"""
NightShift backend.

Two kinds of data, both per dataset folder:
  * EOG's files (network.json, ops.json, telemetry.csv): detection, countdown, cheapest plan, agent.
  * What the iPhone uploads after each round (shifts, flags, photos, notes): saved in SQLite.

EOG data (read-only):
    GET  /datasets                       folders in data/ (test/ first)
    GET  /overview?dataset=              systems, facilities, status, alerts
    GET  /alerts?dataset=                problems in progress, ordered
    GET  /facilities/{id}?dataset=       readings vs limits, trends, plans, what-if, history
    GET  /series?dataset=&asset=&metric= any sensor over time
    GET  /agent/trace?dataset=           the triage agent's steps (starts it on first ask)
    GET  /handoff?dataset=               plain-English handoff
    GET  /events.json?dataset=           export in EOG's format
    GET  /voice/alerts?dataset=          alert sentences for the glasses

iPhone / dashboard:
    POST /shifts/upload                  upload a whole shift (flags inside)
    GET  /shifts?dataset=   GET /shifts/{id}
    POST /flag/{id}/confirm | /dismiss | /note
    GET  /report?shift_id=   GET /next-shift?shift_id=

Run:  uvicorn main:app --reload --host 0.0.0.0 --port 8000

App format (phone/glasses): GET /alerts, GET /facility/{id}, GET /handoff, POST /report, POST /vision/check (raw JPEG).

Clock: GET/POST /clock. Every endpoint resolves its moment with effective_now(): ?now= wins, then the shared replay
clock, else live. Responses for the phone carry mode ("live"|"replay") and as_of.
"""

import base64
import json
import os
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Literal, Optional

import numpy as np
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from app import agent as agent_mod
from app import dataset as D
from app import evidence as evidence_mod
from app import risk as risk_mod
from app import speech, vision
from app.forecast import current_state
from app.handoff import build_handoff, spoken
from app.triage import (SEVERITY_COLOR, SEVERITY_RANK, events_json, fac_name, facility_status, money, run_triage,
                        worst_severity)

BASE = Path(__file__).parent
DB_PATH = Path(os.environ.get("NIGHTSHIFT_DB", BASE / "nightshift.db"))
PHOTOS = BASE / "photos"
PHOTOS.mkdir(exist_ok=True)

TYPE_WEIGHT = {"smoke": 30, "alarm": 25, "leak": 20, "damage": 10}
SENSOR_SCORE = {"high": 60, "medium": 40, "low": 20}  # by triage.severity(), the one scale everything uses

app = FastAPI(title="NightShift API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/photos", StaticFiles(directory=PHOTOS), name="photos")


# ---------- database (iPhone uploads) ----------

@contextmanager
def db():
    """One connection per use: commits on success, rolls back on error, always closes. WAL lets reads run while a
    write is in progress, and busy_timeout makes a second writer wait instead of failing."""
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 5000")
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


SCHEMA = """
CREATE TABLE IF NOT EXISTS shifts (
    id TEXT PRIMARY KEY, dataset TEXT NOT NULL, date TEXT NOT NULL, operator TEXT NOT NULL,
    started_at TEXT NOT NULL, ended_at TEXT NOT NULL, uploaded_at TEXT NOT NULL,
    route_planned TEXT NOT NULL DEFAULT '[]', route_walked TEXT NOT NULL DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS flags (
    id TEXT PRIMARY KEY, shift_id TEXT NOT NULL, type TEXT NOT NULL, location TEXT NOT NULL,
    equipment_id TEXT NOT NULL, photo_url TEXT NOT NULL DEFAULT '', timestamp TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', note TEXT, control_note TEXT,
    trigger_src TEXT NOT NULL DEFAULT 'camera', reason TEXT, priority INTEGER NOT NULL DEFAULT 0
);
"""


def init_db() -> None:
    with db() as c:
        c.execute("PRAGMA journal_mode = WAL")  # stored in the database file, so it holds for every later connection
        cols = [r["name"] for r in c.execute("PRAGMA table_info(shifts)")]
        if cols and "dataset" not in cols:  # old demo schema
            for t in ("shifts", "flags", "equipment", "readings"):
                c.execute(f"DROP TABLE IF EXISTS {t}")
        c.executescript(SCHEMA)
        if "priority" not in [r["name"] for r in c.execute("PRAGMA table_info(flags)")]:  # older database
            c.execute("ALTER TABLE flags ADD COLUMN priority INTEGER NOT NULL DEFAULT 0")
        c.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")


init_db()


# ---------- one clock for the dashboard, the phone and the glasses ----------
# The dashboard's time-travel bar sets the dataset and the moment everyone sees. It is saved in SQLite, so a
# backend restart keeps it. No replay time set = live (the latest reading).

CLOCK: dict = {}  # dataset -> unix time everyone sees (replay)
ACTIVE: dict = {"dataset": None}  # the dataset the dashboard has open; the phone uses it when it does not name one


def _load_clock() -> None:
    try:
        with db() as c:
            row = c.execute("SELECT value FROM settings WHERE key = 'clock'").fetchone()
        saved = json.loads(row["value"]) if row else {}
    except Exception:
        saved = {}
    CLOCK.clear()
    CLOCK.update({k: int(v) for k, v in (saved.get("times") or {}).items()})
    ACTIVE["dataset"] = saved.get("dataset")


def _save_clock() -> None:
    with db() as c:
        c.execute("INSERT OR REPLACE INTO settings VALUES ('clock', ?)",
                  (json.dumps({"dataset": ACTIVE["dataset"], "times": CLOCK}),))


_load_clock()


def default_dataset() -> str:
    """The dataset the dashboard has open (from the clock), else the first folder (test/ first)."""
    names = [d["name"] for d in D.list_datasets()]
    if not names:
        raise HTTPException(500, f"no datasets found in {D.DATA_DIR}")
    return ACTIVE["dataset"] if ACTIVE["dataset"] in names else names[0]


def effective_now(ds, now_param: Optional[int]) -> tuple:
    """
    (now, mode) for a request. An explicit ?now= wins, then the shared replay clock; otherwise live (now None =
    the latest reading). mode is "replay" whenever a time was chosen, "live" otherwise.
    """
    if now_param is not None:
        return int(now_param), "replay"
    if ds.name in CLOCK:
        return CLOCK[ds.name], "replay"
    return None, "live"


def as_of_iso(ds, now: Optional[int]) -> str:
    return D.iso(ds.t_last if now is None else min(int(now), ds.t_last))


