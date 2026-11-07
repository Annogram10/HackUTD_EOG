"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useEffect, useState } from "react";
import AlertCard from "@/components/AlertCard";
import { useApp } from "@/components/AppProvider";
import { FacStatusBadge } from "@/components/Badges";
import { SeriesChart, WhatIfChart } from "@/components/charts";
import FlagCard from "@/components/FlagCard";
import PlanTable from "@/components/PlanTable";
import ReadingBar from "@/components/ReadingBar";
import { formatDateTime, getFacility, getSeries, money } from "@/lib/api";
import type { Alert, FacilityDetail } from "@/lib/types";

const METRICS: Record<string, string[]> = {
  tank: ["level_pct"], pump: ["status", "flow_bpd", "discharge_psi"], pipeline: ["receive_flow_bpd", "pressure_psi"],
  well: ["water_bpd", "status"], facility: ["inflow_bpd"],
};

function WhatIf({ a, now }: { a: Alert; now: number }) {
  if (!a.whatif || !a.plan) return null;
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <h3 className="text-xl font-semibold">What-if replay: tank level from now until the repair ends</h3>
      <p className="mb-2 text-base text-zinc-400">
        <span className="font-semibold text-red-300">Red dashed</span>: nothing done. <span className="font-semibold text-emerald-300">Green</span>: the recommended plan.
      </p>
      <WhatIfChart doNothing={a.whatif.do_nothing} withPlan={a.whatif.with_plan} shutdown={a.whatif.shutdown_pct} warning={a.whatif.warning_pct}
        now={now} repairEnd={Math.floor(new Date(a.whatif.repair_end_ts).getTime() / 1000)} marks={a.whatif.marks} />
    </div>
  );
}

function SensorPicker({ f, dataset }: { f: FacilityDetail; dataset: string }) {
  const assets = [
    ["Tank", f.assets.tank, "tank"], ["Pump", f.assets.pump, "pump"], ["Pipeline", f.assets.pipeline, "pipeline"],
    ["Facility total", f.id, "facility"], ...f.assets.wells.map((w) => [w, w, "well"]),
  ] as [string, string, string][];
  const [asset, setAsset] = useState(assets[1][1]);
  const [metric, setMetric] = useState("flow_bpd");
  const [hours, setHours] = useState(72);
  const [pts, setPts] = useState<[number, number][]>([]);
  const kind = assets.find((a) => a[1] === asset)?.[2] ?? "pump";

  useEffect(() => {
    let alive = true;
    getSeries(dataset, asset, metric, hours).then((r) => alive && setPts(r.points)).catch(() => alive && setPts([]));
    return () => { alive = false; };
  }, [dataset, asset, metric, hours]);

  const sel = "rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-1.5 text-base text-zinc-100";
  return (
    <div>
      <div className="mb-3 flex flex-wrap gap-3">
        <select className={sel} value={asset} onChange={(e) => { setAsset(e.target.value); setMetric(METRICS[assets.find((a) => a[1] === e.target.value)![2]][0]); }}>
          {assets.map(([l, id]) => <option key={id} value={id}>{l} ({id})</option>)}
        </select>
        <select className={sel} value={metric} onChange={(e) => setMetric(e.target.value)}>
          {METRICS[kind].map((m) => <option key={m} value={m}>{m}</option>)}
        </select>
        <select className={sel} value={hours} onChange={(e) => setHours(Number(e.target.value))}>
          <option value={12}>last 12 h</option><option value={24}>last 24 h</option><option value={72}>last 72 h</option><option value={500}>whole dataset</option>
        </select>
      </div>
      <SeriesChart title={`${asset} · ${metric}`} unit="" points={pts} />
    </div>
  );
}

