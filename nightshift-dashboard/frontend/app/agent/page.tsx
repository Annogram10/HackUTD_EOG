"use client";

// AGENT TRACE: what the triage agent concluded, then every tool call it made to get there.

import { useEffect, useState } from "react";
import { useApp } from "@/components/AppProvider";
import { facName, getAgentTrace, money, rerunAgent } from "@/lib/api";
import type { AgentRun, TraceStep } from "@/lib/types";

// One plain-English line per tool result, so you don't have to read JSON.
function summarize(tool: string, raw: string): string | null {
  let r: any; // eslint-disable-line @typescript-eslint/no-explicit-any
  try {
    r = JSON.parse(raw);
  } catch {
    return null;
  }
  if (r.error) return `Error: ${r.error}`;
  switch (tool) {
    case "load_dataset":
      return `Loaded ${r.dataset}: ${Object.keys(r.systems).length} systems, data up to ${r.now}`;
    case "detect_events": {
      const o = r.ongoing as { category: string; facility_id: string }[];
      if (!o.length) return `Scanned ${r.total_events_in_data} events in the data. Nothing in progress.`;
      const by: Record<string, number> = {};
      o.forEach((e) => (by[e.category.replace("_", " ")] = (by[e.category.replace("_", " ")] ?? 0) + 1));
      return `${o.length} problem${o.length > 1 ? "s" : ""} in progress: ${Object.entries(by).map(([k, n]) => `${n} ${k}${n > 1 ? "s" : ""}`).join(", ")}`;
    }
    case "forecast_shutdown":
      return r.tripped ? `${facName(r.facility_id)}: tank already at shutdown`
        : `${facName(r.facility_id)}: tank ${r.level_pct}% full, reaches shutdown in ${r.hours_to_limit?.p50} h (range ${r.hours_to_limit?.p10} to ${r.hours_to_limit?.p90} h)`;
    case "optimize_plan":
      return (r.plans as { facility_id: string; action: string }[]).map((p) => `${facName(p.facility_id)}: ${p.action}`).join(" · ")
        + (r.shared ? ` · total ${money(r.shared.total_cost)} with ${r.shared.trucks_used} of ${r.shared.fleet} trucks` : "");
    case "get_fleet_status":
      return `${r.system_id}: ${r.fleet_size} trucks, plan uses ${r.trucks_planned}, ${r.free_after_plan} left`;
    case "get_weather":
      return r.available ? `${r.temperature_c}°C, ${r.precipitation_mm} mm rain, wind ${r.wind_kmh} km/h. ${r.note}` : r.note;
    case "save_alerts":
      return `Saved ${r.alerts} alerts and the handoff. Order ${r.order_matches_rule ? "matches" : "differs from"} the soonest-shutdown-first rule`;
    case "export_events":
      return `Exported ${r.events_exported} events to events.json`;
  }
  return null;
}

const pretty = (raw: string) => {
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw;
  }
};

const argsLine = (args: Record<string, unknown> = {}) =>
  Object.entries(args).filter(([k]) => k !== "handoff" && k !== "order").map(([k, v]) => `${k}: ${String(v)}`).join(" · ");

interface Row {
  step: TraceStep;
  reasoning: string[];
}

function toRows(steps: TraceStep[]): { rows: Row[]; notes: TraceStep[]; final: TraceStep | null } {
  const rows: Row[] = [];
  const notes: TraceStep[] = [];
  let pending: string[] = [];
  steps.forEach((s) => {
    if (s.kind === "thought" && s.text?.startsWith("(reasoning)")) pending.push(s.text.replace("(reasoning) ", ""));
    else if (s.kind === "tool" || s.kind === "plan") {
      rows.push({ step: s, reasoning: pending });
      pending = [];
    } else notes.push(s);
  });
  // the agent's last message restates the whole run; keep it apart from the short notes between calls
  const last = steps[steps.length - 1];
  const final = last && last.kind === "thought" && !last.text?.startsWith("(reasoning)") && (last.text?.length ?? 0) > 300 ? last : null;
  return { rows, notes: notes.filter((n) => n !== final), final };
}

