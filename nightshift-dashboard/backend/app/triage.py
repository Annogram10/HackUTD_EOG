"""
The triage pipeline: detect problems -> countdown -> cheapest plan (shared trucks) -> order the alerts.
Everything numeric comes from code in this module and its neighbours. Nothing here uses AI.
"""

from typing import Optional

from . import optimize as opt
from .dataset import Dataset, iso
from .detect import detect_events
from .forecast import current_state, forecast_shutdown
from .lru import LRU
from .timeutil import parse_ts

_cache = LRU(256)  # one entry per (dataset, moment)

# ---------- one severity scale for everything (map, next shift, risk colour, alarm, handoff, dashboard) ----------
# high   -> red, the alarm fires:  the tank already tripped, or a pump failure whose tank reaches shutdown before
#                                  the repair ends
# medium -> amber, check soon:     a pump failure the tank can wait out, or a sizeable pipeline leak
# low    -> green, keep an eye on: a worn pump, or a small leak (or one that cannot be measured while the pump is off)
FORECAST_QUANTILE = "p10"  # early-warning forecast decides "before the repair ends": a missed alarm costs more than a false one
LEAK_MISSING_MEDIUM = 0.06  # a leak is "check soon" when 6% or more of the water the pump sends never arrives
SEVERITY_RANK = {"high": 3, "medium": 2, "low": 1}
SEVERITY_COLOR = {"high": "red", "medium": "amber", "low": "green"}


_unix = parse_ts


def drop(ds: Dataset, a: dict, now: int):
    """(share of water missing, share of rated flow lost) over the last 3 h of running readings, or None."""
    fac = ds.facilities[a["facility_id"]]
    pump, pipe = fac.pump["id"], fac.pipeline["id"]
    lo = now - 3 * 3600
    run = ds.wide[(pump, "status")].loc[lo:now] == 1
    fl = ds.wide[(pump, "flow_bpd")].loc[lo:now][run]
    rv = ds.wide[(pipe, "receive_flow_bpd")].loc[lo:now][run]
    if len(fl) < 4:
        return None
    flow = float(fl.mean())
    return 1 - float(rv.mean()) / max(flow, 1.0), 1 - flow / fac.pump["max_flow_bpd"]


def repair_hours_left(a: dict, now: int):
    return (_unix(a["repair_end_ts"]) - now) / 3600 if a.get("repair_end_ts") else None


def severity(a: dict, now: int, ds: Dataset) -> str:
    """"high" | "medium" | "low" for one alert. The single rule every screen and the alarm derive from."""
    if a["category"] == "pump_failure":
        if a.get("tripped"):
            return "high"
        h, left = a.get("hours_to_limit"), repair_hours_left(a, now)
        if h and left is not None and h[FORECAST_QUANTILE] < left:
            return "high"
        return "medium"
    if a["category"] == "pipeline_leak":
        d = drop(ds, a, now)
        return "medium" if d is not None and d[0] >= LEAK_MISSING_MEDIUM else "low"
    return "low"  # pump_degradation


def worst_severity(alerts: list):
    return max((a["severity"] for a in alerts), key=SEVERITY_RANK.get, default=None)


def fac_name(fac_id: str) -> str:
    return fac_id.replace("_FACILITY_", " Facility ").replace("_", " ")


def money(x: float) -> str:
    return f"${x:,.0f}"


def _ctx(ds: Dataset, ev: dict, now: int) -> Optional[opt.Ctx]:
    f = ds.facilities[ev["facility_id"]]
    st = current_state(ds, f.id, now)
    horizon = (ev["onset_unix"] + ds.repair_hours * 3600 - now) / 60.0
    if horizon <= 0 or st["tripped"]:
        return None
    producing = [w for w in st["wells"] if w["producing"] and w["water_bpd"] > 0]
    trk = ds.ops["emergency_trucking"]
    return opt.Ctx(
        event_id=ev["event_id"], facility_id=f.id, capacity=st["capacity_bbl"], level_pct=st["level_pct"],
        shutdown_pct=st["shutdown_pct"], wells=producing, horizon_min=horizon,
        response_min=f.response_min, cycle_min=f.cycle_min,
        truck_bbl=trk["truck_capacity_bbl"], trip_cost=trk["cost_per_trip"],
    )


