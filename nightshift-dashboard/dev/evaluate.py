"""
Offline check of detection against the practice answer keys. DEV ONLY: the app never imports this
and never loads answer_key.json. Usage: python dev/evaluate.py
"""
import json
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from app import dataset, detect  # noqa: E402

f = lambda x: datetime.strptime(x, "%Y-%m-%dT%H:%M:%SZ")
for name in ["full_week", "snapshot_2026-10-08T1200", "snapshot_2026-10-09T0330", "snapshot_2026-10-10T0900"]:
    ds = dataset.load(name)
    ev = detect.detect_events(ds)
    key = json.loads((ROOT / "dev" / "answer_keys" / f"{name}.json").read_text())
    used, hits, errs, ends = set(), 0, [], []
    for k in key:
        m = [(i, e) for i, e in enumerate(ev) if i not in used and e["asset_id"] == k["asset"] and e["category"] == k["category"]
             and abs((f(e["onset_ts"]) - f(k["onset"])).total_seconds()) < 12 * 3600]
        if m:
            i, e = m[0]; used.add(i); hits += 1
            errs.append(round((f(e["onset_ts"]) - f(k["onset"])).total_seconds() / 3600, 1))
            if k["end"] and e["end_ts"]:
                ends.append(round((f(e["end_ts"]) - f(k["end"])).total_seconds() / 3600, 1))
            if e["status"] != k["status"]:
                print("   status differs:", k["id"], "detected", e["status"], "key", k["status"])
    print(f"{name}: matched {hits}/{len(key)} labelled events, {len(ev) - len(used)} extra detections")
    print("   onset error (h):", errs)
    print("   end error (h):", ends)
