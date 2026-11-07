"""
Score the app against the practice snapshots' answer keys. DEV ONLY: the app never imports this or loads answer keys.
Usage: backend/.venv/bin/python dev/score.py [--brute]
  --brute  also searches shut-in start times exhaustively (10 min grid) to confirm the optimizer isn't missing a cheaper plan.
"""
import itertools
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from app import dataset, optimize as opt, triage  # noqa: E402

SNAPS = ["snapshot_2026-10-08T1200", "snapshot_2026-10-09T0330", "snapshot_2026-10-10T0900"]
BRUTE = "--brute" in sys.argv


def ref_cost(s):
    m = re.search(r"~\$([\d,]+)", s)
    return float(m.group(1).replace(",", "")) if m else None


def brute_best(c, fleet):
    """Cheapest cost per truck count using a 10-minute grid of start times for every well (independent of the optimizer)."""
    ids = [w["id"] for w in c.wells]
    grid = [None] + [float(t) for t in range(0, int(c.horizon_min) + 1, 10)]
    best = {}
    for n in range(0, fleet + 1):
        b = 1e18
        for k in ([0] if n == 0 else range(1, opt.max_trips(c) + 1)):
            for starts in itertools.product(grid, repeat=len(ids)):
                shut = {i: s for i, s in zip(ids, starts) if s is not None}
                sim = opt.simulate(c, n, k, shut)
                b = min(b, opt.cost_of(c, n, k, shut, sim["trip_min"]))
        best[n] = b
    return best


grand_ours = grand_ref = 0
for name in SNAPS:
    ds = dataset.load(name)
    tri = triage.run_triage(ds)
    key = json.loads((ROOT / "dev" / "answer_keys" / f"{name}.json").read_text())
    ongoing = [k for k in key if k["status"] == "ongoing"]
    alerts = {a["asset_id"]: a for a in tri["alerts"]}
    print(f"\n=== {name}  (now {tri['now_ts']})")
    print(f"events in progress: key {len(ongoing)}, found {len(tri['alerts'])}, missing {[k['asset'] for k in ongoing if k['asset'] not in alerts]}, extra {[a for a in alerts if a not in {k['asset'] for k in ongoing}]}")
    rows = []
    for k in [x for x in ongoing if x["category"] == "pump_failure"]:
        a = alerts.get(k["asset"])
        if not a:
            continue
        ours = a["plan"]["cost"] if a.get("plan") else 0
        ref = ref_cost(k["reference_action"])
        rows.append((k, a, ours, ref))
        print(f"  {k['asset']:<13} level {a['level_pct']:>5} vs {k['level_final_pct']:>5} | hours {a['hours_to_limit']['p50']:>4} vs {k['hours_to_limit_final']:>4} | "
              f"order {a['order']} vs {k['order']} | cost ${ours:,.0f} vs ref ${ref:,.0f} ({ours - ref:+,.0f})")
        print(f"      ours: {a['action_text']}\n      ref : {k['reference_action']}")
    for sid, sh in tri["shared_trucks"].items():
        ref_total = sum(r[3] for r in rows if r[1]["system_id"] == sid)
        print(f"  {sid} shared fleet: ours ${sh['total_cost']:,.0f} vs ref ${ref_total:,.0f} ({sh['total_cost'] - ref_total:+,.0f}), trucks used {sh['trucks_used']}/{sh['fleet']}")
        grand_ours += sh["total_cost"]
        grand_ref += ref_total
    orders_ok = all(r[1]["order"] == r[0]["order"] or True for r in rows)
    pump_order_ours = [a["asset_id"] for a in tri["alerts"] if a["category"] == "pump_failure"]
    pump_order_key = [k["asset"] for k in sorted([x for x in ongoing if x["category"] == "pump_failure"], key=lambda x: x["order"])]
    print(f"  alert order (pump failures): {'MATCH' if pump_order_ours == pump_order_key else 'DIFFERS'}  ours {pump_order_ours}  key {pump_order_key}")

    if BRUTE:
        for sid, sh in tri["shared_trucks"].items():
            ctxs = [triage._ctx(ds, e, tri["now"]) for e in tri["events"] if e["status"] == "ongoing" and e["category"] == "pump_failure" and e["system_id"] == sid]
            ctxs = [c for c in ctxs if c]
            per = [brute_best(c, sh["fleet"]) for c in ctxs]
            best = min(sum(p[n] for p, n in zip(per, split)) for split in itertools.product(range(sh["fleet"] + 1), repeat=len(ctxs)) if sum(split) <= sh["fleet"])
            print(f"  {sid} brute-force optimum ${best:,.0f} vs ours ${sh['total_cost']:,.0f}  -> {'OK (ours <= brute)' if sh['total_cost'] <= best + 0.5 else 'OPTIMIZER MISSES A CHEAPER PLAN'}")

print(f"\nTOTAL across shared-fleet snapshots: ours ${grand_ours:,.0f} vs reference ${grand_ref:,.0f} ({grand_ours - grand_ref:+,.0f})")
