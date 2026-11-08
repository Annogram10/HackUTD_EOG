"""
"What dropped": for each problem in progress, the sensors that moved away from normal, ready to chart.
The numbers come from the telemetry. Nemotron picks which charts are worth showing and writes a one-line caption.
It only describes what the readings did. It never diagnoses or tells anyone to operate equipment.
"""

import json
import os
import re
import urllib.request

import numpy as np

from .lru import LRU
from .risk import _alert_level
from .triage import fac_name, run_triage

URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1") + "/chat/completions"
MODEL = os.environ.get("NEMOTRON_MODEL", "nvidia/nemotron-3.5-super-vl-120b-a12b")
POINTS = 160
_cache = LRU(256)


def _candidates(ds, a: dict, now: int) -> list:
    f = ds.facilities[a["facility_id"]]
    pump, pipe, tank = f.pump["id"], f.pipeline["id"], f.tank["id"]
    onset = int(a["onset_unix"])
    run = ds.wide[(pump, "status")].loc[: onset - 1800] == 1
    metrics = [
        (pump, "flow_bpd", "Pump flow", "bpd"),
        (pump, "discharge_psi", "Pump discharge pressure", "psi"),
        (pipe, "pressure_psi", "Pipeline pressure", "psi"),
        (pipe, "receive_flow_bpd", "Flow arriving at disposal", "bpd"),
        (tank, "level_pct", "Tank level", "%"),
    ]
    out = []
    for asset, metric, label, unit in metrics:
        if not ds.has(asset, metric):
            continue
        s = ds.wide[(asset, metric)]
        before = s.loc[onset - 72 * 3600: onset - 1800]
        if metric != "level_pct":  # normal = typical value while the pump was running
            before = before[run.reindex(before.index, fill_value=False)]
        if len(before) < 6:
            continue
        base = float(np.nanmedian(before.values))
        cur = float(np.nanmedian(s.loc[:now].tail(3).values))
        change = cur - base if unit == "%" else (cur - base) / base * 100 if base else 0.0
        lo = min(onset - 6 * 3600, now - 12 * 3600)
        win = s.loc[max(int(s.index[0]), lo): now]
        step = max(1, int(np.ceil(len(win) / POINTS)))
        pts = [[int(t), round(float(v), 2)] for t, v in list(zip(win.index, win.values))[::step]]
        if pts and pts[-1][0] != int(win.index[-1]):
            pts.append([int(win.index[-1]), round(float(win.values[-1]), 2)])
        out.append({"asset": asset, "metric": metric, "label": label, "unit": unit, "base": round(base, 1),
                    "current": round(cur, 1), "change": round(change, 1), "points": pts})
    return out


def _ask_ai(sections: list, now: int) -> dict:
    k = os.environ.get("NVIDIA_API_KEY")
    if not k:
        return {"available": False, "error": "NVIDIA_API_KEY is not set"}
    facts = [{"facility_id": s["facility_id"], "problem": s["category"],
              "sensors": [{"metric": c["metric"], "label": c["label"], "normal": c["base"], "now": c["current"],
                           "change": f"{c['change']:+.0f}{' points' if c['unit'] == '%' else '%'}"} for c in s["candidates"]]}
             for s in sections]
    prompt = (
        "A night-shift screen shows charts for problems in an oil-field water system. For each facility pick the 2 sensors "
        "whose chart best shows what changed (usually the biggest drops from normal; a tank level rise counts when a pump failed). "
        "Write one short plain caption per chart saying what the line did, using the numbers given. "
        "Do not diagnose a cause and never tell anyone to operate or shut down equipment. "
        'Answer with JSON only: {"charts": [{"facility_id": "...", "metric": "...", "caption": "max 18 words"}]}\n\n'
        + json.dumps(facts))
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}], "max_tokens": 600,
                       "temperature": 0.2, "chat_template_kwargs": {"enable_thinking": False}}).encode()
    req = urllib.request.Request(URL, body, {"Authorization": f"Bearer {k}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            text = json.loads(r.read())["choices"][0]["message"].get("content") or ""
        picked = json.loads(re.search(r"\{.*\}", text, re.S).group(0))["charts"]
        return {"available": True, "model": MODEL, "charts": picked}
    except Exception as e:
        return {"available": False, "error": str(e)[:120]}


def _fallback_caption(c: dict) -> str:
    if c["unit"] == "%":
        if abs(c["change"]) < 1:
            return f"{c['label']} is at {c['current']:.0f}% (usually around {c['base']:.0f}%)."
        return f"{c['label']} went from about {c['base']:.0f}% to {c['current']:.0f}%."
    word = "fell" if c["change"] < 0 else "rose"
    return f"{c['label']} {word} from about {c['base']:.0f} to {c['current']:.0f} {c['unit']} ({c['change']:+.0f}%)."


def build(ds, now=None, use_ai: bool = True) -> dict:
    tri = run_triage(ds, now)
    alerts = tri["alerts"][:4]
    key = (ds.name, ds.token, tri["now"], tuple(a["event_id"] for a in alerts), use_ai)
    hit = _cache.get(key)
    if hit is not None:
        return hit
    sections = []
    for a in alerts:
        sections.append({"facility_id": a["facility_id"], "name": fac_name(a["facility_id"]), "system": a["system_id"],
                         "category": a["category"], "level": _alert_level(a, tri["now"], ds)[0], "onset_unix": int(a["onset_unix"]), "onset_ts": a["onset_ts"],
                         "candidates": _candidates(ds, a, tri["now"])})
    ai = _ask_ai(sections, tri["now"]) if (use_ai and sections) else None
    chosen = {}
    if ai and ai.get("available"):
        for c in ai["charts"]:
            chosen.setdefault(c.get("facility_id"), []).append((c.get("metric"), str(c.get("caption", ""))[:200]))
    for s in sections:
        cands = {c["metric"]: c for c in s.pop("candidates")}
        picks = []
        for metric, cap in chosen.get(s["facility_id"], []):
            if metric in cands and all(metric != m for m, _ in picks):
                picks.append((metric, cap or _fallback_caption(cands[metric])))
        if len(picks) < 2:  # fill with the biggest moves (drops first) when the AI is off or picked fewer
            rest = sorted((c for m, c in cands.items() if all(m != p for p, _ in picks)),
                          key=lambda c: (c["change"] > 0 and c["unit"] != "%", -abs(c["change"])))
            picks += [(c["metric"], _fallback_caption(c)) for c in rest[: 2 - len(picks)]]
        if s["category"] == "pump_failure" and "level_pct" in cands and all(m != "level_pct" for m, _ in picks[:2]):
            picks = picks[:1] + [("level_pct", _fallback_caption(cands["level_pct"]))]  # a failed pump: show the tank filling
        s["charts"] = [{**cands[m], "caption": cap} for m, cap in picks[:2]]
    res = {"dataset": ds.name, "as_of": tri["now_ts"], "now": tri["now"], "ai": ai, "sections": sections}
    _cache[key] = res
    return res
