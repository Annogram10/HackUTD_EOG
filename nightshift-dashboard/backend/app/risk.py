"""
Danger check at any moment in time.

1. Rules (always on, instant): RED = a pump failure whose tank will reach shutdown before the repair ends (or already has).
   AMBER = something to check soon (a leak, a worn pump, or a failure the tank can wait out). GREEN = nothing wrong.
2. The AI (Nemotron) reads the same facts and adds a short second opinion (`note`). It runs in the background with
   a short timeout and never changes the level, the alarm or any number.

It only flags. It never says to operate equipment.
"""

import json
import os
import re
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from . import dataset as D
from .handoff import _plan_words, spoken
from .lru import LRU
from .timeutil import parse_ts
from .triage import (FORECAST_QUANTILE, SEVERITY_COLOR, drop, fac_name, repair_hours_left, run_triage, severity,
                     worst_severity)

URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1") + "/chat/completions"
MODEL = os.environ.get("NEMOTRON_MODEL", "nvidia/nemotron-3.5-super-vl-120b-a12b")
ORDER = {"green": 0, "amber": 1, "red": 2}
BY_RANK = {v: k for k, v in ORDER.items()}


_unix = parse_ts  # naive timestamps are UTC (the old version read them as the server's local time)


_drop = drop  # older name, used by main.py


def _alert_level(a: dict, now: int, ds) -> tuple:
    """(colour, short reason) for one alert. The colour comes from triage.severity(), nowhere else."""
    who = fac_name(a["facility_id"])
    sev = a.get("severity") or severity(a, now, ds)
    level = SEVERITY_COLOR[sev]
    if a["category"] != "pump_failure":
        leak = a["category"] == "pipeline_leak"
        what = "possible pipeline leak" if leak else "pump wearing out"
        d = drop(ds, a, now)
        if d is None:  # the pump is stopped, so the drop cannot be measured right now
            return level, f"{who}: {what}, cannot be re-checked while the pump is stopped"
        size = max(d[0], 0) if leak else max(d[1], 0)
        detail = f"{size * 100:.0f}% of the water is missing" if leak else f"{size * 100:.0f}% below rated flow"
        if sev == "medium":
            return level, f"{who}: {what}, {detail}, an inspector should check it"
        return level, f"{who}: {what}, {detail}, keep an eye on it"
    if a.get("tripped"):
        return level, f"{who}: pump failed and the tank has already reached shutdown"
    h, left = a.get("hours_to_limit"), repair_hours_left(a, now)
    if sev == "high":
        q = h[FORECAST_QUANTILE]
        return level, f"{who}: pump failed, tank may reach shutdown in {q:.1f} h but the repair needs {left:.1f} more"
    return level, f"{who}: pump failed, but the tank can wait out the repair"


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
    text = f"Proposed plan for supervisor approval: ${cost:,}. Doing nothing: ${idle:,}. The plan saves ${saves:,}."
    return {"rows": rows, "total_cost": cost, "total_do_nothing": idle, "total_saves": saves, "text": text, "from_ai": False,
            "trip_price": rows[0]["trucks"]["trip_price"], "trip_bbl": rows[0]["trucks"]["trip_bbl"]}


AI_TIMEOUT_S = 8          # one model call never holds anything longer than this
AI_FAIL_TTL_S = 60        # a failed call is remembered this long, so a dead model is not retried on every poll
_ai_cache = LRU(256)      # key -> (result, time stored)
_ai_inflight: set = set()
_ai_lock = threading.Lock()
_ai_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="nemotron")


def _ai_key(tri: dict, rules: dict) -> tuple:
    return (tri["dataset"], tri["now"], rules["level"], len(tri["alerts"]))


def cached_ai(tri: dict, rules: dict):
    """The AI opinion for this moment if one is already known (success, or a failure younger than AI_FAIL_TTL_S)."""
    with _ai_lock:
        hit = _ai_cache.get(_ai_key(tri, rules))
    if hit is None:
        return None
    res, stored = hit
    if not res.get("available") and time.time() - stored > AI_FAIL_TTL_S:
        return None
    return res


