"""
Danger check at any moment in time.

1. Rules (always on, instant): RED = a pump failure whose tank will reach shutdown before the repair ends (or already has).
   AMBER = something to check soon (a leak, a worn pump, or a failure the tank can wait out). GREEN = nothing wrong.
2. The AI (Nemotron) reads the same facts and gives its own verdict and a short reason. It may RAISE the level
   but never lower it below the rules, so a bad moment can never be hidden by the model.

It only flags. It never says to operate equipment.
"""

import json
import os
import re
import urllib.request
from datetime import datetime, timezone

from . import dataset as D
from .handoff import _plan_words, spoken
from .triage import fac_name, run_triage

URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1") + "/chat/completions"
MODEL = os.environ.get("NEMOTRON_MODEL", "nvidia/nemotron-3.5-super-vl-120b-a12b")
ORDER = {"green": 0, "amber": 1, "red": 2}
# A leak or a worn pump is only "check soon" when it is a real, sizeable drop. A small decrease is fine.
# These are measured from the last 3 hours of running readings, so a slow problem is quiet at first and
# turns amber once it is big enough to matter.
LEAK_MISSING_AMBER = 0.06   # 6% or more of the water the pump sends never arrives
WEAR_LOSS_AMBER = 0.12      # the pump moves 12% or more below its rated flow
BY_RANK = {v: k for k, v in ORDER.items()}


def _unix(ts: str) -> int:
    return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp())


def _drop(ds, a: dict, now: int):
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


def _alert_level(a: dict, now: int, ds) -> tuple:
    """(level, short reason) for one alert."""
    who = fac_name(a["facility_id"])
    if a["category"] != "pump_failure":
        leak = a["category"] == "pipeline_leak"
        what = "possible pipeline leak" if leak else "pump wearing out"
        d = _drop(ds, a, now)
        if d is None:  # the pump is stopped, so the drop cannot be measured right now
            return "green", f"{who}: {what}, cannot be re-checked while the pump is stopped"
        missing, lost = d
        size = max(missing, 0) if leak else max(lost, 0)
        big = size >= (LEAK_MISSING_AMBER if leak else WEAR_LOSS_AMBER)
        detail = f"{size * 100:.0f}% of the water is missing" if leak else f"{size * 100:.0f}% below rated flow"
        if big:
            return "amber", f"{who}: {what}, {detail}, needs an inspector"
        return "green", f"{who}: {what}, minor so far ({detail}), keep an eye on it"
    if a.get("tripped"):
        return "red", f"{who}: pump failed and the tank has already reached shutdown"
    h = a.get("hours_to_limit")
    left = (_unix(a["repair_end_ts"]) - now) / 3600 if a.get("repair_end_ts") else None
    if h and left is not None and h["p50"] < left:
        return "red", f"{who}: pump failed, tank reaches shutdown in {h['p50']:.1f} h but the repair needs {left:.1f} more"
    return "amber", f"{who}: pump failed, but the tank can wait out the repair"


def rules_risk(tri: dict) -> dict:
    now = tri["now"]
    ds = D.load(tri["dataset"])
    per, reasons, level = {}, [], "green"
    for a in tri["alerts"]:
        lv, why = _alert_level(a, now, ds)
        reasons.append({"level": lv, "facility_id": a["facility_id"], "text": why})
        per[a["facility_id"]] = BY_RANK[max(ORDER[lv], ORDER.get(per.get(a["facility_id"], "green"), 0))]
        level = BY_RANK[max(ORDER[level], ORDER[lv])]
    reasons.sort(key=lambda r: -ORDER[r["level"]])
    return {"level": level, "reasons": reasons, "facilities": per}


def truck_cost(ds, a: dict) -> dict:
    """What the trucks in this alert's plan cost: price per trip x trucks x trips, and the rest of the plan (wells shut in)."""
    trk = ds.ops["emergency_trucking"]
    plan = a["plan"]
    trucks, trips = plan["trucks"], plan["trips_per_truck"]
    total = trucks * trips * trk["cost_per_trip"]
    return {"trip_price": trk["cost_per_trip"], "trip_bbl": trk["truck_capacity_bbl"], "trucks": trucks, "trips": trips,
            "trucks_total": round(total), "shut_in_total": max(0, round(plan["cost"] - total)),
            "arrive_min": ds.facilities[a["facility_id"]].response_min if trucks else None}


