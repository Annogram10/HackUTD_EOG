"""
Item 8 regressions and the evaluate/score baseline guard.
These DEV tests read dev/answer_keys to grade the detector; the app itself never opens an answer key.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import main
from app import dataset as D
from app.detect import detect_events

ROOT = Path(__file__).resolve().parents[2]
PY = sys.executable


def _key(name):
    return json.loads((ROOT / "dev" / "answer_keys" / f"{name}.json").read_text())


def test_events_ending_at_a_stop_end_on_time():
    """Wear that ended in a fault (EVENT_5/7/8) and problems that ended while the pump was stopped (EVENT_2/16/17)
    used to end 4-7 h late, at the restart. Now within 1 h."""
    ds = D.load("full_week")
    ours = detect_events(ds)
    for k in _key("full_week"):
        if k["id"] not in ("EVENT_2", "EVENT_5", "EVENT_7", "EVENT_8", "EVENT_16", "EVENT_17"):
            continue
        e = min((e for e in ours if e["asset_id"] == k["asset"]), key=lambda e: abs(e["onset_unix"] - k["onset_unix"]))
        assert e["status"] == "resolved", k["id"]
        assert abs(e["end_unix"] - k["end_unix"]) <= 3600, (k["id"], (e["end_unix"] - k["end_unix"]) / 3600)


def test_stale_leak_while_pump_stopped_cannot_alarm():
    """Snapshot 10T0900: S2_PIPELINE_C's leak was repaired while its pump was off, so the data cannot show the end.
    It may stay 'ongoing', but it must be low severity, never an alarm and never an auto flag."""
    ds = D.load("snapshot_2026-10-10T0900")
    tri = main.run_triage(ds)
    leak = next(a for a in tri["alerts"] if a["asset_id"] == "S2_PIPELINE_C")
    assert leak["severity"] == "low"
    out = main.risk_mod.assess(ds, None, use_ai=False)
    assert "S2_FACILITY_C" not in {f["facility_id"] for f in out["flaggable"]}
    assert not (out["alarm"] and "S2_FACILITY_C" in (out["alarm_id"] or ""))


def test_baseline_guard():
    ev = subprocess.run([PY, str(ROOT / "dev" / "evaluate.py")], capture_output=True, text=True, cwd=ROOT).stdout
    got = dict(re.findall(r"^(\S+): matched (\d+/\d+) labelled events, 0 extra detections", ev, re.M))
    assert got == {"full_week": "23/23", "snapshot_2026-10-08T1200": "13/13",
                   "snapshot_2026-10-09T0330": "15/15", "snapshot_2026-10-10T0900": "21/21"}, ev
    sc = subprocess.run([PY, str(ROOT / "dev" / "score.py")], capture_output=True, text=True, cwd=ROOT).stdout
    assert "TOTAL across shared-fleet snapshots: ours $7,999 vs reference $8,013" in sc, sc
    assert sc.count("alert order (pump failures): MATCH") == 3, sc