def _plan_json(c: opt.Ctx, p: dict, now: int, label: str) -> dict:
    actions = []
    if p["trucks"]:
        actions.append({"type": "dispatch_truck", "facility_id": c.facility_id, "trucks": p["trucks"],
                        "trips_per_truck": p["trips"]})
    if p["shut_ins"]:
        groups: dict = {}
        for w, s in p["shut_ins"].items():
            groups.setdefault(round(s), []).append(w)
        for start, wells in sorted(groups.items()):
            actions.append({"type": "shut_in_wells", "wells": wells, "start_after_min": start})
    if not actions:
        actions.append({"type": "none"})
    return {
        "label": label, "trucks": p["trucks"], "trips_per_truck": p["trips"], "cost": round(p["cost"], 2),
        "shut_ins": [{"well": w, "start_after_min": round(s)} for w, s in sorted(p["shut_ins"].items(), key=lambda x: x[1])],
        "tank_trips": p["tripped"],
        "trip_ts": iso(now + p["trip_min"] * 60) if p["tripped"] else None,
        "actions": actions,
    }


def _describe(plan: dict) -> str:
    bits = []
    if plan["trucks"]:
        t, k = plan["trucks"], plan["trips_per_truck"]
        bits.append(f"send {t} truck{'s' if t > 1 else ''} ({k} trip{'s' if k > 1 else ''} each)")
    for s in plan["shut_ins"]:
        when = "now" if s["start_after_min"] <= 0 else f"in {s['start_after_min']} min"
        bits.append(f"shut in {s['well']} {when}")
    if not bits:
        bits.append("no action, the tank reaches shutdown" if plan["tank_trips"] else "no action needed")
    return "Proposed plan for supervisor approval: " + ", ".join(bits)


def _timeline(c: opt.Ctx, p: dict, now: int) -> list:
    sim = opt.simulate(c, p["trucks"], p["trips"], p["shut_ins"])
    pts = list(sim["points"])
    if sim["trip_min"] is not None:  # wells are shut in, so the level holds until the repair ends
        pts.append((c.horizon_min, pts[-1][1]))
    return [{"ts": int(now + t * 60), "level_pct": round(v / c.capacity * 100, 2)} for t, v in pts]


def _marks(c: opt.Ctx, p: dict) -> list:
    marks = []
    if p["trucks"]:
        for j, t in enumerate(opt.arrivals(c, p["trips"])):
            marks.append({"min": round(t), "label": f"{p['trucks']} truck{'s' if p['trucks'] > 1 else ''} arrive" if j == 0 else "trucks return"})
    for w, s in p["shut_ins"].items():
        marks.append({"min": round(s), "label": f"shut in {w.split('_')[-1]}"})
    return sorted(marks, key=lambda m: m["min"])