def _money(tri: dict) -> dict:
    """
    What the pump failures cost to fix, from the optimizer (EOG's formulas: truck trips x price per trip, plus the
    oil and gas revenue lost while a well is shut in) against doing nothing (every well shut in until the repair ends).
    """
    rows = []
    ds = D.load(tri["dataset"])
    for a in tri["alerts"]:
        if a["category"] != "pump_failure" or not a.get("plan"):
            continue
        nothing = next((o for o in a.get("options", []) if o["label"] == "Do nothing"), None)
        cost = round(a["plan"]["cost"])
        idle = round(nothing["cost"]) if nothing else None
        rows.append({"facility_id": a["facility_id"], "name": fac_name(a["facility_id"]),
                     "fix": _plan_words(a["plan"], False), "cost": cost, "do_nothing": idle, "trucks": truck_cost(ds, a),
                     "saves": max(0, idle - cost) if idle is not None else None})
    if not rows:
        return {"rows": [], "total_cost": 0, "total_do_nothing": 0, "total_saves": 0, "text": "", "from_ai": False,
                "trip_price": 0, "trip_bbl": 0}
    cost = sum(r["cost"] for r in rows)
    idle = sum(r["do_nothing"] or 0 for r in rows)
    saves = sum(r["saves"] or 0 for r in rows)
    text = f"Cheapest fix: ${cost:,}. Doing nothing: ${idle:,}. The plan saves ${saves:,}."
    return {"rows": rows, "total_cost": cost, "total_do_nothing": idle, "total_saves": saves, "text": text, "from_ai": False,
            "trip_price": rows[0]["trucks"]["trip_price"], "trip_bbl": rows[0]["trucks"]["trip_bbl"]}


_ai_cache: dict = {}


