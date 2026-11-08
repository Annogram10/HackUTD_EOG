"use client";

// "What dropped": for each problem in progress, the sensors that moved most, with a one-line caption from Nemotron.
// Only shows data up to the chosen moment, never later.

import Link from "next/link";
import { useEffect, useState } from "react";
import { formatTime, getEvidence } from "@/lib/api";
import type { Evidence } from "@/lib/types";
import { useApp } from "./AppProvider";
import { SeriesChart, WhatIfChart } from "./charts";

const KIND: Record<string, string> = { pump_failure: "Pump failure", pipeline_leak: "Possible leak", pump_degradation: "Pump wearing out" };

export default function EvidenceCharts() {
  const { dataset, asOf, playing, overview } = useApp();
  const key = dataset ? `${dataset}|${asOf ?? "live"}|${playing ? "rules" : "ai"}` : null;
  const [got, setGot] = useState<{ key: string; data: Evidence | null } | null>(null);

  useEffect(() => {
    if (!dataset || !key) return;
    let alive = true;
    getEvidence(dataset, asOf ?? undefined, !playing).then((r) => alive && setGot({ key, data: r })).catch(() => alive && setGot({ key, data: null }));
    return () => {
      alive = false;
    };
  }, [dataset, asOf, key, playing]);

  const ev = got?.data;
  if (got && got.key === key && !ev)
    return (
      <section>
        <h2 className="text-2xl font-semibold">What dropped</h2>
        <p className="mt-1 text-base text-zinc-400">The charts could not be loaded. The rest of the page is unaffected.</p>
      </section>
    );
  if (!ev) return null;
  if (ev.sections.length === 0)
    return (
      <section>
        <h2 className="text-2xl font-semibold">What dropped</h2>
        <p className="mt-1 text-base text-zinc-500">No problems at this time, so there are no charts. They appear here when a problem starts and show which readings changed.</p>
      </section>
    );
  const stale = got.key !== key;

  return (
    <section className={`space-y-4 ${stale ? "opacity-80" : ""}`}>
      <div>
        <h2 className="text-2xl font-semibold">What dropped</h2>
        <p className="text-base text-zinc-500">
          Biggest changes at each problem, up to the time shown. Shaded from when it began: red is danger, amber is check soon.
        </p>
      </div>
      {ev.sections.map((s) => (
        <div key={s.facility_id} className="space-y-3 rounded-xl border border-zinc-800 bg-zinc-900 p-4">
          <h3 className="text-xl font-semibold text-zinc-100">
            <Link href={`/facility/${s.facility_id}`} className="hover:text-amber-300 hover:underline">{s.name}</Link>
            <span className="ml-3 text-base font-normal text-zinc-500">{KIND[s.category] ?? s.category}</span>
          </h3>
          <div className="grid gap-4 lg:grid-cols-2">
            {(() => {
              const a = overview?.alerts.find((x) => x.facility_id === s.facility_id && x.category === "pump_failure" && x.whatif);
              if (!a || !a.whatif) return null;
              const nothing = a.options.find((o) => o.label === "Do nothing");
              return (
                <div className="space-y-1 lg:col-span-2">
                  <div>
                    <h4 className="text-lg text-zinc-300">Projected tank level</h4>
                    <WhatIfChart doNothing={a.whatif.do_nothing} withPlan={a.whatif.with_plan} shutdown={a.whatif.shutdown_pct} warning={a.whatif.warning_pct}
                      now={ev.now} repairEnd={Math.floor(new Date(a.whatif.repair_end_ts).getTime() / 1000)} marks={a.whatif.marks} />
                  </div>
                  <p className="px-1 text-base text-zinc-300">
                    <span className="font-semibold text-red-300">Red dashed</span>: if nothing is done{nothing?.trip_ts ? `, the tank reaches shutdown at ${formatTime(nothing.trip_ts)} UTC` : ""}.{" "}
                    <span className="font-semibold text-emerald-300">Green</span>: with the cheapest plan. The repair ends at {formatTime(a.whatif.repair_end_ts)} UTC.
                  </p>
                </div>
              );
            })()}
            {s.charts.map((c) => (
              <div key={c.metric} className="space-y-1">
                <SeriesChart bare title={c.label} unit={c.unit} points={c.points} height={170}
                  bands={[{ from: s.onset_unix, to: ev.now, color: s.level === "red" ? "#ff3b3b" : "#e8a33d", label: s.level === "red" ? "Danger: problem in progress" : "Check soon: problem in progress" }]}
                  lines={c.unit === "%" ? [] : [{ value: c.base, label: "normal", color: "#6e6475" }]} />
                <p className="px-1 text-base text-zinc-300">{c.caption}</p>
              </div>
            ))}
          </div>
        </div>
      ))}
    </section>
  );
}