def request_ai(tri: dict, rules: dict) -> None:
    """Start the AI second opinion in the background (never blocks the caller). No-op if known or already running."""
    key = _ai_key(tri, rules)
    if cached_ai(tri, rules) is not None:
        return
    with _ai_lock:
        if key in _ai_inflight:
            return
        _ai_inflight.add(key)

    def job():
        try:
            res = ai_check(tri, rules)
        except Exception as e:  # never let a background failure go unrecorded
            res = {"available": False, "error": str(e)[:120]}
        with _ai_lock:
            _ai_cache[key] = (res, time.time())
            _ai_inflight.discard(key)

    _ai_pool.submit(job)


def ai_check(tri: dict, rules: dict) -> dict:
    """Nemotron's opinion on the same facts. Blocking: only ever called from the background pool."""
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
        'Answer with JSON only: {"level": "green"|"amber"|"red", "headline": "max 10 words", "why": "one short plain sentence", "money": "one plain sentence on the cost, worded as a proposal a supervisor approves, like: Proposed plan for supervisor approval: send 1 truck, $905. Doing nothing would cost $4,984. Use only numbers that appear in the facts (dollars with commas); empty string if there is no pump failure"}\n\n'
        + json.dumps(facts))
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}], "max_tokens": 400,
                       "temperature": 0.2, "chat_template_kwargs": {"enable_thinking": False}}).encode()
    req = urllib.request.Request(URL, body, {"Authorization": f"Bearer {k}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=AI_TIMEOUT_S) as r:
            text = json.loads(r.read())["choices"][0]["message"].get("content") or ""
        out = json.loads(re.search(r"\{.*\}", text, re.S).group(0))
        lv = out.get("level") if out.get("level") in ORDER else "green"
        known = allowed_numbers(facts)  # a sentence with a number the facts do not contain is dropped
        said = {k: str(out.get(k, ""))[:n] for k, n in (("headline", 120), ("why", 300), ("money", 300))}
        said = {k: (v if numbers_ok(v, known) else "") for k, v in said.items()}
        return {"available": True, "model": MODEL, "level": lv, **said}
    except Exception as e:
        return {"available": False, "error": str(e)[:120]}


_WORD_NUM = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
    "seventeen eighteen nineteen".split())}
_WORD_NUM.update({"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
                  "ninety": 90, "hundred": 100, "thousand": 1000, "million": 1000000})


def allowed_numbers(*sources) -> set:
    """Every number that appears anywhere in the structured input (nested dicts/lists/strings)."""
    out: set = set()

    def walk(x):
        if isinstance(x, bool) or x is None:
            return
        if isinstance(x, (int, float)):
            out.add(round(float(x), 2))
            out.add(float(round(x)))
        elif isinstance(x, str):
            for n in re.findall(r"\d[\d,]*(?:\.\d+)?", x):
                out.add(round(float(n.replace(",", "")), 2))
        elif isinstance(x, dict):
            for v in x.values():
                walk(v)
        elif isinstance(x, (list, tuple, set)):
            for v in x:
                walk(v)

    for s in sources:
        walk(s)
    return out


def numbers_ok(sentence: str, allowed: set) -> bool:
    """False if the sentence has any number, in digits or spelled out, that is not in `allowed`."""
    for n in re.findall(r"\d[\d,]*(?:\.\d+)?", sentence):
        if round(float(n.replace(",", "").rstrip(".")), 2) not in allowed:
            return False
    for w in re.findall(r"[a-z]+", sentence.lower()):
        if w in _WORD_NUM and float(_WORD_NUM[w]) not in allowed:
            return False
    return True


def worst_red(red_alerts: list):
    """The most urgent red event: a tank that already tripped, else the soonest early-warning shutdown."""
    def urgency(a):
        h = (a.get("hours_to_limit") or {}).get(FORECAST_QUANTILE)
        return (0 if a.get("tripped") else 1, h if h is not None else 1e9, a["facility_id"])
    return min(red_alerts, key=urgency) if red_alerts else None