def ai_check(tri: dict, rules: dict) -> dict:
    """Nemotron's verdict on the same facts. Cached per moment."""
    key = (tri["dataset"], tri["now"], rules["level"], len(tri["alerts"]))
    if key in _ai_cache:
        return _ai_cache[key]
    k = os.environ.get("NVIDIA_API_KEY")
    if not k:
        return {"available": False, "error": "NVIDIA_API_KEY is not set"}
    now = tri["now"]
    ds = D.load(tri["dataset"])
    active = [a for a in tri["alerts"] if _alert_level(a, now, ds)[0] != "green"]
    facts = {
        "time_utc": datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "problems": [{
            "facility": fac_name(a["facility_id"]), "kind": a["category"], "tank_level_pct": a.get("level_pct"),
            "hours_until_tank_shutdown": (a.get("hours_to_limit") or {}).get("p50"),
            "tank_already_shut_down": bool(a.get("tripped")),
            "hours_until_repair_ends": round((_unix(a["repair_end_ts"]) - now) / 3600, 1) if a.get("repair_end_ts") else None,
            "cheapest_fix": _plan_words(a["plan"], False) if a.get("plan") else None,
            "cheapest_fix_cost_usd": round((a.get("plan") or {}).get("cost", 0)) or None,
            "cost_of_doing_nothing_usd": next((round(o["cost"]) for o in a.get("options", []) if o["label"] == "Do nothing"), None),
            "confidence": a["confidence"],
        } for a in active],
        "totals_usd": {k: v for k, v in _money(tri).items() if k in ("total_cost", "total_do_nothing", "total_saves")},
        "minor_issues_not_urgent": len(tri["alerts"]) - len(active),
        "rules_verdict": rules["level"],
    }
    prompt = (
        "You watch an oil-field water system at night and decide how worried a night-shift operator should be right now. "
        "Levels: green = nothing wrong; amber = something to check soon; red = danger, a tank will reach its shutdown limit "
        "before the repair ends, or already has, so people must act now. Judge only from these facts. "
        "Name facilities exactly as written in the facts (for example \"S1 Facility C\"), never as \"the tank\" or \"S1 tank\". "
        "Only red problems are danger: a leak or a worn pump is at most amber. The headline must name the facility when there is one. "
        "Do not diagnose and never tell anyone to operate or shut down equipment. "
        'Answer with JSON only: {"level": "green"|"amber"|"red", "headline": "max 10 words", "why": "one short plain sentence", "money": "one plain sentence on the cost, like: Cheapest fix: send 1 truck, $905. Doing nothing would cost $4,984. Use only dollar figures from the facts (write them with commas); empty string if there is no pump failure"}\n\n'
        + json.dumps(facts))
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}], "max_tokens": 400,
                       "temperature": 0.2, "chat_template_kwargs": {"enable_thinking": False}}).encode()
    req = urllib.request.Request(URL, body, {"Authorization": f"Bearer {k}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            text = json.loads(r.read())["choices"][0]["message"].get("content") or ""
        out = json.loads(re.search(r"\{.*\}", text, re.S).group(0))
        lv = out.get("level") if out.get("level") in ORDER else "green"
        res = {"available": True, "model": MODEL, "level": lv, "headline": str(out.get("headline", ""))[:120],
               "why": str(out.get("why", ""))[:300], "money": str(out.get("money", ""))[:300]}
        _ai_cache[key] = res
        return res
    except Exception as e:
        return {"available": False, "error": str(e)[:120]}


def assess(ds, now=None, use_ai: bool = True) -> dict:
    tri = run_triage(ds, now)
    rules = rules_risk(tri)
    active = [a for a in tri["alerts"] if _alert_level(a, tri["now"], ds)[0] != "green"]
    ai = ai_check(tri, rules) if (use_ai and active) else None  # nothing new or urgent: nothing for the AI to judge
    level = rules["level"]
    if ai and ai.get("available"):
        level = BY_RANK[max(ORDER[level], ORDER[ai["level"]])]
    red = [r for r in rules["reasons"] if r["level"] == "red"]
    alarm_ids = sorted((a["facility_id"], a["onset_unix"]) for a in tri["alerts"]
                       if _alert_level(a, tri["now"], ds)[0] == "red")
    if ai and ai.get("available") and level == "red" and not red:
        headline = ai["headline"]
    elif red:
        headline = (ai.get("headline") if ai and ai.get("available") and ai["level"] == "red" else None) or red[0]["text"]
    else:
        known = len(tri["alerts"]) - len(active)
        headline = (ai.get("headline") if ai and ai.get("available") else None) or (
            rules["reasons"][0]["text"] if active and rules["reasons"] else
            (f"Nothing urgent. {known} minor issue{'s' if known != 1 else ''} to keep an eye on" if known else "All clear"))
    flaggable = []
    for a in tri["alerts"]:
        lv, text = _alert_level(a, tri["now"], ds)
        if lv in ("red", "amber"):
            flaggable.append({"facility_id": a["facility_id"], "category": a["category"], "level": lv,
                              "onset_unix": int(a["onset_unix"]), "text": text})
    money = _money(tri)
    if ai and ai.get("available") and ai.get("money") and money["rows"]:
        real = {money["total_cost"], money["total_do_nothing"], money["total_saves"]}
        for r in money["rows"]:
            real |= {r["cost"], r["do_nothing"], r["saves"]}
        said = {int(x.replace(",", "")) for x in re.findall(r"\$([\d,]+)", ai["money"])}
        if said and said <= {x for x in real if x is not None}:
            money["text"], money["from_ai"] = ai["money"], True
    speak = ""
    if level == "red":
        speak = "Alarm. " + " ".join(spoken(a) for a in tri["alerts"] if _alert_level(a, tri["now"], ds)[0] == "red")
    elif level == "amber":
        speak = "Check soon. " + " ".join(spoken(a) for a in active[:2])
    return {
        "dataset": ds.name, "as_of": tri["now_ts"], "now": tri["now"], "level": level, "rules_level": rules["level"],
        "alarm": level == "red",
        "alarm_id": (f"{ds.name}:" + ",".join(f"{f}@{o}" for f, o in alarm_ids)) if level == "red" else None,
        "headline": headline, "reasons": rules["reasons"], "facilities": rules["facilities"],
        "ai": ai, "money": money, "flaggable": flaggable, "spoken_text": speak,
    }


_timeline_cache: dict = {}


def timeline(ds, step_min: int = 30) -> dict:
    """
    Risk across the whole dataset, for the slider. Cached until the files change.
    The main bar follows pump failures only (amber = the tank can wait out the repair, red = danger), so it has real
    quiet stretches. Leaks and worn pumps last for days, so they get their own thin strip instead of painting
    the whole bar.
    """
    key = (ds.name, ds.token, step_min)
    if key in _timeline_cache:
        return _timeline_cache[key]
    t0, t1 = int(ds.t_first), int(ds.t_last)
    start = t0 + 6 * 3600  # detection needs some history before it can judge
    pts = []
    for now in list(range(start, t1, step_min * 60)) + [t1]:
        level, slow = "green", False
        for a in run_triage(ds, now)["alerts"]:
            if a["category"] == "pump_failure":
                level = BY_RANK[max(ORDER[level], ORDER[_alert_level(a, now, ds)[0]])]
            else:
                slow = True
        pts.append((now, level, slow))

    def merge(pairs):
        out, cur = [], None
        for now, lv in pairs:
            if cur and cur["level"] == lv:
                cur["end"] = now
            else:
                cur = {"level": lv, "start": now, "end": now}
                out.append(cur)
        return [b for b in out if b["level"] != "green"]

    bands = merge([(n, lv) for n, lv, _ in pts])
    slow_bands = merge([(n, "amber" if sl else "green") for n, _, sl in pts])
    res = {"dataset": ds.name, "first": start, "last": t1, "step_s": 300, "bands": bands, "slow_bands": slow_bands,
           "alarms": [b["start"] for b in bands if b["level"] == "red"]}
    _timeline_cache[key] = res
    return res
