"""
The triage agent. It plans and runs the steps on its own when a dataset loads (nobody types a prompt):

  load_dataset -> detect_events -> forecast_shutdown (each failure) -> optimize_plan (each system, shared trucks)
  -> get_fleet_status -> get_weather -> save_alerts (order + handoff) -> export_events

Every number comes from a tool (code). The model only decides what to call next and writes the handoff.

With NVIDIA_API_KEY set, a Nemotron model (build.nvidia.com, OpenAI-compatible API) drives the loop with tool calling.
Without a key, the same tools run in a fixed script and the trace says so. It never pretends to be Nemotron.
"""

import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

from . import dataset as D
from .detect import detect_events
from .forecast import forecast_shutdown
from .handoff import build_handoff
from .lru import LRU
from .triage import events_json, fac_name, run_triage

NVIDIA_URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1") + "/chat/completions"
MODEL = os.environ.get("NEMOTRON_MODEL", "nvidia/nemotron-3.5-super-vl-120b-a12b")

_runs = LRU(32)  # one agent run per (dataset, files, moment)
_lock = threading.Lock()


# ---------- tools (all numbers come from here) ----------

class Tools:
    def __init__(self, dataset_name: str, now: Optional[int]):
        self.name, self.now = dataset_name, now
        self.ds = None
        self.saved: Optional[dict] = None

    def _tri(self):
        return run_triage(self.ds, self.now)

    def load_dataset(self, dataset: Optional[str] = None) -> dict:
        self.ds = D.load(dataset or self.name)
        ds = self.ds
        return {"dataset": ds.name, "now": D.iso(self.now or ds.t_last), "first": D.iso(ds.t_first),
                "systems": {s: {"facilities": len(v["facility_ids"]), "trucks": v["fleet_size"]} for s, v in ds.systems.items()},
                "repair_hours": ds.repair_hours, "tank_limits_pct": ds.limits}

    def detect_events(self) -> dict:
        tri = self._tri()
        ev = tri["events"]
        ong = [e for e in ev if e["status"] == "ongoing"]
        return {"total_events_in_data": len(ev), "ongoing": [
            {k: e[k] for k in ("event_id", "category", "facility_id", "asset_id", "onset_ts", "confidence")}
            | {"evidence": e["evidence"], "lat": self.ds.facilities[e["facility_id"]].lat, "lon": self.ds.facilities[e["facility_id"]].lon}
            for e in ong]}

    def forecast_shutdown(self, facility_id: str) -> dict:
        fc = forecast_shutdown(self.ds, facility_id, self.now)
        return {k: fc[k] for k in ("facility_id", "level_pct", "shutdown_pct", "hours_to_limit", "tripped", "lost_revenue_per_hour")}

    def optimize_plan(self, system_id: str) -> dict:
        tri = self._tri()
        plans = [{"event_id": a["event_id"], "facility_id": a["facility_id"], "plan": a["plan"]["label"],
                  "cost": a["plan"]["cost"], "do_nothing_cost": next((o["cost"] for o in a["options"] if o["label"] == "Do nothing"), None),
                  "action": a["action_text"]}
                 for a in tri["alerts"] if a["category"] == "pump_failure" and a["system_id"] == system_id and a.get("plan")]
        return {"system_id": system_id, "plans": plans, "shared": tri["shared_trucks"].get(system_id)}

    def get_fleet_status(self, system_id: str) -> dict:
        s = self.ds.systems[system_id]
        sh = self._tri()["shared_trucks"].get(system_id)
        return {"system_id": system_id, "fleet_size": s["fleet_size"], "trucks_planned": sh["trucks_used"] if sh else 0,
                "free_after_plan": s["fleet_size"] - (sh["trucks_used"] if sh else 0),
                "note": "Nothing is dispatched yet at 'now'; all trucks are free until the plan is approved."}

    def get_weather(self, lat: float, lon: float) -> dict:
        q = urllib.parse.urlencode({"latitude": lat, "longitude": lon, "current": "temperature_2m,precipitation,wind_speed_10m"})
        try:
            with urllib.request.urlopen(f"https://api.open-meteo.com/v1/forecast?{q}", timeout=5) as r:
                cur = json.loads(r.read())["current"]
            slow = cur.get("precipitation", 0) > 0.5 or cur.get("wind_speed_10m", 0) > 40
            return {"available": True, "temperature_c": cur["temperature_2m"], "precipitation_mm": cur["precipitation"],
                    "wind_kmh": cur["wind_speed_10m"],
                    "note": "Wet or windy: truck travel may be slower than the planned response time." if slow
                    else "Weather looks fine for truck travel."}
        except Exception as e:  # network off, API down: say so, don't guess
            return {"available": False, "error": str(e)[:80], "note": "Weather unavailable; no change to the plan."}

    def save_alerts(self, handoff: str = "", order: Optional[list] = None) -> dict:
        tri = self._tri()
        self.saved = {"handoff": handoff, "agent_order": order or [a["event_id"] for a in tri["alerts"]],
                      "canonical_order": [a["event_id"] for a in tri["alerts"]]}
        return {"saved": True, "alerts": len(tri["alerts"]), "order_matches_rule": self.saved["agent_order"] == self.saved["canonical_order"]}

    def export_events(self) -> dict:
        ev = events_json(self._tri())
        return {"events_exported": len(ev), "download": f"/events.json?dataset={self.ds.name}"}


