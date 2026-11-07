"""
NightShift backend.

Dashboard endpoints (Vikram):
    GET  /flags          tonight's flags (add ?scope=all for everything)
    GET  /report         shift summary
    GET  /next-shift     ranked priorities with reasons

Shared endpoints (the iPhone app / detection code calls these):
    POST /flags                    create a flag
    POST /flag/{id}/confirm        operator confirmed it
    POST /flag/{id}/dismiss        operator dismissed it
    POST /flag/{id}/note           attach a voice note

Run:  uvicorn main:app --reload --host 0.0.0.0 --port 8000
"""

import sqlite3
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal, Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

BASE = Path(__file__).parent
DB_PATH = BASE / "nightshift.db"
PHOTOS = BASE / "photos"
PHOTOS.mkdir(exist_ok=True)

SHIFT_START_HOUR = 18  # night shift starts at 6 PM
TYPE_WEIGHT = {"smoke": 30, "leak": 20, "damage": 10}
HISTORY_DAYS = 7

app = FastAPI(title="NightShift API")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)
app.mount("/photos", StaticFiles(directory=PHOTOS), name="photos")


# ---------- database ----------

def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with db() as c:
        c.execute(
            """CREATE TABLE IF NOT EXISTS flags (
                id         TEXT PRIMARY KEY,
                type       TEXT NOT NULL,
                location   TEXT NOT NULL,
                photo_url  TEXT NOT NULL DEFAULT '',
                timestamp  TEXT NOT NULL,
                status     TEXT NOT NULL DEFAULT 'pending',
                note       TEXT
            )"""
        )


init_db()


def all_flags() -> list[dict]:
    with db() as c:
        rows = c.execute("SELECT * FROM flags ORDER BY timestamp DESC").fetchall()
    return [dict(r) for r in rows]


def shift_start(now: Optional[datetime] = None) -> datetime:
    """Most recent 6 PM. Anything after this counts as 'tonight'."""
    now = now or datetime.now()
    start = now.replace(hour=SHIFT_START_HOUR, minute=0, second=0, microsecond=0)
    return start if now >= start else start - timedelta(days=1)


def split_by_shift(flags: list[dict]) -> tuple[list[dict], list[dict]]:
    start = shift_start().isoformat(timespec="seconds")
    tonight = [f for f in flags if f["timestamp"] >= start]
    history = [f for f in flags if f["timestamp"] < start]
    return tonight, history


# ---------- models ----------

class FlagIn(BaseModel):
    type: Literal["leak", "smoke", "damage"]
    location: str
    photo_url: str = ""
    note: Optional[str] = None


class NoteIn(BaseModel):
    note: str


# ---------- shared endpoints ----------

@app.get("/health")
def health():
    return {"ok": True}


@app.post("/flags")
def create_flag(flag: FlagIn):
    new = {
        "id": f"f_{uuid.uuid4().hex[:6]}",
        "type": flag.type,
        "location": flag.location,
        "photo_url": flag.photo_url,
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "status": "pending",
        "note": flag.note,
    }
    with db() as c:
        c.execute(
            "INSERT INTO flags VALUES (:id, :type, :location, :photo_url, :timestamp, :status, :note)",
            new,
        )
    return new


def set_status(flag_id: str, status: str) -> dict:
    with db() as c:
        cur = c.execute("UPDATE flags SET status = ? WHERE id = ?", (status, flag_id))
        if cur.rowcount == 0:
            raise HTTPException(404, f"flag {flag_id} not found")
        row = c.execute("SELECT * FROM flags WHERE id = ?", (flag_id,)).fetchone()
    return dict(row)


@app.post("/flag/{flag_id}/confirm")
def confirm_flag(flag_id: str):
    return set_status(flag_id, "confirmed")


@app.post("/flag/{flag_id}/dismiss")
def dismiss_flag(flag_id: str):
    return set_status(flag_id, "dismissed")


@app.post("/flag/{flag_id}/note")
def add_note(flag_id: str, body: NoteIn):
    with db() as c:
        cur = c.execute("UPDATE flags SET note = ? WHERE id = ?", (body.note, flag_id))
        if cur.rowcount == 0:
            raise HTTPException(404, f"flag {flag_id} not found")
        row = c.execute("SELECT * FROM flags WHERE id = ?", (flag_id,)).fetchone()
    return dict(row)


# ---------- dashboard endpoints ----------

@app.get("/flags")
def get_flags(scope: Literal["shift", "all"] = "shift"):
    flags = all_flags()
    if scope == "all":
        return flags
    tonight, _ = split_by_shift(flags)
    return tonight


@app.get("/report")
def get_report():
    tonight, _ = split_by_shift(all_flags())

    by_type: dict[str, int] = {}
    for f in tonight:
        by_type[f["type"]] = by_type.get(f["type"], 0) + 1

    def with_status(s: str) -> list[dict]:
        return [f for f in tonight if f["status"] == s]

    return {
        "shift_start": shift_start().isoformat(timespec="seconds"),
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "totals": {
            "total": len(tonight),
            "confirmed": len(with_status("confirmed")),
            "pending": len(with_status("pending")),
            "dismissed": len(with_status("dismissed")),
        },
        "by_type": by_type,
        "confirmed": with_status("confirmed"),
        "pending": with_status("pending"),
        "notes": [
            {"location": f["location"], "note": f["note"], "timestamp": f["timestamp"]}
            for f in tonight
            if f["note"]
        ],
    }


def level_for(score: int) -> str:
    if score >= 60:
        return "high"
    if score >= 30:
        return "medium"
    return "low"


@app.get("/next-shift")
def get_next_shift():
    """
    Simple, explainable scoring per location (dismissed flags are ignored):
      +50  confirmed flag tonight
      +25  unreviewed flag tonight
      +30 / +20 / +10  worst flag type (smoke / leak / damage)
      +10  per previous night it was flagged (last 7 days)
    """
    tonight, history = split_by_shift(all_flags())
    cutoff = (shift_start() - timedelta(days=HISTORY_DAYS)).isoformat(timespec="seconds")
    history = [f for f in history if f["timestamp"] >= cutoff]

    locations = {f["location"] for f in tonight + history}
    out = []

    for loc in locations:
        now = [f for f in tonight if f["location"] == loc and f["status"] != "dismissed"]
        past = [f for f in history if f["location"] == loc and f["status"] != "dismissed"]
        if not now and not past:
            continue

        score = 0
        reasons = []

        confirmed = [f for f in now if f["status"] == "confirmed"]
        pending = [f for f in now if f["status"] == "pending"]
        if confirmed:
            score += 50
            reasons.append(f"Confirmed {confirmed[0]['type']} tonight")
        if pending:
            score += 25
            reasons.append(f"Unreviewed {pending[0]['type']} flag from tonight")

        everything = now + past
        worst = max(TYPE_WEIGHT.get(f["type"], 0) for f in everything)
        score += worst
        if worst == TYPE_WEIGHT["smoke"]:
            reasons.append("Smoke is the highest-severity flag type")

        past_nights = len({f["timestamp"][:10] for f in past})
        if past_nights:
            score += 10 * past_nights
            s = "s" if past_nights > 1 else ""
            reasons.append(f"Flagged {past_nights} previous night{s}, repeat issue")

        latest = max(everything, key=lambda f: f["timestamp"])
        out.append(
            {
                "location": loc,
                "score": score,
                "level": level_for(score),
                "reasons": reasons,
                "latest_flag": latest,
            }
        )

    return sorted(out, key=lambda p: p["score"], reverse=True)
