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
"""

import json
import sqlite3
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Literal, Optional

import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from app import agent as agent_mod
from app import dataset as D
from app import vision
from app.forecast import current_state
from app.handoff import build_handoff, spoken
from app.triage import events_json, fac_name, facility_status, money, run_triage

BASE = Path(__file__).parent
DB_PATH = BASE / "nightshift.db"
PHOTOS = BASE / "photos"
PHOTOS.mkdir(exist_ok=True)

TYPE_WEIGHT = {"smoke": 30, "leak": 20, "damage": 10}
HISTORY_DAYS = 7
SENSOR_SCORE = {"pump_failure": 60, "pipeline_leak": 40, "pump_degradation": 20}

app = FastAPI(title="NightShift API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/photos", StaticFiles(directory=PHOTOS), name="photos")


# ---------- database (iPhone uploads) ----------

def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


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
    trigger_src TEXT NOT NULL DEFAULT 'camera', reason TEXT
);
"""


def init_db() -> None:
    with db() as c:
        cols = [r["name"] for r in c.execute("PRAGMA table_info(shifts)")]
        if cols and "dataset" not in cols:  # old demo schema
            for t in ("shifts", "flags", "equipment", "readings"):
                c.execute(f"DROP TABLE IF EXISTS {t}")
        c.executescript(SCHEMA)


init_db()


def default_dataset() -> str:
    names = [d["name"] for d in D.list_datasets()]
    if not names:
        raise HTTPException(500, f"no datasets found in {D.DATA_DIR}")
    return names[0]


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

FlagType = Literal["leak", "smoke", "damage"]
FlagStatus = Literal["pending", "confirmed", "dismissed"]


class FlagUpload(BaseModel):
    id: Optional[str] = None
    type: FlagType
    location: str  # facility name or id, e.g. "S1 Facility C" / "S1_FACILITY_C"
    photo_url: str = ""
    timestamp: str
    status: FlagStatus = "pending"
    note: Optional[str] = None
    trigger: Literal["camera", "data"] = "camera"
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
    c.execute("DELETE FROM flags WHERE shift_id = ?", (shift_id,))
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


def one_flag(c, flag_id: str) -> dict:
    row = c.execute("SELECT * FROM flags WHERE id = ?", (flag_id,)).fetchone()
    if not row:
        raise HTTPException(404, f"flag {flag_id} not found")
    return flag_row(row)


def set_status(flag_id: str, status: str) -> dict:
    with db() as c:
        one_flag(c, flag_id)
        c.execute("UPDATE flags SET status = ? WHERE id = ?", (status, flag_id))
        return one_flag(c, flag_id)


@app.post("/flag/{flag_id}/confirm")
def confirm_flag(flag_id: str):
    return set_status(flag_id, "confirmed")


@app.post("/flag/{flag_id}/dismiss")
def dismiss_flag(flag_id: str):
    return set_status(flag_id, "dismissed")


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
    tri = run_triage(ds, now)
    systems = []
    for sid, s in ds.systems.items():
        systems.append({
            "id": sid, "center": s["center"], "truck_yard": s["truck_yard"], "fleet_size": s["fleet_size"],
            "disposal_site": s["disposal_site"],
            "facilities": [_facility_card(ds, tri, fid) for fid in s["facility_ids"]],
            "shared": tri["shared_trucks"].get(sid),
        })
    alerts = tri["alerts"]
    return {
        "dataset": ds.name, "now_ts": tri["now_ts"], "first_ts": tri["t_first_ts"], "systems": systems,
        "alerts": alerts,
        "counts": {
            "failures": sum(a["category"] == "pump_failure" for a in alerts),
            "leaks": sum(a["category"] == "pipeline_leak" for a in alerts),
            "worn": sum(a["category"] == "pump_degradation" for a in alerts),
        },
    }


@app.get("/alerts")
def alerts(dataset: Optional[str] = None, now: Optional[int] = None):
    return run_triage(ds_for(dataset), now)["alerts"]


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
    n = ds.t_last if now is None else min(now, ds.t_last)
    return {"asset": asset, "metric": metric, "points": _series(ds, asset, metric, n, hours)}


@app.get("/facilities/{fac_id}")
def facility(fac_id: str, dataset: Optional[str] = None, hours: float = 72, now: Optional[int] = None):
    ds = ds_for(dataset)
    if fac_id not in ds.facilities:
        raise HTTPException(404, f"facility {fac_id} not found")
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
        **card, "dataset": ds.name, "now": tri["now"], "readings": readings, "series": sers,
        "alerts": [a for a in tri["alerts"] if a["facility_id"] == fac_id],
        "events": [e for e in tri["events"] if e["facility_id"] == fac_id][::-1],
        "pump_max_flow_bpd": f.pump["max_flow_bpd"],
        "start_level_pct": f.pump["start_level_pct"], "stop_level_pct": f.pump["stop_level_pct"],
        "wells_detail": [{**w, "rev_per_hour": round(ds.well_rev_per_hour(w), 2)} for w in f.wells],
        "response_min": f.response_min, "cycle_min": f.cycle_min,
        "flags": [flag_row(r) for r in flag_rows],
        "assets": {"tank": f.tank["id"], "pump": f.pump["id"], "pipeline": f.pipeline["id"],
                   "wells": [w["id"] for w in f.wells]},
    }


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
    tri = run_triage(ds, now)
    h = build_handoff(tri)
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
def voice_alerts(dataset: Optional[str] = None):
    tri = run_triage(ds_for(dataset))
    return [{"event_id": a["event_id"], "facility_id": a["facility_id"], "text": spoken(a)} for a in tri["alerts"]]