def run_triage(ds: Dataset, now: Optional[int] = None) -> dict:
    now = ds.t_last if now is None else min(int(now), ds.t_last)
    key = (ds.name, ds.token, now)
    hit = _cache.get(key)
    if hit is not None:
        return hit

    events = detect_events(ds, now)
    alerts, by_sys = [], {}
    for e in events:
        if e["status"] != "ongoing":
            continue
        a = {**e, "facility_name": fac_name(e["facility_id"]), "lost_revenue_per_hour": ds.revenue_per_hour(e["facility_id"])}
        if e["category"] == "pump_failure":
            fc = forecast_shutdown(ds, e["facility_id"], now)
            a.update(level_pct=round(fc["level_pct"], 1), hours_to_limit=fc["hours_to_limit"], tripped=fc["tripped"],
                     repair_end_ts=iso(e["onset_unix"] + ds.repair_hours * 3600))
            c = _ctx(ds, e, now)
            a["_ctx"] = c
            if c:
                by_sys.setdefault(e["system_id"], []).append(a)
            else:
                a["plan"] = {"label": "Already shut in", "trucks": 0, "trips_per_truck": 0, "cost": 0, "shut_ins": [],
                             "tank_trips": a["tripped"], "trip_ts": None, "actions": [{"type": "none"}]}
                a["options"] = []
                a["recommended_actions"] = a["plan"]["actions"]
                a["action_text"] = ("The tank already reached shutdown; wells stay shut in until the repair ends"
                                    if a["tripped"] else "Repair window has passed")
        else:
            a.update(hours_to_limit=None, level_pct=None,
                     recommended_actions=[{"type": "field_inspection", "asset_id": e["asset_id"]}],
                     action_text="Proposed for supervisor approval: an inspector checks " + e["asset_id"],
                     plan=None, options=[])
        alerts.append(a)

    # plan each system's failures together: they share the fleet
    shared = {}
    for sid, group in by_sys.items():
        fleet = ds.systems[sid]["fleet_size"]
        ctxs = [a["_ctx"] for a in group]
        res = opt.optimize_system(ctxs, fleet)
        shared[sid] = {"fleet": fleet, "trucks_used": res["trucks_used"], "total_cost": round(res["total_cost"], 2),
                       "events": [a["event_id"] for a in group]}
        for a in group:
            c = a["_ctx"]
            chosen = res["chosen"][c.event_id]
            plan = _plan_json(c, chosen, now, "Recommended")
            opts = [
                _plan_json(c, opt.do_nothing(c), now, "Do nothing"),
                _plan_json(c, opt.shut_in_only(c), now, "Shut in wells only"),
            ]
            for n in range(1, fleet + 1):
                opts.append(_plan_json(c, res["per_trucks"][c.event_id][n], now, f"{n} truck{'s' if n > 1 else ''} (+ shut-ins if needed)"))
            a["plan"] = plan
            a["options"] = opts
            a["recommended_actions"] = plan["actions"]
            a["trucks_shared_with"] = [x for x in shared[sid]["events"] if x != a["event_id"]]
            a["action_text"] = _describe(plan) + f", {money(plan['cost'])}"
            a["whatif"] = {
                "shutdown_pct": c.shutdown_pct, "warning_pct": ds.limits["warning"],
                "repair_end_ts": a["repair_end_ts"],
                "do_nothing": _timeline(c, opt.do_nothing(c), now),
                "with_plan": _timeline(c, chosen, now),
                "marks": _marks(c, chosen),
            }
            del a["_ctx"]
    for a in alerts:
        a.pop("_ctx", None)

    def order(a):
        if a["category"] == "pump_failure":
            h = (a["hours_to_limit"] or {}).get("p50")
            return (0, h if h is not None else 1e9, -a["lost_revenue_per_hour"])
        return (1, 0, 0 if a["category"] == "pipeline_leak" else 1)

    alerts.sort(key=order)
    for i, a in enumerate(alerts, 1):
        a["order"] = i
        a["severity"] = severity(a, now, ds)

    out = {
        "dataset": ds.name, "now": now, "now_ts": iso(now), "t_first": ds.t_first, "t_first_ts": iso(ds.t_first),
        "alerts": alerts, "events": events, "shared_trucks": shared,
    }
    _cache[key] = out
    return out


def facility_status(triage: dict, fac_id: str) -> str:
    """tripped | failure | leak | worn | ok, worst first."""
    rank = {"tripped": 4, "failure": 3, "leak": 2, "worn": 1, "ok": 0}
    worst = "ok"
    for a in triage["alerts"]:
        if a["facility_id"] != fac_id:
            continue
        s = {"pump_failure": "tripped" if a.get("tripped") else "failure", "pipeline_leak": "leak",
             "pump_degradation": "worn"}[a["category"]]
        if rank[s] > rank[worst]:
            worst = s
    return worst


def events_json(triage: dict) -> list:
    """EOG's events.json shape (SPEC.md)."""
    out = []
    for e in triage["events"]:
        a = next((x for x in triage["alerts"] if x["event_id"] == e["event_id"]), None)
        row = {
            "event_id": e["event_id"], "system_id": e["system_id"], "facility_id": e["facility_id"],
            "asset_id": e["asset_id"], "category": e["category"], "status": e["status"],
            "onset_ts": e["onset_ts"], "onset_unix": e["onset_unix"], "end_ts": e["end_ts"], "end_unix": e["end_unix"],
            "confidence": e["confidence"], "evidence": e["evidence"],
        }
        if a and e["category"] == "pump_failure":
            row["level_pct"] = a["level_pct"]
            row["hours_to_limit"] = a["hours_to_limit"]
        if a:
            row["recommended_actions"] = a["recommended_actions"]
            if a.get("plan"):
                row["est_cost"] = a["plan"]["cost"]
        out.append(row)
    return out