export default function FacilityView() {
  const { id } = useParams<{ id: string }>();
  const { dataset, shifts } = useApp();
  const [got, setGot] = useState<{ key: string; data: FacilityDetail | null } | null>(null);
  const key = `${dataset}/${id}`;
  const f = got && got.key === key ? got.data : undefined; // undefined = loading

  useEffect(() => {
    if (!dataset) return;
    let alive = true;
    getFacility(dataset, id).then((r) => alive && setGot({ key, data: r })).catch(() => alive && setGot({ key, data: null }));
    return () => { alive = false; };
  }, [dataset, id, key]);

  if (f === undefined) return <div className="h-96 animate-pulse rounded-2xl bg-zinc-900" />;
  if (f === null)
    return (
      <div className="space-y-3">
        <h1 className="text-3xl font-bold">Facility not found in this dataset</h1>
        <Link href="/" className="text-sky-300 hover:underline">← Back to the map</Link>
      </div>
    );

  const bands = f.events.map((e) => ({
    from: Math.floor(new Date(e.onset_ts).getTime() / 1000),
    to: e.end_ts ? Math.floor(new Date(e.end_ts).getTime() / 1000) : f.now,
    color: e.category === "pump_failure" ? "#ef4444" : e.category === "pipeline_leak" ? "#f97316" : "#fbbf24",
    label: `${e.category.replace("_", " ")} (${e.status})`,
  }));
  const lim = (label: string) => f.readings.find((r) => r.label === label);
  const linesFor = (metric: string) =>
    metric === "level_pct" ? [{ value: f.warning_pct, label: `warning ${f.warning_pct}%`, color: "#fbbf24" }, { value: f.shutdown_pct, label: `shutdown ${f.shutdown_pct}%`, color: "#f87171" }]
    : metric === "flow_bpd" && lim("Pump flow") ? [{ value: lim("Pump flow")!.limit, label: "rated flow", color: "#34d399" }] : [];
  const flagFacts = shifts.length ? f.flags : [];
  const failure = f.alerts.find((a) => a.category === "pump_failure");

  return (
    <div className="space-y-8">
      <div>
        <Link href="/" className="text-base text-sky-300 hover:text-sky-200">← Network map</Link>
        <div className="mt-2 flex flex-wrap items-center gap-4">
          <h1 className="text-4xl font-bold">{f.name}</h1>
          <FacStatusBadge status={f.status} />
        </div>
        <p className="mt-1 text-lg text-zinc-400">
          {f.system_id} · tank {f.capacity_bbl} bbl · {f.wells.length} wells · up to {money(f.lost_revenue_per_hour)}/h lost if shut in · data to {formatDateTime(new Date(f.now * 1000).toISOString())}
        </p>
      </div>

      {f.alerts.length > 0 && (
        <section className="space-y-4">
          <h2 className="text-2xl font-semibold">In progress</h2>
          {f.alerts.map((a) => <AlertCard key={a.event_id} a={a} />)}
        </section>
      )}

      {failure?.plan && (
        <section className="space-y-4">
          <h2 className="text-2xl font-semibold">Every plan option, side by side</h2>
          <PlanTable a={failure} />
          <WhatIf a={failure} now={f.now} />
          <p className="text-base text-zinc-500">
            Trucks arrive {f.response_min} min after the call and can come back every {f.cycle_min} min. The recommended row plans every failure in {f.system_id} together because they share the trucks.
          </p>
        </section>
      )}

      <section>
        <h2 className="mb-3 text-2xl font-semibold">Current readings next to their limits</h2>
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          {f.readings.map((r) => <ReadingBar key={r.label} {...r} />)}
        </div>
      </section>

      <section>
        <h2 className="mb-1 text-2xl font-semibold">Trends, last 72 hours</h2>
        <p className="mb-3 text-base text-zinc-500">Shaded bands mark when a problem was in progress.</p>
        <div className="grid gap-4 lg:grid-cols-2">
          {f.series.map((s) => <SeriesChart key={s.label} title={s.label} unit={s.unit} points={s.points} lines={linesFor(s.metric)} bands={bands} />)}
        </div>
      </section>

      <section>
        <h2 className="mb-3 text-2xl font-semibold">Look at any sensor</h2>
        <SensorPicker f={f} dataset={f.dataset} />
      </section>

      <section>
        <h2 className="mb-3 text-2xl font-semibold">Wells</h2>
        <div className="overflow-x-auto rounded-xl border border-zinc-800 bg-zinc-900">
          <table className="w-full text-left text-lg">
            <thead className="text-sm uppercase tracking-wide text-zinc-500"><tr><th className="px-4 py-3">Well</th><th className="px-4 py-3">Status</th><th className="px-4 py-3">Water</th><th className="px-4 py-3">Oil</th><th className="px-4 py-3">Gas</th><th className="px-4 py-3 text-right">Lost if shut in</th></tr></thead>
            <tbody className="divide-y divide-zinc-800">
              {f.wells_detail.map((w) => {
                const on = f.wells.find((x) => x.id === w.id)?.producing;
                return (
                  <tr key={w.id}>
                    <td className="px-4 py-3 font-semibold">{w.id}</td>
                    <td className="px-4 py-3">{on ? <span className="text-emerald-300">Producing</span> : <span className="text-zinc-500">Shut in</span>}</td>
                    <td className="px-4 py-3 tabular-nums">{w.baseline_water_bpd} bpd</td>
                    <td className="px-4 py-3 tabular-nums">{w.oil_bpd} bpd</td>
                    <td className="px-4 py-3 tabular-nums">{w.gas_mcfd} mcfd</td>
                    <td className="px-4 py-3 text-right tabular-nums">{money(w.rev_per_hour)}/h</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-2xl font-semibold">Problems detected in the data</h2>
        {f.events.length === 0 ? <p className="text-lg text-zinc-500">None in this dataset.</p> : (
          <ul className="divide-y divide-zinc-800 rounded-xl border border-zinc-800 bg-zinc-900">
            {f.events.map((e) => (
              <li key={e.event_id} className="flex flex-wrap items-baseline gap-x-5 gap-y-1 px-5 py-3 text-lg">
                <span className="font-semibold capitalize">{e.category.replace("_", " ")}</span>
                <span className="text-zinc-400">{formatDateTime(e.onset_ts)} → {e.end_ts ? formatDateTime(e.end_ts) : "ongoing"}</span>
                <span className="text-sm text-zinc-500">confidence {Math.round(e.confidence * 100)}%</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="space-y-4">
        <h2 className="text-2xl font-semibold">Operator flags, photos and notes</h2>
        {flagFacts.length === 0 ? <p className="text-lg text-zinc-500">No flags uploaded for this facility.</p> : flagFacts.map((x) => <FlagCard key={x.id} flag={x} showDate linkEquipment={false} />)}
      </section>
    </div>
  );
}
