import Link from "next/link";
import { facName, formatDateTime, fmtHours, money } from "@/lib/api";
import type { Alert } from "@/lib/types";
import { CategoryBadge } from "./Badges";

export function planWords(p: NonNullable<Alert["plan"]>): string {
  const bits: string[] = [];
  if (p.trucks) bits.push(`send ${p.trucks} truck${p.trucks > 1 ? "s" : ""}, ${p.trips_per_truck} trip${p.trips_per_truck > 1 ? "s" : ""} each`);
  for (const s of p.shut_ins) bits.push(`shut in ${s.well} ${s.start_after_min <= 0 ? "now" : `in ${s.start_after_min} min`}`);
  return bits.join(" + ") || (p.tank_trips ? "let the tank trip" : "no action needed");
}

export default function AlertCard({ a, compact = false }: { a: Alert; compact?: boolean }) {
  const failure = a.category === "pump_failure";
  const urgent = failure && a.hours_to_limit && a.hours_to_limit.p50 < 3;
  return (
    <article className={`rounded-xl border bg-zinc-900 p-5 ${failure ? "border-red-500/40" : "border-zinc-800"}`}>
      <div className="flex flex-wrap items-start gap-x-6 gap-y-3">
        <div className="min-w-0 flex-1 space-y-2">
          <div className="flex flex-wrap items-center gap-3">
            <span className="text-3xl font-bold tabular-nums text-zinc-600">{a.order}</span>
            <CategoryBadge category={a.category} />
            <span className="text-sm text-zinc-500">
              confidence {Math.round(a.confidence * 100)}% · started {formatDateTime(a.onset_ts)}
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
                  {a.hours_to_limit ? fmtHours(a.hours_to_limit.p50) : "–"}
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
          <Link href={`/facility/${a.facility_id}`} className="text-sky-300 hover:text-sky-200">
            See every option and the what-if replay →
          </Link>
        </p>
      )}
      {a.facility_name !== facName(a.facility_id) && null}
    </article>
  );
}
