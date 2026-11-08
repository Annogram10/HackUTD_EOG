"use client";

// NOW: what is wrong right now and what to do about it, then the map and every facility.

import Link from "next/link";
import { useState } from "react";
import AlertCard from "@/components/AlertCard";
import { ErrorState, NowSkeleton } from "@/components/Skeleton";
import EvidenceCharts from "@/components/EvidenceCharts";
import RiskCard from "@/components/RiskCard";
import TimeTravel from "@/components/TimeTravel";
import { FacStatusBadge } from "@/components/Badges";
import { useApp } from "@/components/AppProvider";
import SiteMap, { MapLegend } from "@/components/SiteMap";
import { fmtHours, money } from "@/lib/api";
import type { FacilityStatus } from "@/lib/types";

const RANK: Record<FacilityStatus, number> = { tripped: 0, failure: 1, leak: 2, worn: 3, ok: 4 };

function plural(n: number, one: string, many: string) {
  return `${n} ${n === 1 ? one : many}`;
}

export default function Now() {
  const { overview, shift, asOf, offline } = useApp();
  const [picked, setPicked] = useState<string | null>(null);

  if (!overview) return offline ? <ErrorState what="the facilities" /> : <NowSkeleton />;

  const system =
    overview.systems.find((s) => s.id === picked) ??
    overview.systems.find((s) => s.facilities.some((f) => f.status !== "ok")) ??
    overview.systems[0];
  const flags = shift?.flags ?? [];
  const review = flags.filter((f) => f.status === "pending").length;
  const phoneLine = shift ? (
    <>
      From the phone: {plural(flags.length, "flag", "flags")}
      {review ? `, ${review} not reviewed yet` : ""}. <Link href="/flags" className="text-sky-400 underline underline-offset-2 hover:text-sky-300">See flags</Link>
    </>
  ) : asOf !== null ? "No shift had started yet at this time, so there are no phone flags to show." : "No phone report for this dataset yet. Flags from the field appear here once the phone uploads.";
  const allFacs = overview.systems.flatMap((s) => s.facilities);
  const sorted = [...allFacs].sort((a, b) => RANK[a.status] - RANK[b.status] || (a.hours_to_limit?.p50 ?? 99) - (b.hours_to_limit?.p50 ?? 99));

  return (
    <div className="space-y-8">
      <div className="space-y-1.5">
        <p className="hud">SYS//STATUS</p>
        <RiskCard footer={phoneLine}>
          <TimeTravel bare />
        </RiskCard>
      </div>
      <EvidenceCharts />

      {overview.alerts.length === 0 && (
        <section className="border border-emerald-500/40 bg-emerald-500/5 p-5">
          <h2 className="text-2xl font-semibold text-emerald-300">No problems in progress</h2>
          <p className="mt-1 text-base text-zinc-400">Every facility reads normal at this time. Nothing needs a decision.</p>
        </section>
      )}
      {overview.alerts.length > 0 && (
        <section className="space-y-4">
          <div>
            <p className="hud">SYS//PLAN</p>
            <h2 className="text-2xl font-semibold">What to do</h2>
            <p className="text-base text-zinc-500">Most urgent first. These are suggestions for a person to approve, nothing here operates equipment.</p>
          </div>
          {overview.alerts.map((a) => <AlertCard key={a.event_id} a={a} />)}
        </section>
      )}

      <section>
        <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="hud">SYS//NETWORK</p>
            <h2 className="text-2xl font-semibold">Map</h2>
          </div>
          {overview.systems.length > 1 && (
            <div className="flex flex-wrap gap-2">
              {overview.systems.map((s) => {
                const bad = s.facilities.some((f) => f.status !== "ok");
                return (
                  <button key={s.id} onClick={() => setPicked(s.id)}
                    className={`px-4 py-1.5 text-base font-medium ring-1 ${s.id === system.id ? "bg-zinc-800 text-zinc-100 ring-sky-400" : "bg-zinc-900 text-zinc-300 ring-zinc-700 hover:bg-zinc-800"}`}>
                    {bad && <span className="mr-2 inline-block h-2 w-2 rounded-full bg-red-500" />}
                    {s.id}
                  </button>
                );
              })}
            </div>
          )}
        </div>
        <SiteMap system={system} shift={shift} />
        <MapLegend />
        {system.shared && system.shared.events.length > 1 && (
          <p className="mt-3 rounded-lg bg-sky-500/10 px-4 py-2 text-base text-sky-200">
            {system.shared.events.length} failures in {system.id} share {system.shared.fleet} trucks. Planned together: {system.shared.trucks_used} used, {money(system.shared.total_cost)} total.
          </p>
        )}
      </section>

      <details className="group rounded-xl border border-zinc-800 bg-zinc-900" open={overview.alerts.length === 0}>
        <summary className="cursor-pointer select-none px-5 py-4 text-xl font-semibold text-zinc-100">
          All {allFacs.length} facilities <span className="text-base font-normal text-zinc-500">(tank level and time to shutdown)</span>
        </summary>
        <div className="overflow-x-auto border-t border-zinc-800">
          <table className="w-full text-left text-lg">
            <thead className="text-sm uppercase tracking-wide text-zinc-500">
              <tr><th className="px-4 py-3">Facility</th><th className="px-4 py-3">Status</th><th className="px-4 py-3 text-right">Tank</th><th className="px-4 py-3 text-right">Time to shutdown</th><th className="px-4 py-3 text-right">Lost revenue if shut in</th></tr>
            </thead>
            <tbody className="divide-y divide-zinc-800">
              {sorted.map((f) => (
                <tr key={f.id} className="hover:bg-zinc-800/50">
                  <td className="px-4 py-3 font-semibold"><Link href={`/facility/${f.id}`} className="hover:text-amber-300 hover:underline">{f.name}</Link></td>
                  <td className="px-4 py-3"><FacStatusBadge status={f.status} severity={f.severity} /></td>
                  <td className="px-4 py-3">
                    <div className="flex items-center justify-end gap-3">
                      <div className="relative h-3 w-32 rounded bg-zinc-800">
                        <div className={`h-full rounded ${f.level_pct >= f.shutdown_pct - 0.1 ? "bg-red-500" : f.level_pct >= f.warning_pct ? "bg-amber-400" : "bg-sky-500"}`} style={{ width: `${f.level_pct}%` }} />
                        <div className="absolute inset-y-0 w-px bg-red-300" style={{ left: `${f.shutdown_pct}%` }} />
                      </div>
                      <span className="tabular-nums text-zinc-300">{f.level_pct.toFixed(0)}%</span>
                    </div>
                  </td>
                  <td className="px-4 py-3 text-right">
                    {f.status === "tripped" ? <span className="font-semibold text-red-300">Tripped</span>
                      : f.hours_to_limit ? <span className="font-semibold text-red-300">{fmtHours(f.hours_to_limit.p50)}</span>
                      : <span className="text-zinc-500">pump is running</span>}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-zinc-400">{money(f.lost_revenue_per_hour)}/h</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </div>
  );
}