TOOL_SPECS = [
    ("load_dataset", "Load the dataset folder (network, ops, telemetry). Call first.", {"dataset": ("string", False)}),
    ("detect_events", "Run the detection rules. Returns problems still in progress with evidence.", {}),
    ("forecast_shutdown", "Countdown to tank shutdown for one facility.", {"facility_id": ("string", True)}),
    ("optimize_plan", "Cheapest plan for all pump failures in one system (trucks shared). Returns costs.", {"system_id": ("string", True)}),
    ("get_fleet_status", "Truck fleet size and how many the plan uses for one system.", {"system_id": ("string", True)}),
    ("get_weather", "Real weather at a location (Open-Meteo), as a note on truck travel.", {"lat": ("number", True), "lon": ("number", True)}),
    ("save_alerts", "Save the final ordered alerts and the shift handoff text (plain English, quote tool numbers only).",
     {"handoff": ("string", True), "order": ("array", False)}),
    ("export_events", "Export detected events to events.json in EOG's format.", {}),
]


def _schema():
    out = []
    for name, desc, params in TOOL_SPECS:
        props = {k: ({"type": "array", "items": {"type": "string"}} if t == "array" else {"type": t}) for k, (t, _) in params.items()}
        out.append({"type": "function", "function": {"name": name, "description": desc, "parameters": {
            "type": "object", "properties": props, "required": [k for k, (_, req) in params.items() if req]}}})
    return out


SYSTEM_PROMPT = (
    "You are the NightShift triage agent for oil and gas night operations. A dataset has just loaded. "
    "Without asking anyone, run this workflow with the tools: load_dataset, detect_events, then for every ongoing "
    "pump_failure call forecast_shutdown, then optimize_plan once per affected system, get_fleet_status for those systems, "
    "get_weather once for a failing facility, then save_alerts with a short handoff (readable in 30 seconds), then export_events. "
    "Rules: never invent or compute a number yourself, only quote numbers returned by tools. You flag things for a human to check; "
    "never tell anyone to operate or shut down equipment, a human approves every plan. Word every plan as a proposal, "
    "starting with 'Proposed plan for supervisor approval:', never as an instruction. Stop after export_events."
)


# ---------- trace ----------

def _short(obj, n=1800) -> str:
    s = json.dumps(obj, default=str)
    return s if len(s) <= n else s[:n] + "…"


class Run:
    def __init__(self, dataset_name, now):
        self.dataset, self.now = dataset_name, now
        self.status = "running"
        self.mode = "nemotron" if os.environ.get("NVIDIA_API_KEY") else "offline-script"
        self.model = MODEL if self.mode == "nemotron" else None
        self.steps: list = []
        self.handoff_text: Optional[str] = None
        self.error: Optional[str] = None
        self.started = time.time()

    def add(self, kind, **kw):
        self.steps.append({"step": len(self.steps) + 1, "kind": kind, "t": round(time.time() - self.started, 2), **kw})

    def call(self, tools: Tools, name: str, args: dict, why: str = ""):
        t = time.time()
        try:
            res = getattr(tools, name)(**args)
            err = None
        except Exception as e:  # tool errors go back to the agent as data
            res, err = {"error": str(e)[:200]}, str(e)[:200]
        self.add("tool", tool=name, args=args, why=why, result=_short(res, 8000), ms=round((time.time() - t) * 1000), error=err)
        return res

    def public(self):
        return {"dataset": self.dataset, "status": self.status, "mode": self.mode, "model": self.model,
                "steps": self.steps, "handoff": self.handoff_text, "error": self.error}


