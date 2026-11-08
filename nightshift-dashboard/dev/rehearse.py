"""
Run every screen's API calls against one dataset and check the results make sense. DEV ONLY.
Usage: backend/.venv/bin/python dev/rehearse.py [dataset]     (default: test)
"""
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402

name = sys.argv[1] if len(sys.argv) > 1 else "test"
c = TestClient(main.app)
problems = []


def check(label, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {label} {detail}")
    if not ok:
        problems.append(label)


def get(path, **params):
    t = time.time()
    r = c.get(path, params={"dataset": name, **params})
    return r, round(time.time() - t, 2)


print(f"Rehearsal on dataset '{name}'")
r = c.get("/datasets")
names = [d["name"] for d in r.json()]
check("dataset listed", name in names, f"(order: {names})")

r, t = get("/overview")
check("overview loads", r.status_code == 200, f"{t}s")
ov = r.json()
facs = [f for s in ov["systems"] for f in s["facilities"]]
check("systems and facilities come from the files", len(facs) > 0, f"{len(ov['systems'])} systems, {len(facs)} facilities: {[s['id'] for s in ov['systems']]}")
check("alerts found", True, f"{len(ov['alerts'])} in progress: {[(a['facility_id'], a['category']) for a in ov['alerts']]}")

for a in ov["alerts"]:
    if a["category"] == "pump_failure":
        check(f"{a['facility_id']} has countdown + plan + options", bool(a["hours_to_limit"] and a["plan"] and a["options"] and a["whatif"]),
              f"{a['hours_to_limit']['p50']} h, {a['action_text']}")
        wi = a["whatif"]
        peak = max(p["level_pct"] for p in wi["with_plan"])
        check(f"{a['facility_id']} plan keeps tank under {wi['shutdown_pct']}%", peak < wi["shutdown_pct"] or a["plan"]["tank_trips"], f"peak {peak}%")

bad = 0
for f in facs:
    r, t = get(f"/facilities/{f['id']}")
    if r.status_code != 200 or not r.json()["series"] or not r.json()["readings"]:
        bad += 1
        print("   facility page problem:", f["id"], r.status_code)
check("every facility page loads with readings + trends", bad == 0, f"({len(facs)} checked)")

# any sensor chart
f0 = facs[0]
for asset, metric in [(f0["tank_id"], "level_pct"), (f0["pump_id"], "flow_bpd"), (f0["pipeline_id"], "pressure_psi"), (f0["wells"][0]["id"], "water_bpd")]:
    r, _ = get("/series", asset=asset, metric=metric, hours=24)
    check(f"series {asset}/{metric}", r.status_code == 200 and len(r.json()["points"]) > 5)

r, t = get("/handoff")
check("handoff", r.status_code == 200 and r.json()["lines"], f"{t}s")

r, _ = get("/events.json")
ev = r.json()
need = {"event_id", "system_id", "facility_id", "asset_id", "category", "status", "onset_ts", "onset_unix", "end_ts", "end_unix", "confidence", "evidence"}
check("events.json has EOG's fields", r.status_code == 200 and all(need <= set(e) for e in ev), f"{len(ev)} events")
check("events.json categories valid", all(e["category"] in ("pump_failure", "pipeline_leak", "pump_degradation") for e in ev))
check("resolved events have end_ts", all(e["end_ts"] for e in ev if e["status"] == "resolved"))
check("ongoing pump failures have hours_to_limit", all(e.get("hours_to_limit") for e in ev if e["status"] == "ongoing" and e["category"] == "pump_failure"))
check("leaks/wear have null hours_to_limit", all(not e.get("hours_to_limit") for e in ev if e["category"] != "pump_failure"))

r, _ = get("/voice/alerts")
check("voice alerts", r.status_code == 200 and all(x["text"] for x in r.json()), f"{len(r.json())} sentences")
r, _ = get(f"/voice/facility/{f0['id']}")
check("voice facility status", r.status_code == 200 and "percent full" in r.json()["text"], r.json()["text"][:80])

r, _ = get("/shifts")
shifts = r.json()
check("shifts seeded for this dataset (run: python backend/seed.py " + name + ")", len(shifts) > 0, f"{len(shifts)} shifts")
if shifts:
    sid = shifts[0]["id"]
    r = c.get("/report", params={"shift_id": sid}); check("handover report", r.status_code == 200)
    r = c.get("/next-shift", params={"shift_id": sid}); check("next-shift priorities", r.status_code == 200, f"{len(r.json())} items; top: {r.json()[0]['location'] + ' ' + str(r.json()[0]['score']) if r.json() else '-'}")

run = None
from app import agent  # noqa: E402
run = agent.get_run(name)
for _ in range(240):
    if run.status != "running":
        break
    time.sleep(0.5)
check("agent finished", run.status == "done", f"mode={run.mode} steps={len(run.steps)} error={run.error}")
tools = [s["tool"] for s in run.steps if s["kind"] == "tool"]
check("agent called detect + countdown/plan tools", "detect_events" in tools and "save_alerts" in tools, str(tools))

# nothing should ever open an answer key
import app.dataset as D  # noqa: E402
check("only the three allowed files are ever read", D.REQUIRED == ("network.json", "ops.json", "telemetry.csv"))
print("\nRESULT:", "ALL GOOD" if not problems else f"{len(problems)} PROBLEM(S): {problems}")
sys.exit(1 if problems else 0)
