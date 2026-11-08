"""
Plain-English shift handoff, written from the triage numbers (no AI needed, no numbers invented).
Every plan is worded as a proposal a supervisor approves, never as an instruction: nothing here operates equipment.
"""
from . import speech as sp
from .triage import fac_name, money

PROPOSAL = "Proposed plan for supervisor approval"


def spoken(a: dict, words: bool = True) -> str:
    """One alert. words=True: numbers spelled out, for the glasses. words=False: digits, for the screen."""
    who = sp.facility(fac_name(a["facility_id"])) if words else fac_name(a["facility_id"])
    if a["category"] == "pump_failure":
        h = a.get("hours_to_limit")
        if a.get("tripped"):
            return f"{who} pump has failed and the tank has already reached shutdown. The wells stay shut in until the repair ends."
        hours_txt = (sp.hours(h["p50"]) if words else "%.1f hours" % h["p50"]) if h else ""
        t = f"Shutdown in about {hours_txt}." if h else ""
        plan = a.get("plan")
        fix = f" {PROPOSAL}: {_plan_words(plan, words)}, {sp.dollars(plan['cost']) if words else money(plan['cost'])}." if plan else ""
        return f"{who} pump has failed. {t}{fix}"
    if a["category"] == "pipeline_leak":
        return f"{who} pipeline may be leaking. Proposed for supervisor approval: an inspector checks it."
    return f"{who} pump may be wearing out. Proposed for supervisor approval: an inspector checks it."


def _plan_words(plan: dict, words: bool = True) -> str:
    num = sp.int_words if words else str
    bits = []
    if plan["trucks"]:
        n, k = plan["trucks"], plan["trips_per_truck"]
        bits.append(f"send {num(n)} truck{'s' if n > 1 else ''}" + (f", {num(k)} trips each" if k > 1 else ""))
    for s in plan["shut_ins"]:
        bits.append(f"shut in well {s['well'].split('_')[-1]}" + ("" if s["start_after_min"] <= 0 else f" in {num(int(s['start_after_min']))} minutes"))
    return ", ".join(bits) or ("no action, the tank reaches shutdown" if plan["tank_trips"] else "no action needed")


def build_handoff(triage: dict) -> dict:
    alerts = triage["alerts"]
    by_sev = {s: [a for a in alerts if a.get("severity") == s] for s in ("high", "medium", "low")}
    lines = []
    if not alerts:
        lines.append("No problems in progress. Normal round.")
    heads = {"high": "Danger (high)", "medium": "Check soon (medium)", "low": "Keep an eye on (low)"}
    for sev in ("high", "medium", "low"):
        group = by_sev[sev]
        if not group:
            continue
        lines.append(f"{heads[sev]}: {len(group)} problem{'s' if len(group) > 1 else ''}")
        for a in group:
            lines.append("• " + spoken(a, words=False))
    for sid, s in triage["shared_trucks"].items():
        if len(s["events"]) > 1:
            lines.append(f"{sid}: {len(s['events'])} failures share {s['fleet']} trucks. Planned together, {s['trucks_used']} used, total {money(s['total_cost'])}.")
    lines.append("These are flags for a person to check. Nothing here operates equipment.")
    spoken_text = " ".join(spoken(a) for a in alerts) if alerts else "No problems in progress. Normal round."
    return {
        "text": "\n".join(lines), "spoken_text": spoken_text,
        "dataset": triage["dataset"], "as_of": triage["now_ts"],
        "headline": (f"{len(alerts)} problem{'s' if len(alerts) != 1 else ''} in progress" if alerts else "All clear"),
        "lines": lines, "spoken": [spoken(a) for a in alerts],
    }


BRIEF_MAX_WORDS = 150  # about 30 seconds of reading


def _brief_item(a: dict) -> str:
    """One short line per problem, digits not words."""
    who = fac_name(a["facility_id"])
    if a["category"] == "pump_failure":
        if a.get("tripped"):
            return f"{who}: pump failed, tank already at shutdown. Wells stay shut in until the repair ends."
        h = a.get("hours_to_limit")
        left = f"shutdown in {h['p50']:.1f} h" if h else "pump failed"
        plan = a.get("plan")
        fix = f" Proposed (needs approval): {_plan_words(plan, False)}, {money(plan['cost'])}." if plan else ""
        return f"{who}: pump failed, {left}.{fix}"
    what = "possible pipeline leak" if a["category"] == "pipeline_leak" else "pump wearing out"
    return f"{who}: {what}, an inspector should check it."


def build_brief(triage: dict, as_of_text: str, check_first: list, events_count: int, mode: str) -> str:
    """
    The plain-English handoff the next operator can read in about 30 seconds (EOG README, 'Go further').
    Plain text, most urgent first, numbers from the triage only. Long lists are cut with 'and N more'.
    """
    alerts = triage["alerts"]
    groups = {s: [a for a in alerts if a.get("severity") == s] for s in ("high", "medium", "low")}
    n = len(alerts)
    if not n:
        headline = "All clear. No problems in progress. Normal round."
    else:
        bits = [f"{len(groups['high'])} need{'s' if len(groups['high']) == 1 else ''} action now" if groups["high"] else None,
                f"{len(groups['medium'])} to check soon" if groups["medium"] else None,
                f"{len(groups['low'])} minor" if groups["low"] else None]
        headline = f"{n} problem{'s' if n != 1 else ''} in progress: " + ", ".join(b for b in bits if b) + "."

    out = ["NIGHTSHIFT HANDOFF", f"{triage['dataset']} · {as_of_text}{' (replay)' if mode == 'replay' else ''} · about 30 seconds to read", "", headline]

    def section(title, items, limit):
        if not items:
            return
        out.append("")
        out.append(title)
        for a in items[:limit]:
            out.append("- " + _brief_item(a))
        if len(items) > limit:
            out.append(f"- and {len(items) - limit} more on the dashboard.")

    section("ACT NOW", groups["high"], 3)
    section("CHECK SOON", groups["medium"], 3)
    if groups["low"]:
        out += ["", "KEEP AN EYE ON", "- " + ", ".join(fac_name(a["facility_id"]) for a in groups["low"][:6])
                + (f" and {len(groups['low']) - 6} more" if len(groups["low"]) > 6 else "") + " (minor, no action yet)."]
    shared = [f"{sid}: {len(s['events'])} failures share {s['fleet']} trucks, {s['trucks_used']} used, {money(s['total_cost'])} total."
              for sid, s in triage["shared_trucks"].items() if len(s["events"]) > 1]
    if shared:
        out += ["", "TRUCKS"] + ["- " + x for x in shared]
    if check_first:
        out += ["", "CHECK FIRST NEXT SHIFT", "- " + ", ".join(check_first[:3]) + "."]
    out += ["", "Flags for a person to check. Nothing here operates equipment.",
            f"Full event list: events.json ({events_count} events)."]

    # keep it a 30-second read: drop the least urgent lines first if it runs long
    def words(lines):
        return sum(len(x.split()) for x in lines)
    while words(out) > BRIEF_MAX_WORDS and "KEEP AN EYE ON" in out:
        i = out.index("KEEP AN EYE ON")
        del out[i - 1:i + 2]
    return "\n".join(out) + "\n"
