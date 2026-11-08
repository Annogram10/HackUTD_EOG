"use client";

import Link from "next/link";
import { facName, formatDateTime, formatTime, fmtHours, money } from "@/lib/api";
import type { Alert } from "@/lib/types";
import { useApp } from "./AppProvider";
import { CategoryBadge } from "./Badges";
import { WarningIcon } from "./Icons";

export function planWords(p: NonNullable<Alert["plan"]>): string {
  const bits: string[] = [];
  if (p.trucks) bits.push(`send ${p.trucks} truck${p.trucks > 1 ? "s" : ""}, ${p.trips_per_truck} trip${p.trips_per_truck > 1 ? "s" : ""} each`);
  for (const s of p.shut_ins) bits.push(`shut in ${s.well} ${s.start_after_min <= 0 ? "now" : `in ${s.start_after_min} min`}`);
  return bits.join(" + ") || (p.tank_trips ? "let the tank trip" : "no action needed");
}

export default function AlertCard({ a, compact = false }: { a: Alert; compact?: boolean }) {
  const { overview } = useApp();
  const failure = a.category === "pump_failure";
  // Danger = the tank reaches shutdown before the repair ends (or already has). Same rule as the danger card.
  const now = overview ? Date.parse(overview.now_ts) : NaN;
  const repairLeft = a.repair_end_ts && !Number.isNaN(now) ? (Date.parse(a.repair_end_ts) - now) / 3.6e6 : null;
  const danger = a.level ? a.level === "red" : failure && (a.tripped || (a.hours_to_limit && repairLeft !== null && a.hours_to_limit.p50 < repairLeft));
  const minor = a.level === "green";
  const urgent = danger;
  return (
    <article className="border border-zinc-700 bg-zinc-900 p-5">
      <div className="flex flex-wrap items-start gap-x-6 gap-y-3">
        <div className="min-w-0 flex-1 space-y-2">
          <div className="flex flex-wrap items-center gap-3">
            <span className="text-3xl font-bold tabular-nums text-zinc-600">{a.order}</span>
            <span className={`inline-flex items-center gap-1.5 px-2.5 py-0.5 text-sm font-semibold uppercase ring-1 ${danger ? "bg-red-500/15 text-red-300 ring-red-500/50" : minor ? "bg-zinc-800 text-zinc-300 ring-zinc-600" : "bg-amber-500/15 text-amber-300 ring-amber-500/40"}`}>
              {!minor && <WarningIcon />}
              {danger ? "Danger" : minor ? "Minor" : "Check soon"}
            </span>
            <CategoryBadge category={a.category} minor={minor} />
            <span className="text-sm text-zinc-500">
              confidence {Math.round(a.confidence * 100)}% · started {formatDateTime(a.onset_ts)} · noticed {formatDateTime(a.detected_ts)}
            </span>
          </div>
          <h3 className="text-2xl font-semibold text-zinc-100">
            <Link href={`/facility/${a.facility_id}`} className="hover:text-amber-300 hover:underline">
              {a.facility_name}
            </Link>
            <span className="ml-3 text-base font-normal text-zinc-500">{a.asset_id}</span>
          </h3>
          {!compact && (
            <ul className="space-y-1 text-lg text-zinc-300">
              {a.evidence.map((e) => (
                <li key={e}>
                  <span className="mr-2 text-zinc-600">•</span>
                  {e}
                </li>
              ))}
            </ul>
          )}
        </div>

        {failure && (
          <div className="w-full shrink-0 rounded-lg bg-zinc-950/60 p-4 sm:w-80">
            {a.tripped ? (
              <p className="text-xl font-semibold text-red-300">Tank already at shutdown. Wells stay shut in until the repair ends.</p>
            ) : (
              <>
                <p className="text-sm uppercase tracking-wide text-zinc-500">Tank reaches shutdown in</p>
                <p className={`text-5xl font-bold tabular-nums ${urgent ? "text-red-400" : "text-amber-300"}`}>
                  {a.hours_to_limit ? fmtHours(a.hours_to_limit.p50) : "n/a"}
                </p>
                {a.hours_to_limit && (
                  <p className="text-sm text-zinc-500">
                    best {fmtHours(a.hours_to_limit.p90)} · worst {fmtHours(a.hours_to_limit.p10)} · tank {a.level_pct}% full
                  </p>
                )}
              </>
            )}
            {a.plan && (
              <div className="mt-3 border-t border-zinc-800 pt-3">
                <p className="text-sm uppercase tracking-wide text-zinc-500">Cheapest plan</p>
                <p className="text-lg text-zinc-100">
                  {planWords(a.plan)} <span className="font-bold text-emerald-300">{money(a.plan.cost)}</span>
                </p>
                {a.truck_cost && a.truck_cost.trucks > 0 && (
                  <p className="text-sm text-zinc-500">
                    {a.truck_cost.trucks} truck{a.truck_cost.trucks > 1 ? "s" : ""} x {a.truck_cost.trips} trip{a.truck_cost.trips > 1 ? "s" : ""} x {money(a.truck_cost.trip_price)} per trip
                    {a.truck_cost.arrive_min ? `, arrives in ${a.truck_cost.arrive_min} min` : ""}
                    {a.truck_cost.shut_in_total > 0 ? `, plus ${money(a.truck_cost.shut_in_total)} lost sales from shut-ins` : ""}
                  </p>
                )}
                {(() => {
                  const nothing = a.options.find((o) => o.label === "Do nothing");
                  if (!nothing || nothing.cost <= a.plan.cost) return null;
                  return (
                    <p className="mt-1 text-base text-zinc-300">
                      Doing nothing: <span className="font-semibold text-red-300">{money(nothing.cost)}</span>
                      {nothing.trip_ts ? ` (tank reaches shutdown at ${formatTime(nothing.trip_ts)} UTC)` : ""}.{" "}
                      <span className="font-semibold text-emerald-300">Saves {money(nothing.cost - a.plan.cost)}.</span>
                    </p>
                  );
                })()}
                {a.trucks_shared_with && a.trucks_shared_with.length > 0 && (
                  <p className="text-sm text-zinc-500">Planned together with {a.trucks_shared_with.length} other failure(s) sharing the trucks</p>
                )}
              </div>
            )}
          </div>
        )}
      </div>
      {!failure && <p className="mt-3 text-lg font-medium text-sky-300">{a.action_text} to check it</p>}
      {failure && (
        <p className="mt-3 text-base">
          <Link href={`/facility/${a.facility_id}`} className="text-sky-400 underline underline-offset-2 hover:text-sky-300">
            See every option and the what-if replay
          </Link>
        </p>
      )}
      {a.facility_name !== facName(a.facility_id) && null}
    </article>
  );
}