def _script(run: Run, tools: Tools):
    """Same workflow, fixed order. Used when there is no NVIDIA key."""
    run.add("plan", text="Plan: load data, detect problems, countdown for each pump failure, plan per system (shared trucks), "
                         "check fleet and weather, order alerts, write handoff, export events.")
    info = run.call(tools, "load_dataset", {}, "Every run starts by loading the dataset files.")
    det = run.call(tools, "detect_events", {}, "Find problems still in progress from the sensor readings.")
    fails = [e for e in det["ongoing"] if e["category"] == "pump_failure"]
    for e in fails:
        run.call(tools, "forecast_shutdown", {"facility_id": e["facility_id"]}, f"Countdown for {fac_name(e['facility_id'])}.")
    systems = sorted({tools.ds.facilities[e["facility_id"]].system_id for e in fails})
    for s in systems:
        run.call(tools, "optimize_plan", {"system_id": s}, f"Failures in {s} share its trucks, so plan them together.")
        run.call(tools, "get_fleet_status", {"system_id": s}, f"Check how many {s} trucks the plan uses.")
    if fails:
        f = tools.ds.facilities[fails[0]["facility_id"]]
        run.call(tools, "get_weather", {"lat": f.lat, "lon": f.lon}, "Weather note on truck travel to the most urgent site.")
    tri = tools._tri()
    hand = build_handoff(tri)
    text = f"{hand['headline']}\n" + "\n".join(hand["lines"])
    run.call(tools, "save_alerts", {"handoff": text, "order": [a["event_id"] for a in tri["alerts"]]}, "Order alerts and save the handoff.")
    run.call(tools, "export_events", {}, "Export events.json for EOG.")
    run.handoff_text = text


def _nemotron(run: Run, tools: Tools):
    key = os.environ["NVIDIA_API_KEY"]
    msgs = [{"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"New data loaded: dataset '{tools.name}'. Begin triage."}]
    for _ in range(24):
        body = json.dumps({
            "model": MODEL, "messages": msgs, "tools": _schema(), "parallel_tool_calls": True,
            "temperature": 0.6, "top_p": 0.95, "max_tokens": 4096, "seed": 42,
            "chat_template_kwargs": {"enable_thinking": True},
        }).encode()
        req = urllib.request.Request(NVIDIA_URL, body, {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=180) as r:
            msg = json.loads(r.read())["choices"][0]["message"]
        msgs.append({k: v for k, v in msg.items() if k in ("role", "content", "tool_calls")} | {"role": "assistant"})
        if msg.get("reasoning_content"):
            run.add("thought", text="(reasoning) " + str(msg["reasoning_content"])[:1200])
        if msg.get("content"):
            run.add("thought", text=msg["content"])
        calls = msg.get("tool_calls") or []
        if not calls:
            run.handoff_text = (tools.saved or {}).get("handoff") or msg.get("content")
            return
        for c in calls:
            fn = c["function"]
            args = json.loads(fn.get("arguments") or "{}")
            res = run.call(tools, fn["name"], args)
            msgs.append({"role": "tool", "tool_call_id": c["id"], "content": _short(res, 6000)})
            if fn["name"] == "save_alerts":
                run.handoff_text = args.get("handoff")
    raise RuntimeError("agent hit the step limit")


def _execute(run: Run):
    tools = Tools(run.dataset, run.now)
    try:
        tools.ds = D.load(run.dataset)
        if run.mode == "nemotron":
            try:
                _nemotron(run, tools)
            except Exception as e:  # key rejected, model name wrong, offline...: say so and fall back
                run.error = f"Nemotron call failed ({str(e)[:120]}); ran the offline script instead."
                run.mode, run.model = "offline-script", None
                run.steps = []
                tools = Tools(run.dataset, run.now)
                tools.ds = D.load(run.dataset)
                _script(run, tools)
        else:
            _script(run, tools)
        if not run.handoff_text:
            h = build_handoff(run_triage(tools.ds, run.now))
            run.handoff_text = h["headline"] + "\n" + "\n".join(h["lines"])
        run.status = "done"
    except Exception as e:
        run.status, run.error = "error", str(e)[:200]


def find_run(dataset_name: str, now: Optional[int] = None) -> Optional[Run]:
    """An agent run that already exists for this moment, without starting one."""
    return _runs.get((dataset_name, D.load(dataset_name).token, now))


def get_run(dataset_name: str, now: Optional[int] = None, force: bool = False) -> Run:
    """Starts the agent the first time a dataset is asked for. Nobody has to type a prompt."""
    key = (dataset_name, D.load(dataset_name).token, now)
    with _lock:
        if force or key not in _runs:
            run = Run(dataset_name, now)
            _runs[key] = run
            threading.Thread(target=_execute, args=(run,), daemon=True).start()
        return _runs.get(key)