@app.get("/voice/facility/{fac_id}")
def voice_facility(fac_id: str, dataset: Optional[str] = None):
    ds = ds_for(dataset)
    if fac_id not in ds.facilities:
        raise HTTPException(404, "facility not found")
    tri = run_triage(ds)
    c = _facility_card(ds, tri, fac_id)
    mine = [spoken(a) for a in tri["alerts"] if a["facility_id"] == fac_id]
    base = f"{c['name']}: tank {c['level_pct']:.0f} percent full, pump {'running' if c['pump_status'] == 1 else 'fault' if c['pump_status'] == 2 else 'stopped'}."
    return {"facility_id": fac_id, "text": " ".join([base] + (mine or ["No problems in progress."]))}


class VisionIn(BaseModel):
    image_url: str  # https URL or a data: URL of one camera frame


@app.post("/vision/check")
def vision_check(body: VisionIn):
    """One glasses camera frame -> possible leak / smoke / damage / none. A human still confirms or dismisses."""
    return vision.check_image(body.image_url)


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


@app.get("/report")
def get_report(shift_id: Optional[str] = None, dataset: Optional[str] = None):
    with db() as c:
        shift = get_shift(c, shift_id, dataset)
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
    }


def level_for(score: int) -> str:
    return "high" if score >= 60 else "medium" if score >= 30 else "low"


@app.get("/next-shift")
def get_next_shift(shift_id: Optional[str] = None, dataset: Optional[str] = None):
    """
    Simple, explainable scoring per facility (dismissed flags are ignored):
      +50 confirmed flag last shift   +25 unreviewed flag last shift
      +30/+20/+10 worst flag type (smoke/leak/damage)   +10 per previous night flagged (last 7 days)
      +15 stop planned but missed
      +60 / +40 / +20 sensor problem still in progress (pump failure / leak / worn pump), latest shift only
    """
    with db() as c:
        shift = get_shift(c, shift_id, dataset)
        past_rows = c.execute(
            """SELECT f.*, s.date AS shift_date FROM flags f JOIN shifts s ON s.id = f.shift_id
               WHERE s.dataset = ? AND s.date < ? AND s.date >= ? AND f.status != 'dismissed'""",
            (shift["dataset"], shift["date"], (date.fromisoformat(shift["date"]) - timedelta(days=HISTORY_DAYS)).isoformat())).fetchall()
        newest = c.execute("SELECT id FROM shifts WHERE dataset = ? ORDER BY started_at DESC LIMIT 1", (shift["dataset"],)).fetchone()
    ds = ds_for(shift["dataset"])
    now_flags = [f for f in shift["flags"] if f["status"] != "dismissed"]
    past_flags = [dict(flag_row(r), shift_date=r["shift_date"]) for r in past_rows]
    walked = set(shift["route_walked"])
    missed = {s for s in shift["route_planned"] if s not in walked}
    sensor = {}
    if newest and newest["id"] == shift["id"]:
        for a in run_triage(ds)["alerts"]:
            sensor.setdefault(a["facility_id"], []).append(a)

    out = []
    for eid in {f["equipment_id"] for f in now_flags + past_flags} | missed | set(sensor):
        now = [f for f in now_flags if f["equipment_id"] == eid]
        past = [f for f in past_flags if f["equipment_id"] == eid]
        score, reasons = 0, []
        for a in sorted(sensor.get(eid, []), key=lambda a: -SENSOR_SCORE[a["category"]]):
            score += SENSOR_SCORE[a["category"]]
            what = {"pump_failure": "Pump failure in progress", "pipeline_leak": "Possible pipeline leak",
                    "pump_degradation": "Pump wearing out"}[a["category"]]
            extra = ""
            if a["category"] == "pump_failure" and a.get("hours_to_limit"):
                extra = f", tank hits shutdown in {a['hours_to_limit']['p50']:.1f} h. {a['action_text']}"
            reasons.append(f"{what} (sensor data){extra}")
        confirmed = [f for f in now if f["status"] == "confirmed"]
        pending = [f for f in now if f["status"] == "pending"]
        if confirmed:
            score += 50
            reasons.append(f"Operator confirmed a {confirmed[0]['type']} flag last shift")
        if pending:
            score += 25
            reasons.append(f"Unreviewed {pending[0]['type']} flag from last shift")
        everything = now + past
        if everything:
            worst = max(everything, key=lambda f: TYPE_WEIGHT[f["type"]])["type"]
            score += TYPE_WEIGHT[worst]
            reasons.append(f"Worst flag type seen here: {worst}")
        for f in now:
            if f["trigger"] == "data" and f["reason"]:
                reasons.append(f"Data check: {f['reason']}")
                break
        nights = len({f["shift_date"] for f in past})
        if nights:
            score += 10 * nights
            reasons.append(f"Flagged on {nights} previous night{'s' if nights > 1 else ''}, repeat issue")
        if eid in missed:
            score += 15
            reasons.append("Stop was planned last shift but not checked")
        if score == 0:
            continue
        latest = max(everything, key=lambda f: f["timestamp"]) if everything else None
        out.append({"equipment_id": eid, "location": fac_name(eid) if eid in ds.facilities else eid, "score": score,
                    "level": level_for(score), "reasons": reasons, "latest_flag": latest})
    return sorted(out, key=lambda p: p["score"], reverse=True)