export default function AgentTrace() {
  const { dataset } = useApp();
  const [loaded, setLoaded] = useState<AgentRun | null>(null);
  const run = loaded && loaded.dataset === dataset ? loaded : null; // ignore a trace from another dataset

  useEffect(() => {
    if (!dataset) return;
    let alive = true;
    getAgentTrace(dataset).then((r) => alive && setLoaded(r)).catch(() => {});
    return () => {
      alive = false;
    };
  }, [dataset]);

  // while a run is in progress (including after "Run again"), refresh until it finishes
  const running = run?.status === "running";
  useEffect(() => {
    if (!running || !dataset) return;
    let alive = true;
    const t = setInterval(() => {
      getAgentTrace(dataset).then((r) => alive && setLoaded(r)).catch(() => {});
    }, 1500);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [running, dataset]);

  if (!run) return <div className="h-96 animate-pulse rounded-2xl bg-zinc-900" />;
  const live = run.mode === "nemotron";
  const { rows, final } = toRows(run.steps);
  const toolCalls = run.steps.filter((s) => s.kind === "tool");
  const seconds = run.steps.length ? run.steps[run.steps.length - 1].t : 0;
  const toolNumber = new Map(rows.filter((r) => r.step.kind === "tool").map((r, i) => [r.step.step, i + 1]));

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-4xl font-bold">Agent trace</h1>
          <p className="mt-1 text-lg text-zinc-400">
            The triage agent started on its own when <span className="font-semibold text-zinc-200">{run.dataset}</span> loaded. Every number came from a tool, not from the model.
          </p>
        </div>
        <button onClick={() => dataset && rerunAgent(dataset).then(setLoaded)} className="no-print rounded-lg border border-zinc-700 px-5 py-2.5 text-base font-semibold text-zinc-200 hover:bg-zinc-800">
          Run again
        </button>
      </div>

      <div className={`flex flex-wrap items-center gap-x-8 gap-y-2 rounded-xl px-5 py-4 text-lg ${live ? "bg-emerald-500/10 text-emerald-100" : "bg-amber-500/10 text-amber-100"}`}>
        <span>
          {live ? <>Driven by <span className="font-semibold">{run.model}</span></> : <>Fixed script, <span className="font-semibold">not Nemotron</span> (no <code>NVIDIA_API_KEY</code> set)</>}
        </span>
        <span className="text-zinc-300">{toolCalls.length} tool calls</span>
        <span className="text-zinc-300">{seconds.toFixed(0)} s</span>
        <span className="text-zinc-300">{running ? "Working…" : run.status === "done" ? "Finished" : "Error"}</span>
        {run.error && <span className="w-full text-base text-amber-300">{run.error}</span>}
      </div>

      {run.handoff && (
        <section className="rounded-xl border border-emerald-500/30 bg-zinc-900 p-6">
          <h2 className="text-2xl font-semibold">What the agent concluded</h2>
          <p className="mb-3 text-sm text-zinc-500">The handoff it saved. A person reviews and approves every plan.</p>
          <div className="space-y-3 text-lg leading-relaxed text-zinc-200">
            {run.handoff.split(/\n\s*\n/).map((p, i) => <p key={i} className="whitespace-pre-line">{p}</p>)}
          </div>
        </section>
      )}

      <section>
        <h2 className="mb-4 text-2xl font-semibold">How it got there</h2>
        <ol className="relative space-y-4 border-l-2 border-zinc-800 pl-6">
          {rows.map(({ step: s, reasoning }) => {
            const isTool = s.kind === "tool";
            const n = toolNumber.get(s.step);
            const line = isTool && s.result ? summarize(s.tool ?? "", s.result) : null;
            return (
              <li key={s.step} className="relative">
                <span className={`absolute -left-[35px] top-1 flex h-7 w-7 items-center justify-center rounded-full text-sm font-bold ring-4 ring-zinc-950 ${isTool ? "bg-violet-400 text-violet-950" : "bg-sky-400 text-sky-950"}`}>
                  {isTool ? n : "✓"}
                </span>
                {isTool ? (
                  <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4">
                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                      <span className="font-mono text-lg font-semibold text-violet-200">{s.tool}</span>
                      <span className="text-base text-zinc-500">{argsLine(s.args)}</span>
                      <span className="ml-auto text-sm text-zinc-600">{s.ms} ms</span>
                    </div>
                    {line && <p className="mt-2 text-lg text-zinc-100">{line}</p>}
                    {s.error && <p className="mt-2 text-base text-red-300">{s.error}</p>}
                    {s.why && <p className="mt-1 text-base text-zinc-500">{s.why}</p>}
                    <div className="mt-2 flex flex-wrap gap-x-6 gap-y-1 text-base">
                      {reasoning.length > 0 && (
                        <details>
                          <summary className="cursor-pointer text-sky-300">Why the agent chose this</summary>
                          <div className="mt-2 max-w-3xl space-y-2 rounded-lg bg-zinc-950 p-3 text-base text-zinc-400">
                            {reasoning.map((r, i) => <p key={i} className="whitespace-pre-line">{r}</p>)}
                          </div>
                        </details>
                      )}
                      {s.result && (
                        <details>
                          <summary className="cursor-pointer text-sky-300">Raw result</summary>
                          <pre className="mt-2 max-h-72 overflow-auto rounded-lg bg-zinc-950 p-3 text-sm text-zinc-300">{pretty(s.result)}</pre>
                        </details>
                      )}
                    </div>
                  </div>
                ) : (
                  <p className="pt-1 text-lg text-zinc-300">{s.text}</p>
                )}
              </li>
            );
          })}
          {running && <li className="animate-pulse text-lg text-zinc-500">Agent is working…</li>}
        </ol>
      </section>

      {final && (
        <details className="rounded-xl border border-zinc-800 bg-zinc-900 p-4">
          <summary className="cursor-pointer text-lg text-sky-300">The agent&apos;s closing message</summary>
          <p className="mt-3 whitespace-pre-line text-lg text-zinc-300">{final.text}</p>
        </details>
      )}
    </div>
  );
}
