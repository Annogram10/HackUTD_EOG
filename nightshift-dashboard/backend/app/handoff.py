"""Plain-English shift handoff, written from the triage numbers (no AI needed, no numbers invented)."""

from .triage import fac_name, money


def spoken(a: dict) -> str:
    """One alert as the glasses would say it."""
    who = fac_name(a["facility_id"])
    if a["category"] == "pump_failure":
        h = a.get("hours_to_limit")
        if a.get("tripped"):
            return f"{who} pump has failed and the tank has already reached shutdown. Wells stay shut in until the repair ends."
        t = f"Shutdown in {h['p50']:.1f} hours." if h else ""
        plan = a.get("plan")
        fix = f" Cheapest fix: {_plan_words(plan)}, {money(plan['cost'])}." if plan else ""
        return f"{who} pump has failed. {t}{fix}"
    if a["category"] == "pipeline_leak":
        return f"{who} pipeline looks like it is leaking. Send an inspector."
    return f"{who} pump is wearing out. Send an inspector."


def _plan_words(plan: dict) -> str:
    bits = []
    if plan["trucks"]:
        n, k = plan["trucks"], plan["trips_per_truck"]
        bits.append(f"send {'one' if n == 1 else n} truck{'s' if n > 1 else ''}" + (f", {k} trips each" if k > 1 else ""))
    for s in plan["shut_ins"]:
        bits.append(f"shut in {s['well']}" + ("" if s["start_after_min"] <= 0 else f" in {s['start_after_min']} minutes"))
    return " and ".join(bits) or ("let the tank trip" if plan["tank_trips"] else "no action needed")


def build_handoff(triage: dict) -> dict:
    alerts = triage["alerts"]
    fails = [a for a in alerts if a["category"] == "pump_failure"]
    leaks = [a for a in alerts if a["category"] == "pipeline_leak"]
    worn = [a for a in alerts if a["category"] == "pump_degradation"]
    lines = []
    if not alerts:
        lines.append("No problems in progress. Normal round.")
    if fails:
        lines.append(f"{len(fails)} pump failure{'s' if len(fails) > 1 else ''} in progress, soonest shutdown first:")
        for a in fails:
            lines.append("• " + spoken(a))
    for sid, s in triage["shared_trucks"].items():
        if len(s["events"]) > 1:
            lines.append(f"{sid}: {len(s['events'])} failures share {s['fleet']} trucks. Planned together, {s['trucks_used']} used, total {money(s['total_cost'])}.")
    if leaks:
        lines.append("Possible leaks (send an inspector): " + ", ".join(fac_name(a["facility_id"]) for a in leaks) + ".")
    if worn:
        lines.append("Pumps wearing out (send an inspector): " + ", ".join(fac_name(a["facility_id"]) for a in worn) + ".")
    lines.append("These are flags for a person to check. Nothing here operates equipment.")
    return {
        "dataset": triage["dataset"], "as_of": triage["now_ts"],
        "headline": (f"{len(alerts)} problem{'s' if len(alerts) != 1 else ''} in progress" if alerts else "All clear"),
        "lines": lines, "spoken": [spoken(a) for a in alerts],
    }
