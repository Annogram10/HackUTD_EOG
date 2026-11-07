"""
Fake iPhone uploads for every dataset in data/, so the shift screens have something to show.

One shift per night (18:00 to 06:00 UTC). Flags come from the problems the detector finds in that
dataset's telemetry (so they line up with the real sensor data), plus a camera flag for each leak.
Statuses, operators and notes are invented demo data, standing in for what the glasses would record.

Run:  python seed.py          (wipes shifts and flags, then re-seeds every dataset)
      python seed.py test     (re-seeds only the dataset called "test", leaves the others alone)
"""

from datetime import datetime, timedelta, timezone

from app import dataset as D
from app.detect import detect_events
from app.triage import fac_name
from main import ShiftUpload, db, init_db, save_shift

OPERATORS = ["J. Ramirez", "M. Chen", "A. Okafor", "S. Patel", "L. Nguyen"]
TYPE = {"pipeline_leak": "leak", "pump_failure": "damage", "pump_degradation": "damage"}


def utc(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).replace(tzinfo=None)


def iso(dt):
    return dt.isoformat(timespec="seconds")


def build(ds):
    events = detect_events(ds)
    first = utc(ds.t_first).date()
    last = utc(ds.t_last)
    systems = list(ds.systems)
    shifts = []
    n = 0
    day = first
    while datetime.combine(day, datetime.min.time()) + timedelta(hours=18) < last:
        start = datetime.combine(day, datetime.min.time()) + timedelta(hours=18)
        end = start + timedelta(hours=12)
        ended = min(end, last)
        sid = systems[n % len(systems)]
        planned = list(ds.systems[sid]["facility_ids"])
        walked = planned[:-1] if (n % 3 == 2 and len(planned) > 1) else planned
        flags = []
        for e in events:
            onset = utc(e["onset_unix"])
            if not (start <= onset < end):
                continue
            k = len(flags)
            status = "pending" if (e["status"] == "ongoing" or k % 3 == 2) else "confirmed"
            flags.append({
                "id": f"f_{ds.name[:4]}_{e['event_id'][3:]}", "type": TYPE[e["category"]], "location": e["facility_id"],
                "photo_url": f"/photos/{e['event_id']}.jpg", "timestamp": iso(onset + timedelta(minutes=20)), "status": status,
                "note": ("operator: confirmed on site, pump is off" if (status == "confirmed" and e["category"] == "pump_failure") else None),
                "trigger": "data", "reason": e["evidence"][0],
            })
            if e["category"] == "pipeline_leak":
                flags.append({
                    "id": f"c_{ds.name[:4]}_{e['event_id'][3:]}", "type": "leak", "location": e["facility_id"],
                    "photo_url": f"/photos/c_{e['event_id']}.jpg", "timestamp": iso(onset + timedelta(hours=1, minutes=5)),
                    "status": status, "note": "operator: wet ground along the pipeline" if status == "confirmed" else None,
                    "trigger": "camera", "reason": None,
                })
        shifts.append({
            "id": f"shift-{ds.name}-{day.isoformat()}", "dataset": ds.name, "date": day.isoformat(),
            "operator": OPERATORS[n % len(OPERATORS)], "started_at": iso(start), "ended_at": iso(ended),
            "uploaded_at": iso(ended + timedelta(minutes=12)), "route_planned": planned, "route_walked": walked,
            "flags": flags,
        })
        n += 1
        day += timedelta(days=1)
    return shifts


def main():
    import sys

    init_db()
    only = sys.argv[1] if len(sys.argv) > 1 else None
    with db() as c:
        if only:
            c.execute("DELETE FROM flags WHERE shift_id IN (SELECT id FROM shifts WHERE dataset = ?)", (only,))
            c.execute("DELETE FROM shifts WHERE dataset = ?", (only,))
        else:
            c.execute("DELETE FROM flags")
            c.execute("DELETE FROM shifts")
        total = 0
        for d in D.list_datasets():
            if only and d["name"] != only:
                continue
            ds = D.load(d["name"])
            for s in build(ds):
                save_shift(c, ShiftUpload(**s))
                total += 1
    print(f"Seeded {total} shifts" + (f" for {only}." if only else f" across {len(D.list_datasets())} datasets."))


if __name__ == "__main__":
    main()