def alarm_id(dataset: str, red_alerts: list):
    """
    "<dataset>:<facility_id>:<event>" for the worst rules-red event. The event part is "pf-<onset unix>": detection
    numbers events in onset order, so an EV-#### id can shift when an earlier leak is found later; the onset cannot.
    Same situation -> same id on every poll, so the phone alarms once per situation.
    """
    a = worst_red(red_alerts)
    return f"{dataset}:{a['facility_id']}:pf-{int(a['onset_unix'])}" if a else None


def assess(ds, now=None, use_ai: bool = True, peek_ai: bool = False) -> dict:
    """
    The danger level is the rules' level, always. The AI never raises or lowers it and never touches alarm_id.
    use_ai=True: use the AI opinion if it is already known, otherwise start it in the background (never waits).
    peek_ai=True: only use an AI opinion that is already known (no network work started at all).
    """
    tri = run_triage(ds, now)
    rules = rules_risk(tri)
    active = [a for a in tri["alerts"] if _alert_level(a, tri["now"], ds)[0] != "green"]
    ai = None
    if active and (use_ai or peek_ai):  # nothing new or urgent: nothing for the AI to judge
        ai = cached_ai(tri, rules)
        if ai is None and use_ai:
            request_ai(tri, rules)
            ai = {"available": False, "pending": True}
    level = rules["level"]
    red = [r for r in rules["reasons"] if r["level"] == "red"]
    red_alerts = [a for a in tri["alerts"] if _alert_level(a, tri["now"], ds)[0] == "red"]
    note = ai["why"] if ai and ai.get("available") and ai.get("why") else None
    if red:
        headline = red[0]["text"]
    else:
        known = len(tri["alerts"]) - len(active)
        headline = (rules["reasons"][0]["text"] if active and rules["reasons"] else
                    (f"Nothing urgent. {known} minor issue{'s' if known != 1 else ''} to keep an eye on" if known else "All clear"))
    flaggable = []
    for a in tri["alerts"]:
        lv, text = _alert_level(a, tri["now"], ds)
        if lv in ("red", "amber"):
            flaggable.append({"facility_id": a["facility_id"], "category": a["category"], "level": lv,
                              "onset_unix": int(a["onset_unix"]), "text": text})
    money = _money(tri)
    if ai and ai.get("available") and ai.get("money") and money["rows"]:
        if numbers_ok(ai["money"], allowed_numbers(money)):  # else keep the deterministic sentence
            money["text"], money["from_ai"] = ai["money"], True
    speak = ""
    if level == "red":
        speak = "Alarm. " + " ".join(spoken(a) for a in tri["alerts"] if _alert_level(a, tri["now"], ds)[0] == "red")
    elif level == "amber":
        speak = "Check soon. " + " ".join(spoken(a) for a in active[:2])
    return {
        "dataset": ds.name, "as_of": tri["now_ts"], "now": tri["now"], "level": level, "rules_level": rules["level"],
        "severity": worst_severity(tri["alerts"]), "alarm": level == "red",
        "alarm_id": alarm_id(ds.name, red_alerts) if level == "red" else None,
        "headline": headline, "reasons": rules["reasons"], "facilities": rules["facilities"],
        "ai": ai, "note": note, "money": money, "flaggable": flaggable, "spoken_text": speak,
    }


_timeline_cache = LRU(32)


def timeline(ds, step_min: int = 30) -> dict:
    """
    Risk across the whole dataset, for the slider. Cached until the files change.
    The main bar follows pump failures only (amber = the tank can wait out the repair, red = danger), so it has real
    quiet stretches. Leaks and worn pumps last for days, so they get their own thin strip instead of painting
    the whole bar.
    """
    key = (ds.name, ds.token, step_min)
    hit = _timeline_cache.get(key)
    if hit is not None:
        return hit
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
