"use client";

// SHIFT OVERVIEW: risk brief, headline numbers, the site map, and every tank's level + countdown.

import Link from "next/link";
import { useState } from "react";
import { FacStatusBadge } from "@/components/Badges";
import { useApp } from "@/components/AppProvider";
import RiskBrief from "@/components/RiskBrief";
import SiteMap, { MapLegend } from "@/components/SiteMap";
import Stat from "@/components/Stat";
import { fmtHours, formatDateTime, money } from "@/lib/api";
import { usePriorities } from "@/lib/hooks";
import type { FacilityStatus } from "@/lib/types";

const RANK: Record<FacilityStatus, number> = { tripped: 0, failure: 1, leak: 2, worn: 3, ok: 4 };

export default function Overview() {
  const { overview, shift, loading } = useApp();
  const priorities = usePriorities(shift?.id);
  const [picked, setPicked] = useState<string | null>(null);

  if (!overview || (loading && !overview)) return <div className="h-96 animate-pulse rounded-2xl bg-zinc-900" />;

  const first = overview.systems.find((s) => s.id === picked)
    ?? overview.systems.find((s) => shift?.route_planned.some((id) => s.facilities.some((f) => f.id === id)))
    ?? overview.systems.find((s) => s.facilities.some((f) => f.status !== "ok"))
    ?? overview.systems[0];
  const system = first;
  const flags = shift?.flags ?? [];
  const missed = shift ? shift.route_planned.filter((s) => !shift.route_walked.includes(s)).length : 0;
  const allFacs = overview.systems.flatMap((s) => s.facilities);
  const sorted = [...allFacs].sort((a, b) => RANK[a.status] - RANK[b.status] || (a.hours_to_limit?.p50 ?? 99) - (b.hours_to_limit?.p50 ?? 99));

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-4xl font-bold">Shift overview</h1>
        <p className="mt-1 text-lg text-zinc-400">
          Sensor data as of {formatDateTime(overview.now_ts)}. These are things to check, not diagnoses.
        </p>
      </div>

      <RiskBrief items={priorities} />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-5">
        <Stat label="Pump failures" value={overview.counts.failures} tone={overview.counts.failures ? "text-red-400" : "text-emerald-400"} sub="in progress" />
        <Stat label="Possible leaks" value={overview.counts.leaks} tone={overview.counts.leaks ? "text-orange-400" : "text-emerald-400"} sub="in progress" />
        <Stat label="Pumps wearing out" value={overview.counts.worn} tone={overview.counts.worn ? "text-amber-400" : "text-emerald-400"} sub="in progress" />
        <Stat label="Flags last shift" value={flags.length} sub={`${flags.filter((f) => f.status === "pending").length} need review`} />
        <Stat label="Stops checked" value={shift ? `${shift.route_planned.length - missed} / ${shift.route_planned.length}` : "–"}
          tone={missed ? "text-amber-400" : "text-emerald-400"} sub={missed ? `${missed} missed` : "full route"} />
      </div>

      <section>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
          <h2 className="text-2xl font-semibold">Network map</h2>
          <div className="flex flex-wrap gap-2">
            {overview.systems.map((s) => {
              const bad = s.facilities.some((f) => f.status !== "ok");
              return (
                <button key={s.id} onClick={() => setPicked(s.id)}
                  className={`rounded-full px-4 py-1.5 text-base font-medium ring-1 ${s.id === system.id ? "bg-zinc-100 text-zinc-950 ring-zinc-100" : "bg-zinc-900 text-zinc-300 ring-zinc-700 hover:bg-zinc-800"}`}>
                  {bad && <span className="mr-2 inline-block h-2 w-2 rounded-full bg-red-500" />}
                  {s.id}
                </button>
              );
            })}
          </div>
        </div>
        <SiteMap system={system} shift={shift} />
        <MapLegend />
        {system.shared && system.shared.events.length > 1 && (
          <p className="mt-3 rounded-lg bg-sky-500/10 px-4 py-2 text-base text-sky-200">
            {system.shared.events.length} failures in {system.id} share {system.shared.fleet} trucks. Planned together: {system.shared.trucks_used} used, {money(system.shared.total_cost)} total.
          </p>
        )}
      </section>

      <section>
        <h2 className="mb-3 text-2xl font-semibold">Every facility: tank level and countdown</h2>
        <div className="overflow-x-auto rounded-xl border border-zinc-800 bg-zinc-900">
          <table className="w-full text-left text-lg">
            <thead className="text-sm uppercase tracking-wide text-zinc-500">
              <tr><th className="px-4 py-3">Facility</th><th className="px-4 py-3">Status</th><th className="px-4 py-3">Tank</th><th className="px-4 py-3">Time to shutdown</th><th className="px-4 py-3 text-right">Lost revenue if shut in</th></tr>
            </thead>
            <tbody className="divide-y divide-zinc-800">
              {sorted.map((f) => (
                <tr key={f.id} className="hover:bg-zinc-800/50">
                  <td className="px-4 py-3 font-semibold"><Link href={`/facility/${f.id}`} className="hover:text-amber-300 hover:underline">{f.name}</Link></td>
                  <td className="px-4 py-3"><FacStatusBadge status={f.status} /></td>
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-3">
                      <div className="relative h-3 w-32 rounded bg-zinc-800">
                        <div className={`h-full rounded ${f.level_pct >= f.shutdown_pct - 0.1 ? "bg-red-500" : f.level_pct >= f.warning_pct ? "bg-amber-400" : "bg-sky-500"}`} style={{ width: `${f.level_pct}%` }} />
                        <div className="absolute inset-y-0 w-px bg-red-300" style={{ left: `${f.shutdown_pct}%` }} />
                      </div>
                      <span className="tabular-nums text-zinc-300">{f.level_pct.toFixed(0)}%</span>
                    </div>
                  </td>
                  <td className="px-4 py-3 tabular-nums">
                    {f.status === "tripped" ? <span className="font-semibold text-red-300">Tripped</span>
                      : f.hours_to_limit ? <span className="font-semibold text-red-300">{fmtHours(f.hours_to_limit.p50)}</span>
                      : <span className="text-zinc-600">pump is running</span>}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-zinc-400">{money(f.lost_revenue_per_hour)}/h</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