def ds_for(name: Optional[str]) -> D.Dataset:
    try:
        return D.load(name or default_dataset())
    except FileNotFoundError:
        raise HTTPException(404, f"dataset '{name}' not found")


def resolve_facility(ds: D.Dataset, location: str) -> str:
    key = location.strip().lower().replace(" ", "_")
    for fid in ds.facilities:
        if fid.lower() == key or fac_name(fid).lower() == location.strip().lower():
            return fid
    for fid, f in ds.facilities.items():  # also accept a pump/tank/pipeline/well id
        ids = [f.pump["id"], f.tank["id"], f.pipeline["id"]] + [w["id"] for w in f.wells]
        if key in [i.lower() for i in ids]:
            return fid
    return location


# ---------- row helpers ----------

def flag_row(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["trigger"] = d.pop("trigger_src")
    return d


def shift_row(r: sqlite3.Row, flags: list) -> dict:
    d = dict(r)
    d["route_planned"] = json.loads(d["route_planned"])
    d["route_walked"] = json.loads(d["route_walked"])
    d["flags"] = flags
    return d


def flags_for_shift(c, shift_id: str) -> list:
    rows = c.execute("SELECT * FROM flags WHERE shift_id = ? ORDER BY timestamp", (shift_id,)).fetchall()
    return [flag_row(r) for r in rows]


def get_shift(c, shift_id: Optional[str], dataset: Optional[str] = None) -> dict:
    if shift_id:
        row = c.execute("SELECT * FROM shifts WHERE id = ?", (shift_id,)).fetchone()
    else:
        ds = dataset or default_dataset()
        row = c.execute("SELECT * FROM shifts WHERE dataset = ? ORDER BY started_at DESC LIMIT 1", (ds,)).fetchone()
    if not row:
        raise HTTPException(404, "shift not found" if shift_id else "no shifts uploaded for this dataset yet")
    return shift_row(row, flags_for_shift(c, row["id"]))


# ---------- models ----------

FlagType = Literal["leak", "smoke", "damage", "alarm"]
FlagStatus = Literal["pending", "confirmed", "dismissed"]


class FlagUpload(BaseModel):
    id: Optional[str] = None
    type: FlagType
    location: str  # facility name or id, e.g. "S1 Facility C" / "S1_FACILITY_C"
    photo_url: str = ""
    timestamp: str
    status: FlagStatus = "pending"
    note: Optional[str] = None
    trigger: Literal["camera", "data", "voice"] = "camera"
    reason: Optional[str] = None


class ShiftUpload(BaseModel):
    id: Optional[str] = None
    dataset: Optional[str] = None
    date: str
    operator: str
    started_at: str
    ended_at: str
    uploaded_at: Optional[str] = None
    route_planned: list[str] = Field(default_factory=list)  # facility ids
    route_walked: list[str] = Field(default_factory=list)
    flags: list[FlagUpload] = Field(default_factory=list)


class NoteIn(BaseModel):
    note: str
    author: Literal["operator", "control"] = "operator"


def save_shift(c, s: ShiftUpload) -> dict:
    dsname = s.dataset or default_dataset()
    ds = ds_for(dsname)
    shift_id = s.id or f"shift-{dsname}-{s.date}"
    c.execute("DELETE FROM flags WHERE shift_id = ? AND id NOT LIKE 'alarm-%'", (shift_id,))
    c.execute(
        "INSERT OR REPLACE INTO shifts VALUES (?,?,?,?,?,?,?,?,?)",
        (shift_id, dsname, s.date, s.operator, s.started_at, s.ended_at,
         s.uploaded_at or datetime.now().isoformat(timespec="seconds"),
         json.dumps([resolve_facility(ds, x) for x in s.route_planned]),
         json.dumps([resolve_facility(ds, x) for x in s.route_walked])),
    )
    for f in s.flags:
        fid = resolve_facility(ds, f.location)
        c.execute(
            """INSERT OR REPLACE INTO flags (id, shift_id, type, location, equipment_id, photo_url, timestamp,
               status, note, control_note, trigger_src, reason) VALUES (?,?,?,?,?,?,?,?,?,NULL,?,?)""",
            (f.id or f"f_{uuid.uuid4().hex[:6]}", shift_id, f.type,
             fac_name(fid) if fid in ds.facilities else f.location, fid, f.photo_url,
             f.timestamp, f.status, f.note, f.trigger, f.reason),
        )
    return get_shift(c, shift_id)


# ---------- iPhone endpoints ----------

@app.get("/health")
def health():
    return {"ok": True}


@app.post("/shifts/upload")
def upload_shift(shift: ShiftUpload):
    """The phone sends the whole round at the end of the shift."""
    with db() as c:
        return save_shift(c, shift)


def seen_by(flags: list, now: Optional[int]) -> list:
    """Flags that already existed at `now` (unix seconds). None = no time limit."""
    if now is None:
        return flags
    def ts(f):
        t = f["timestamp"]
        return datetime.fromisoformat(t.replace("Z", "+00:00") if t.endswith("Z") or "+" in t[10:] else t + "+00:00").timestamp()
    return [f for f in flags if ts(f) <= now]


def one_flag(c, flag_id: str) -> dict:
    row = c.execute("SELECT * FROM flags WHERE id = ?", (flag_id,)).fetchone()
    if not row:
        raise HTTPException(404, f"flag {flag_id} not found")
    return flag_row(row)


def set_status(flag_id: str, status: str) -> dict:
    with db() as c:
        one_flag(c, flag_id)
        c.execute("UPDATE flags SET status = ?, priority = CASE WHEN ? = 'confirmed' THEN priority ELSE 0 END WHERE id = ?", (status, status, flag_id))
        return one_flag(c, flag_id)


@app.post("/flag/{flag_id}/confirm")
def confirm_flag(flag_id: str):
    return set_status(flag_id, "confirmed")


@app.post("/flag/{flag_id}/dismiss")
def dismiss_flag(flag_id: str):
    return set_status(flag_id, "dismissed")


@app.post("/flag/{flag_id}/prioritize")
def prioritize_flag(flag_id: str):
    """Marks the flag as a real problem and puts its facility at the top of the next-shift list."""
    with db() as c:
        one_flag(c, flag_id)
        c.execute("UPDATE flags SET priority = 1, status = 'confirmed' WHERE id = ?", (flag_id,))
        return one_flag(c, flag_id)


@app.post("/flag/{flag_id}/reopen")
def reopen_flag(flag_id: str):
    """Undo a confirm or dismiss: the flag goes back to 'needs review'."""
    return set_status(flag_id, "pending")


def _drop_photo_file(photo_url: str) -> None:
    name = (photo_url or "").split("?")[0].rsplit("/", 1)[-1]
    if name:
        (PHOTOS / name).unlink(missing_ok=True)


@app.post("/flag/{flag_id}/photo")
async def replace_photo(flag_id: str, request: Request):
    """Raw JPEG body: replaces this flag's photo (the old file is removed)."""
    data = await request.body()
    if not data:
        raise HTTPException(400, "empty body: send the raw JPEG bytes")
    with db() as c:
        one_flag(c, flag_id)
        (PHOTOS / f"{flag_id}.jpg").write_bytes(data)
        c.execute("UPDATE flags SET photo_url = ? WHERE id = ?", (f"/photos/{flag_id}.jpg?v={int(datetime.now().timestamp())}", flag_id))
        return one_flag(c, flag_id)


@app.delete("/flag/{flag_id}/photo")
def clear_photo(flag_id: str):
    with db() as c:
        f = one_flag(c, flag_id)
        _drop_photo_file(f["photo_url"])
        c.execute("UPDATE flags SET photo_url = '' WHERE id = ?", (flag_id,))
        return one_flag(c, flag_id)


@app.delete("/flag/{flag_id}")
def delete_flag(flag_id: str):
    with db() as c:
        f = one_flag(c, flag_id)
        _drop_photo_file(f["photo_url"])
        c.execute("DELETE FROM flags WHERE id = ?", (flag_id,))
    return {"ok": True, "deleted": flag_id}


@app.post("/flag/{flag_id}/note")
def add_note(flag_id: str, body: NoteIn):
    col = "control_note" if body.author == "control" else "note"
    with db() as c:
        one_flag(c, flag_id)
        c.execute(f"UPDATE flags SET {col} = ? WHERE id = ?", (body.note, flag_id))
        return one_flag(c, flag_id)


# ---------- EOG data endpoints ----------

@app.get("/datasets")
def datasets():
    out = []
    for d in D.list_datasets():
        ds = D.load(d["name"])
        out.append({"name": d["name"], "now_ts": D.iso(ds.t_last), "first_ts": D.iso(ds.t_first),
                    "systems": len(ds.systems), "facilities": len(ds.facilities)})
    return out


def _facility_card(ds, tri, fid: str) -> dict:
    f = ds.facilities[fid]
    st = current_state(ds, fid, tri["now"])
    alerts = [a for a in tri["alerts"] if a["facility_id"] == fid]
    fail = next((a for a in alerts if a["category"] == "pump_failure"), None)
    return {
        "id": fid, "name": fac_name(fid), "system_id": f.system_id, "lat": f.lat, "lon": f.lon,
        "status": facility_status(tri, fid), "level_pct": round(st["level_pct"], 1),
        "warning_pct": st["warning_pct"], "shutdown_pct": st["shutdown_pct"], "capacity_bbl": st["capacity_bbl"],
        "pump_status": st["pump_status"], "pump_flow_bpd": round(st["pump_flow_bpd"]), "inflow_bpd": round(st["inflow_bpd"]),
        "wells": [{"id": w["id"], "producing": w["producing"]} for w in st["wells"]],
        "pump_id": f.pump["id"], "tank_id": f.tank["id"], "pipeline_id": f.pipeline["id"],
        "hours_to_limit": fail["hours_to_limit"] if fail else None,
        "lost_revenue_per_hour": round(st["lost_revenue_per_hour"], 2),
        "alert_ids": [a["event_id"] for a in alerts],
    }


@app.get("/overview")
def overview(dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    now, mode = effective_now(ds, now)
    tri = run_triage(ds, now)
    systems = []
    for sid, s in ds.systems.items():
        systems.append({
            "id": sid, "center": s["center"], "truck_yard": s["truck_yard"], "fleet_size": s["fleet_size"],
            "disposal_site": s["disposal_site"],
            "facilities": [_facility_card(ds, tri, fid) for fid in s["facility_ids"]],
            "shared": tri["shared_trucks"].get(sid),
        })
    rules = risk_mod.rules_risk(tri)
    alerts = [{**a, "level": SEVERITY_COLOR[a["severity"]],
               **({"truck_cost": risk_mod.truck_cost(ds, a)} if a["category"] == "pump_failure" and a.get("plan") else {})}
              for a in tri["alerts"]]
    for s in systems:
        for f in s["facilities"]:
            f["risk_level"] = rules["facilities"].get(f["id"], "green")
            f["severity"] = worst_severity([a for a in tri["alerts"] if a["facility_id"] == f["id"]]) or "none"
    return {
        "dataset": ds.name, "now_ts": tri["now_ts"], "first_ts": tri["t_first_ts"], "mode": mode, "as_of": tri["now_ts"],
        "systems": systems,
        "alerts": alerts,
        "counts": {
            "failures": sum(a["category"] == "pump_failure" for a in alerts),
            "leaks": sum(a["category"] == "pipeline_leak" for a in alerts),
            "worn": sum(a["category"] == "pump_degradation" for a in alerts),
        },
    }


TYPE_NAME = {"pump_failure": "pump_failure", "pipeline_leak": "pipeline_leak", "pump_degradation": "pump_wear"}


def app_alert(a: dict) -> dict:
    word = a["severity"]
    sev = SEVERITY_RANK[word]  # 3 / 2 / 1, kept for older app builds
    h = a.get("hours_to_limit")
    plan = a.get("plan")
    return {
        "id": a["event_id"], "facility": a["facility_id"], "facility_name": a["facility_name"], "system": a["system_id"],
        "type": TYPE_NAME[a["category"]], "severity": sev, "severity_word": word, "level": SEVERITY_COLOR[word],
        "hours_to_shutdown": h["p50"] if h else None, "tripped": bool(a.get("tripped")),
        "best_plan": a.get("action_text") or ("Send an inspector to check" if a["category"] != "pump_failure" else None),
        "cost": plan["cost"] if plan else None, "spoken_text": spoken(a),
    }


@app.get("/alerts")
def alerts(dataset: Optional[str] = None, now: Optional[int] = None):
    """App format. Ranked by severity (high first), then fewest hours to shutdown."""
    ds = ds_for(dataset)
    out = [app_alert(a) for a in run_triage(ds, effective_now(ds, now)[0])["alerts"]]
    return sorted(out, key=lambda x: (-x["severity"], x["hours_to_shutdown"] if x["hours_to_shutdown"] is not None else 1e9))


METRIC_INFO = [
    ("tank", "level_pct", "Tank level", "%"),
    ("pump", "flow_bpd", "Pump flow", "bpd"),
    ("pump", "discharge_psi", "Pump discharge pressure", "psi"),
    ("pipeline", "pressure_psi", "Pipeline pressure", "psi"),
    ("pipeline", "receive_flow_bpd", "Flow arriving at disposal", "bpd"),
    ("facility", "inflow_bpd", "Well water inflow", "bpd"),
]


def _series(ds, asset: str, metric: str, now: int, hours: float, points: int = 420) -> list:
    if not ds.has(asset, metric):
        raise HTTPException(404, f"no series {asset}/{metric}")
    s = ds.wide[(asset, metric)].loc[:now]
    s = s.loc[max(int(s.index[0]), now - int(hours * 3600)):]
    step = max(1, int(np.ceil(len(s) / points)))
    idx, vals = s.index.values, s.values
    out = []
    for i in range(0, len(s), step):
        out.append([int(idx[i + step // 2 if i + step // 2 < len(s) else i]), round(float(np.nanmean(vals[i:i + step])), 2)])
    return out


@app.get("/series")
def series(asset: str, metric: str, dataset: Optional[str] = None, hours: float = 72, now: Optional[int] = None):
    ds = ds_for(dataset)
    now = effective_now(ds, now)[0]
    n = ds.t_last if now is None else min(now, ds.t_last)
    return {"asset": asset, "metric": metric, "points": _series(ds, asset, metric, n, hours)}


@app.get("/facilities/{fac_id}")
def facility(fac_id: str, dataset: Optional[str] = None, hours: float = 72, now: Optional[int] = None):
    ds = ds_for(dataset)
    if fac_id not in ds.facilities:
        raise HTTPException(404, f"facility {fac_id} not found")
    now, mode = effective_now(ds, now)
    tri = run_triage(ds, now)
    f = ds.facilities[fac_id]
    card = _facility_card(ds, tri, fac_id)
    st = current_state(ds, fac_id, tri["now"])
    ids = {"tank": f.tank["id"], "pump": f.pump["id"], "pipeline": f.pipeline["id"], "facility": fac_id}

    readings = [
        {"label": "Tank level", "unit": "%", "value": round(st["level_pct"], 1), "limit": st["shutdown_pct"],
         "warning": st["warning_pct"], "note": "Wells shut in automatically at the shutdown limit"},
        {"label": "Pump flow", "unit": "bpd", "value": round(st["pump_flow_bpd"]), "limit": f.pump["max_flow_bpd"],
         "note": "Rated flow when running"},
        {"label": "Pump discharge pressure", "unit": "psi",
         "value": round(float(ds.wide[(f.pump["id"], "discharge_psi")].loc[:tri["now"]].iloc[-1])),
         "limit": f.pipeline["max_pressure_psi"], "note": "Pipeline pressure limit"},
        {"label": "Flow arriving at disposal", "unit": "bpd",
         "value": round(float(ds.wide[(f.pipeline["id"], "receive_flow_bpd")].loc[:tri["now"]].iloc[-1])),
         "limit": f.pipeline["max_bpd"], "note": "Pipeline capacity"},
    ]
    sers = []
    for kind, metric, label, unit in METRIC_INFO:
        sers.append({"asset": ids[kind], "metric": metric, "label": label, "unit": unit,
                     "points": _series(ds, ids[kind], metric, tri["now"], hours)})
    with db() as c:
        flag_rows = c.execute(
            """SELECT f.*, s.date AS shift_date FROM flags f JOIN shifts s ON s.id = f.shift_id
               WHERE s.dataset = ? AND f.equipment_id = ? ORDER BY f.timestamp DESC""", (ds.name, fac_id)).fetchall()
    return {
        **card, "dataset": ds.name, "now": tri["now"], "mode": mode, "as_of": tri["now_ts"], "readings": readings, "series": sers,
        "alerts": [a for a in tri["alerts"] if a["facility_id"] == fac_id],
        "events": [e for e in tri["events"] if e["facility_id"] == fac_id][::-1],
        "pump_max_flow_bpd": f.pump["max_flow_bpd"],
        "start_level_pct": f.pump["start_level_pct"], "stop_level_pct": f.pump["stop_level_pct"],
        "wells_detail": [{**w, "rev_per_hour": round(ds.well_rev_per_hour(w), 2)} for w in f.wells],
        "response_min": f.response_min, "cycle_min": f.cycle_min,
        "flags": seen_by([flag_row(r) for r in flag_rows], now),
        "assets": {"tank": f.tank["id"], "pump": f.pump["id"], "pipeline": f.pipeline["id"],
                   "wells": [w["id"] for w in f.wells]},
    }


@app.get("/facility/{fac_id}")
def facility_app(fac_id: str, dataset: Optional[str] = None, now: Optional[int] = None):
    """App format: {id, name, status, readings, spoken_text}."""
    ds = ds_for(dataset)
    eff, mode = effective_now(ds, now)
    fac_id = resolve_facility(ds, fac_id)
    full = facility(fac_id, ds.name, 1, eff)
    readings = [{"label": r["label"], "value": r["value"], "unit": r["unit"], "limit": r.get("limit")} for r in full["readings"]]
    return {"id": fac_id, "name": full["name"], "system": full["system_id"], "status": full["status"], "readings": readings,
            "alerts": [app_alert(a) for a in full["alerts"]], "mode": mode, "as_of": full["as_of"],
            "spoken_text": voice_facility(fac_id, ds.name, eff)["text"]}  # same moment as the readings on screen


@app.get("/agent/trace")
def agent_trace(dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    return agent_mod.get_run(ds.name, now).public()


@app.post("/agent/run")
def agent_run(dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    return agent_mod.get_run(ds.name, now, force=True).public()


@app.get("/handoff")
def handoff(dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    now, mode = effective_now(ds, now)
    tri = run_triage(ds, now)
    h = build_handoff(tri)
    h["mode"] = mode
    run = agent_mod.get_run(ds.name, now)
    if run.status == "done" and run.handoff_text:
        h["agent_text"] = run.handoff_text
        h["agent_mode"] = run.mode
    h["events_count"] = len(tri["events"])
    return h


@app.get("/events.json")
def events_export(dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    return JSONResponse(events_json(run_triage(ds, now)), headers={"Content-Disposition": 'attachment; filename="events.json"'})


@app.get("/voice/alerts")
def voice_alerts(dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    tri = run_triage(ds, effective_now(ds, now)[0])
    return [{"event_id": a["event_id"], "facility_id": a["facility_id"], "text": spoken(a)} for a in tri["alerts"]]


@app.get("/voice/facility/{fac_id}")
def voice_facility(fac_id: str, dataset: Optional[str] = None, now: Optional[int] = None):
    ds = ds_for(dataset)
    if fac_id not in ds.facilities:
        raise HTTPException(404, "facility not found")
    tri = run_triage(ds, effective_now(ds, now)[0])
    c = _facility_card(ds, tri, fac_id)
    mine = [spoken(a) for a in tri["alerts"] if a["facility_id"] == fac_id]
    base = f"{speech.facility(c['name'])}: tank {speech.num_words(c['level_pct'])} percent full, pump {'running' if c['pump_status'] == 1 else 'fault' if c['pump_status'] == 2 else 'stopped'}."
    return {"facility_id": fac_id, "text": " ".join([base] + (mine or ["No problems in progress."]))}


@app.post("/vision/check")
async def vision_check(request: Request):
    """Raw JPEG (Content-Type image/jpeg) in -> {flag, type, confidence, description}. A person still confirms or dismisses."""
    data = await request.body()
    if not data:
        raise HTTPException(400, "empty body: send the raw JPEG bytes")
    r = vision.check_image("data:image/jpeg;base64," + base64.b64encode(data).decode())
    if not r.get("available"):
        return {"flag": False, "type": "none", "confidence": 0, "description": "", "available": False, "error": r.get("error")}
    t = r["finding"]
    return {"flag": t != "none", "type": t, "confidence": r.get("confidence"), "description": r["description"], "available": True,
            "needs_human_confirmation": True}


# ---------- shifts, report, next shift ----------

@app.get("/shifts")
def list_shifts(dataset: Optional[str] = None):
    ds = dataset or default_dataset()
    with db() as c:
        rows = c.execute("SELECT * FROM shifts WHERE dataset = ? ORDER BY started_at DESC", (ds,)).fetchall()
        return [shift_row(r, flags_for_shift(c, r["id"])) for r in rows]


@app.get("/shifts/{shift_id}")
def read_shift(shift_id: str):
    with db() as c:
        return get_shift(c, shift_id)


def flag_type_for(t: str) -> str:
    t = (t or "").lower()
    if t in ("leak", "smoke", "damage"):
        return t
    if any(k in t for k in ("leak", "spill", "drip", "oil", "liquid", "puddle")):
        return "leak"
    if any(k in t for k in ("smoke", "fire", "vapor", "vapour", "flame")):
        return "smoke"
    return "damage"


class ReportNote(BaseModel):
    text: str = ""


class ReportFlag(BaseModel):
    id: Optional[str] = None
    type: str = "damage"  # leak | smoke | damage (anything else is stored as damage with the original in reason)
    facility: Optional[str] = None  # facility id or name
    location: Optional[str] = None
    created_at: Optional[str] = None
    timestamp: Optional[str] = None
    source: str = "camera"  # camera | voice
    trigger: Optional[str] = None  # same meaning as source
    description: Optional[str] = None  # Nemotron's sentence from /vision/check, shown as "Why it was flagged"
    status: str = "waiting"  # waiting | confirmed | dismissed
    note: Optional[str] = None
    notes: list[ReportNote] = Field(default_factory=list)
    photo_jpeg_base64: Optional[str] = None  # JPEG, with or without a data: prefix
    photo_base64: Optional[str] = None
    reason: Optional[str] = None


class ReportIn(BaseModel):
    """What the iOS app sends (snake_case): shift_id, started_at, ended_at, flags[], notes[], generated_at."""
    dataset: Optional[str] = None
    shift_id: Optional[str] = None
    operator: str = "Operator"
    date: Optional[str] = None
    started_at: Optional[str] = None
    ended_at: Optional[str] = None
    generated_at: Optional[str] = None
    route_planned: list[str] = Field(default_factory=list)
    route_walked: list[str] = Field(default_factory=list)
    flags: list[ReportFlag] = Field(default_factory=list)
    notes: list[ReportNote] = Field(default_factory=list)


@app.post("/report")
def post_report(body: ReportIn):
    """The phone sends the whole round as one JSON body, photos as base64. Re-sending the same shift_id replaces it."""
    now = datetime.now().isoformat(timespec="seconds")
    ds = ds_for(body.dataset)
    flags, photos = [], {}
    for f in body.flags:
        fid = f.id or f"f_{uuid.uuid4().hex[:6]}"
        url = ""
        raw = f.photo_jpeg_base64 or f.photo_base64
        if raw:
            try:
                photos[fid] = base64.b64decode(raw.split(",", 1)[-1])
            except Exception:
                raise HTTPException(400, f"flag {fid}: photo is not valid base64")
            url = f"/photos/{fid}.jpg"
        ftype = flag_type_for(f.type)
        reasons = [x for x in (f.description, f.reason) if x]
        if ftype != f.type and not f.description:
            reasons.append(f"app flag type: {f.type}")
        trig = (f.trigger or f.source or "camera").lower()
        trig = trig if trig in ("camera", "voice", "data") else "camera"
        note = " ".join([t for t in [f.note] + [n.text for n in f.notes] if t]) or None
        flags.append(FlagUpload(id=fid, type=ftype, location=f.facility or f.location or "unknown", photo_url=url,
                                timestamp=f.created_at or f.timestamp or now,
                                status={"waiting": "pending"}.get(f.status, f.status) if f.status in ("waiting", "pending", "confirmed", "dismissed") else "pending",
                                note=note, trigger=trig, reason="; ".join(reasons) or None))
    # One flag per item: the same facility and the same kind of problem is replaced by the newest one,
    # not added again. (Its older photo is dropped too.)
    newest = {}
    for fl in flags:
        fac = resolve_facility(ds, fl.location)
        key = (fac if fac in ds.facilities else "_".join(fac.lower().replace("-", " ").split()), fl.type)
        if key not in newest or fl.timestamp >= newest[key].timestamp:
            newest[key] = fl
    keep = {id(x) for x in newest.values()}
    replaced = len(flags) - len(keep)
    flags = [fl for fl in flags if id(fl) in keep]
    for fl in flags:
        if fl.id in photos:
            (PHOTOS / f"{fl.id}.jpg").write_bytes(photos[fl.id])
    started = body.started_at or now
    shift = ShiftUpload(id=body.shift_id, dataset=body.dataset, date=body.date or started[:10], operator=body.operator,
                        started_at=started, ended_at=body.ended_at or body.generated_at or now,
                        route_planned=body.route_planned, route_walked=body.route_walked, flags=flags)
    with db() as c:
        saved = save_shift(c, shift)
    return {"ok": True, "shift_id": saved["id"], "flags_saved": len(saved["flags"]), "replaced_duplicates": replaced,
            "flags": saved["flags"]}


@app.get("/report")
def get_report(shift_id: Optional[str] = None, dataset: Optional[str] = None, now: Optional[int] = None):
    with db() as c:
        shift = get_shift(c, shift_id, dataset)
    now, mode = effective_now(ds_for(shift["dataset"]), now)
    shift = {**shift, "flags": seen_by(shift["flags"], now)}  # in a replay, flags from later than "now" do not exist yet
    flags = shift["flags"]
    by_type: dict = {}
    for f in flags:
        by_type[f["type"]] = by_type.get(f["type"], 0) + 1
    with_status = lambda s: [f for f in flags if f["status"] == s]
    notes = []
    for f in flags:
        if f["note"]:
            notes.append({"flag_id": f["id"], "location": f["location"], "note": f["note"], "author": "operator", "timestamp": f["timestamp"]})
        if f["control_note"]:
            notes.append({"flag_id": f["id"], "location": f["location"], "note": f["control_note"], "author": "control", "timestamp": f["timestamp"]})
    walked = set(shift["route_walked"])
    return {
        "shift": {k: shift[k] for k in ("id", "dataset", "date", "operator", "started_at", "ended_at", "uploaded_at")},
        "totals": {"total": len(flags), "confirmed": len(with_status("confirmed")), "pending": len(with_status("pending")),
                   "dismissed": len(with_status("dismissed"))},
        "by_type": by_type, "confirmed": with_status("confirmed"), "pending": with_status("pending"),
        "notes": sorted(notes, key=lambda n: n["timestamp"]),
        "stops_planned": len(shift["route_planned"]),
        "stops_walked": len([s for s in shift["route_planned"] if s in walked]),
        "missed_stops": [s for s in shift["route_planned"] if s not in walked],
        "mode": mode,
    }


def flag_level(flags: list, missed: bool):
    """What the operator's own flags say: prioritized -> high, confirmed -> medium, unreviewed or missed stop -> low."""
    if any(f.get("priority") for f in flags):
        return "high"
    if any(f["status"] == "confirmed" for f in flags):
        return "medium"
    return "low" if flags or missed else None


def _flag_counts(flags: list) -> str:
    """'a leak flag' / '4 flags (3 leak, 1 smoke)'"""
    if len(flags) == 1:
        t = flags[0]["type"]
        return f"{'an' if t[0] in 'aeiou' else 'a'} {t} flag"
    by: dict = {}
    for f in flags:
        by[f["type"]] = by.get(f["type"], 0) + 1
    return f"{len(flags)} flags (" + ", ".join(f"{n} {t}" for t, n in sorted(by.items(), key=lambda x: -x[1])) + ")"


@app.get("/next-shift")
def get_next_shift(shift_id: Optional[str] = None, dataset: Optional[str] = None, now: Optional[int] = None):
    """
    Simple, explainable scoring per facility (dismissed flags are ignored):
      +50 confirmed flag last shift   +25 unreviewed flag last shift
      +30/+20/+10 worst flag type (smoke/leak/damage)
      Only the selected (previous) shift counts, earlier nights are not used.
      +15 stop planned but missed
      +60 / +40 / +20 sensor problem still in progress, by severity (high / medium / low), latest shift only
      +100 marked as priority by the operator
    level = the worse of the sensor severity and the flags (prioritized high, confirmed medium, else low).
    """
    ds0 = ds_for(dataset)
    dataset = ds0.name
    eff, _ = effective_now(ds0, now)
    with db() as c:
        try:
            if shift_id is None:  # follow the replay time like the dashboard does: the shift in progress at that moment
                if eff is not None:
                    rows = c.execute("SELECT id, started_at FROM shifts WHERE dataset = ? AND id NOT LIKE 'alarms-%'",
                                     (dataset,)).fetchall()
                    before = sorted((r for r in rows if _unix_of(r["started_at"]) <= eff), key=lambda r: _unix_of(r["started_at"]), reverse=True)
                    shift_id = before[0]["id"] if before else None
            shift = get_shift(c, shift_id, dataset)
        except HTTPException:
            if shift_id:
                raise
            # No phone upload for this dataset yet (e.g. a brand new test/ folder): rank from the sensors alone.
            shift = {"id": None, "dataset": dataset, "date": None, "flags": [],
                     "route_planned": [], "route_walked": []}
        newest = c.execute("SELECT id FROM shifts WHERE dataset = ? ORDER BY started_at DESC LIMIT 1", (shift["dataset"],)).fetchone()
    ds = ds_for(shift["dataset"])
    if ds.name != ds0.name:  # a shift id from another dataset: use that dataset's clock
        eff, _ = effective_now(ds, now)
    now_flags = [f for f in seen_by(shift["flags"], eff) if f["status"] != "dismissed"]
    walked = set(shift["route_walked"])
    missed = {s for s in shift["route_planned"] if s not in walked}
    sensor = {}
    if newest is None or newest["id"] == shift["id"]:
        for a in run_triage(ds, eff)["alerts"]:
            sensor.setdefault(a["facility_id"], []).append(a)

    out = []
    for eid in {f["equipment_id"] for f in now_flags} | missed | set(sensor):
        now = [f for f in now_flags if f["equipment_id"] == eid]
        score, reasons = 0, []
        for a in sorted(sensor.get(eid, []), key=lambda a: -SENSOR_SCORE[a["severity"]]):
            score += SENSOR_SCORE[a["severity"]]
            what = {"pump_failure": "Pump failure in progress", "pipeline_leak": "Possible pipeline leak",
                    "pump_degradation": "Pump wearing out"}[a["category"]]
            extra = ""
            if a["category"] == "pump_failure" and a.get("hours_to_limit"):
                extra = f", tank hits shutdown in {a['hours_to_limit']['p50']:.1f} h. {a['action_text']}"
            reasons.append(f"{what} (sensor data){extra}")
        urgent = [f for f in now if f.get("priority")]
        if urgent:
            score += 100
            reasons.insert(0, "Marked as priority by the operator")
        confirmed = [f for f in now if f["status"] == "confirmed"]
        pending = [f for f in now if f["status"] == "pending"]
        if confirmed:
            score += 50
            reasons.append(f"Operator confirmed {_flag_counts(confirmed)} last shift")
        if pending:
            score += 25
            reasons.append(f"Unreviewed: {_flag_counts(pending)} from last shift")
        everything = now
        if everything:
            worst = max(everything, key=lambda f: TYPE_WEIGHT[f["type"]])["type"]
            score += TYPE_WEIGHT[worst]
            reasons.append(f"Worst flag type seen here: {worst}")
        for f in now:
            if f["trigger"] == "data" and f["reason"]:
                reasons.append(f"Data check: {f['reason']}")
                break
        if eid in missed:
            score += 15
            reasons.append("Stop was planned last shift but not checked")
        if score == 0:
            continue
        latest = max(everything, key=lambda f: f["timestamp"]) if everything else None
        sev = worst_severity(sensor.get(eid, []))
        # level = the worse of the sensor severity and what the operator's flags say (never the score alone)
        level = max([x for x in (sev, flag_level(now, eid in missed)) if x], key=SEVERITY_RANK.get)
        out.append({"equipment_id": eid, "location": fac_name(eid) if eid in ds.facilities else eid, "score": score,
                    "level": level, "severity": sev or "none", "reasons": reasons, "latest_flag": latest})
    return sorted(out, key=lambda p: p["score"], reverse=True)


@app.get("/map")
def map_points(dataset: Optional[str] = None, shift_id: Optional[str] = None, now: Optional[int] = None):
    """
    Everything a map needs, already ordered by importance (rank 1 = check first).
    Same ranking as Next shift: confirmed/unreviewed flags + problems in progress. Facilities with nothing wrong follow.
    """
    ds = ds_for(dataset)
    now, mode = effective_now(ds, now)
    tri = run_triage(ds, now)
    prio = get_next_shift(shift_id, ds.name, now)
    by_id = {p["equipment_id"]: p for p in prio}
    ranked = [p["equipment_id"] for p in prio if p["equipment_id"] in ds.facilities]
    status_rank = {"tripped": 0, "failure": 1, "leak": 2, "worn": 3, "ok": 4}
    rest = sorted((f for f in ds.facilities if f not in by_id),
                  key=lambda f: (status_rank.get(facility_status(tri, f), 4), f))
    points = []
    for i, fid in enumerate(ranked + rest, start=1):
        f = ds.facilities[fid]
        p = by_id.get(fid)
        alerts = [a for a in tri["alerts"] if a["facility_id"] == fid]
        h = next((a["hours_to_limit"]["p50"] for a in alerts if a.get("hours_to_limit")), None)
        points.append({
            "rank": i, "id": fid, "name": fac_name(fid), "system": f.system_id, "lat": f.lat, "lon": f.lon,
            "importance": p["score"] if p else 0, "level": p["level"] if p else "none",
            "severity": worst_severity(alerts) or "none",
            "status": facility_status(tri, fid), "hours_to_shutdown": h,
            "reasons": p["reasons"] if p else [],
            "spoken_text": " ".join(spoken(a) for a in alerts) if alerts else "",
        })
    systems = [{"id": sid, "center": s["center"], "truck_yard": s["truck_yard"], "disposal_site": s["disposal_site"]}
               for sid, s in ds.systems.items()]
    return {"dataset": ds.name, "as_of": tri["now_ts"], "mode": mode, "systems": systems, "facilities": points}


# ---------- danger check, time travel, alarm ----------

def _warm_timelines() -> None:
    for d in D.list_datasets():
        try:
            risk_mod.timeline(D.load(d["name"]))
        except Exception:
            pass


import threading  # noqa: E402

threading.Thread(target=_warm_timelines, daemon=True).start()


@app.get("/timeline")
def get_timeline(dataset: Optional[str] = None):
    """Slider range plus the amber/red stretches and the moments an alarm would have gone off."""
    return risk_mod.timeline(ds_for(dataset))


def _unix_of(iso: str) -> float:
    return datetime.fromisoformat(iso.replace("Z", "+00:00") if iso.endswith("Z") else iso + "+00:00").timestamp()


AUTO_TYPE = {"pump_failure": "alarm", "pipeline_leak": "leak", "pump_degradation": "damage"}


def record_alarm(ds, out: dict, live: bool, cleanup: bool = True) -> None:
    """
    When something needs a person (a red alarm, or a sizeable leak or worn pump), log it as a flag (trigger "data") so
    the operator can confirm, dismiss or prioritize it, on the dashboard or by voice at the site. One flag per
    facility per problem, so repeats do nothing. A flag nobody decided on goes away when its problem is over.
    """
    current = {(f["facility_id"], str(f["onset_unix"])) for f in out.get("flaggable", [])}
    if cleanup:  # only the dashboard's own check tidies up, so the phone's polling never fights a replay
        with db() as c:
            rows = c.execute("""SELECT f.id FROM flags f JOIN shifts s ON s.id = f.shift_id
                                WHERE s.dataset = ? AND f.id LIKE 'alarm-%' AND f.status = 'pending'""", (ds.name,)).fetchall()
            for r in rows:
                fid, _, onset = r["id"][len("alarm-"):].rpartition("-")
                if int(onset) <= out["now"] and (fid, onset) not in current:
                    c.execute("DELETE FROM flags WHERE id = ?", (r["id"],))
    if not out.get("flaggable"):
        return
    ai = out.get("ai") or {}
    why = ai.get("why") if ai.get("available") else None
    with db() as c:
        shifts = c.execute("SELECT id, started_at FROM shifts WHERE dataset = ? AND id NOT LIKE 'alarms-%' ORDER BY started_at DESC",
                           (ds.name,)).fetchall()
        if live and shifts:
            shift_id = shifts[0]["id"]
        else:  # replay: the shift in progress at that moment, else the last one that started before it
            before = [s for s in shifts if _unix_of(s["started_at"]) <= out["now"]]
            shift_id = before[0]["id"] if before else None
        if shift_id is None:  # no phone shift yet at this time: keep the alarm in a system log shift
            shift_id = f"alarms-{ds.name}"
            c.execute("INSERT OR IGNORE INTO shifts VALUES (?,?,?,?,?,?,?,?,?)",  # many polls can arrive at once
                      (shift_id, ds.name, out["as_of"][:10], "System alarms", out["as_of"], out["as_of"],
                       out["as_of"], "[]", "[]"))
        for r in out["flaggable"]:
            fid = r["facility_id"]
            flag_id = f"alarm-{fid}-{r['onset_unix']}"
            # the AI sentence is about one facility: only attach it to the flag of the facility it names
            reason = r["text"] + (f". {why}" if why and r["level"] == "red" and fac_name(fid) in why else "")
            c.execute(  # OR IGNORE: one flag per facility per problem, however many requests race here
                """INSERT OR IGNORE INTO flags (id, shift_id, type, location, equipment_id, photo_url, timestamp, status, note,
                   control_note, trigger_src, reason) VALUES (?,?,?,?,?,?,?,?,NULL,NULL,?,?)""",
                (flag_id, shift_id, AUTO_TYPE[r["category"]], fac_name(fid) if fid in ds.facilities else fid, fid, "",
                 out["as_of"], "pending", "data", reason))


@app.get("/risk/note")
def get_risk_note(dataset: Optional[str] = None, now: Optional[int] = None):
    """
    The AI second opinion for this moment, without waiting for it: starts it in the background if needed.
    status: "ready" (note filled in), "pending" (ask again in a few seconds), "unavailable", or "none" (nothing to judge).
    """
    ds = ds_for(dataset)
    out = risk_mod.assess(ds, effective_now(ds, now)[0], use_ai=True)
    ai = out["ai"]
    status = "none" if ai is None else "pending" if ai.get("pending") else "ready" if ai.get("available") else "unavailable"
    return {"dataset": ds.name, "as_of": out["as_of"], "level": out["level"], "status": status, "note": out["note"], "ai": ai}


@app.get("/risk")
def get_risk(dataset: Optional[str] = None, now: Optional[int] = None, ai: bool = True):
    """Is this moment dangerous? The rules decide; a Nemotron note is added when it is ready (it never changes the level)."""
    ds = ds_for(dataset)
    eff, mode = effective_now(ds, now)
    out = risk_mod.assess(ds, eff, use_ai=ai)
    record_alarm(ds, out, live=(mode == "live"))
    return {**out, "mode": mode}


class ClockIn(BaseModel):
    dataset: Optional[str] = None
    now: Optional[int] = None  # null = back to the latest data


def clock_state(ds) -> dict:
    now, mode = effective_now(ds, None)
    return {"dataset": ds.name, "now": now, "now_ts": as_of_iso(ds, now), "mode": mode, "live": mode == "live"}


@app.get("/clock")
def get_clock(dataset: Optional[str] = None):
    """Which dataset and moment everyone sees. The phone reads the dataset from here (no local default)."""
    return clock_state(ds_for(dataset))


@app.post("/clock")
def set_clock(body: ClockIn):
    """Time travel for everyone: the phone and glasses see this dataset and moment until it is cleared (now: null)."""
    ds = ds_for(body.dataset)
    if body.dataset:
        ACTIVE["dataset"] = ds.name
    if body.now is None:
        CLOCK.pop(ds.name, None)
    else:
        CLOCK[ds.name] = int(min(max(body.now, ds.t_first), ds.t_last))
    _save_clock()
    return clock_state(ds)


@app.get("/alarm")
def get_alarm(dataset: Optional[str] = None, now: Optional[int] = None):
    """
    For the phone and the glasses: poll this every few seconds. When `alarm` is true, sound/vibrate and speak
    `spoken_text`. `alarm_id` changes when a new red situation starts, so the phone can alarm once per situation.
    """
    ds = ds_for(dataset)
    eff, mode = effective_now(ds, now)
    out = risk_mod.assess(ds, eff, use_ai=False, peek_ai=True)  # rules only: no model call on this path, ever
    record_alarm(ds, out, live=(mode == "live"), cleanup=False)
    return {k: out[k] for k in ("dataset", "as_of", "level", "severity", "alarm", "alarm_id", "headline", "spoken_text", "note")} | {
        "mode": mode, "live": mode == "live", "reasons": [r["text"] for r in out["reasons"]],
        "facility_ids": [f["facility_id"] for f in out["flaggable"] if f["level"] == "red"]}


@app.get("/evidence")
def get_evidence(dataset: Optional[str] = None, now: Optional[int] = None, ai: bool = True):
    """Charts of what dropped (or rose) at each facility with a problem, picked and captioned by Nemotron."""
    ds = ds_for(dataset)
    return evidence_mod.build(ds, effective_now(ds, now)[0], use_ai=ai)


@app.get("/issue")
def get_issue(dataset: Optional[str] = None, facility: Optional[str] = None, now: Optional[int] = None):
    """
    "Meta, what's the issue?" at the site. Says what is wrong at a facility (default: the most urgent one) and
    returns the flag the operator can then dismiss or prioritize (POST /flag/{id}/dismiss or /prioritize).
    """
    ds = ds_for(dataset)
    eff, mode = effective_now(ds, now)
    out = risk_mod.assess(ds, eff, use_ai=False)
    record_alarm(ds, out, live=(mode == "live"), cleanup=False)  # make sure there is a flag to act on
    tri = run_triage(ds, eff)
    fid = resolve_facility(ds, facility) if facility else None
    if fid not in ds.facilities:
        order = sorted(out["flaggable"], key=lambda f: (f["level"] != "red", f["onset_unix"]))
        fid = order[0]["facility_id"] if order else None
    if fid is None:
        return {"facility_id": None, "name": None, "problem": False, "spoken_text": "No problems right now.", "flag": None, "options": []}
    name = fac_name(fid)
    alerts = [a for a in tri["alerts"] if a["facility_id"] == fid]
    if not alerts:
        return {"facility_id": fid, "name": name, "problem": False, "spoken_text": f"{speech.facility(name)} has no problems right now.",
                "flag": None, "options": []}
    parts = []
    for a in alerts:
        parts.append(spoken(a))
        if a["category"] == "pipeline_leak":
            d = risk_mod._drop(ds, a, tri["now"])
            if d and d[0] > 0.01:
                parts.append(f"About {speech.num_words(d[0] * 100)} percent of the water is not arriving.")
    with db() as c:
        rows = c.execute("""SELECT f.* FROM flags f JOIN shifts s ON s.id = f.shift_id
                            WHERE s.dataset = ? AND f.equipment_id = ? AND f.status != 'dismissed'
                            ORDER BY (f.status = 'pending') DESC, f.timestamp DESC""", (ds.name, fid)).fetchall()
    flags = seen_by([flag_row(r) for r in rows], eff)
    flag = flags[0] if flags else None
    if flag:
        parts.append("Say dismiss, or prioritize.")
    return {"facility_id": fid, "name": name, "problem": True, "level": next((f["level"] for f in out["flaggable"] if f["facility_id"] == fid), "green"),
            "spoken_text": " ".join(parts), "flag": flag, "options": ["dismiss", "prioritize"] if flag else []}
