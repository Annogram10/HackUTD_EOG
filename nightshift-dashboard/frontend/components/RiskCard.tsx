"use client";

// Is this moment dangerous? The rules decide; a Nemotron note is added when ready. Red = alarm for phone and glasses.

import { money } from "@/lib/api";
import type { RiskLevel } from "@/lib/types";
import { useApp } from "./AppProvider";
import { WarningIcon } from "./Icons";
import { CardSkeleton } from "./Skeleton";

const LOOK: Record<RiskLevel, { label: string; box: string; pill: string }> = {
  green: { label: "Grid stable", box: "border-emerald-400/50 bg-emerald-500/5", pill: "bg-emerald-500/20 text-emerald-300 ring-1 ring-emerald-400/60" },
  amber: { label: "Check soon", box: "border-amber-400/60 bg-amber-400/5", pill: "bg-amber-400/20 text-amber-200 ring-1 ring-amber-400/60" },
  red: { label: "// Alert", box: "border-red-500 bg-red-500/10", pill: "bg-red-500 text-zinc-950 danger-pulse" },
};

export default function RiskCard({ children, footer }: { children?: React.ReactNode; footer?: React.ReactNode }) {
  const { asOf, playing, risk, lastOk, acked, acknowledge } = useApp();

  // No danger check yet (first load, or the check failed): still show the time bar so playback never disappears.
  if (!risk)
    return (
      <section className="brackets key-panel border-2 p-5">
        <CardSkeleton lines={2} />
        {footer && <p className="mt-2 text-base text-zinc-300">{footer}</p>}
        {children && <div className="mt-4 border-t border-zinc-700/70 pt-4">{children}</div>}
      </section>
    );
  const look = LOOK[risk.level];
  const ai = risk.ai;
  // Only the items at the card's own level are reasons. A worn pump is never listed as a reason for danger.
  const mine = risk.reasons.filter((r) => r.level === risk.level);
  const others = risk.reasons.filter((r) => r.level !== risk.level);

  return (
    <section id="danger-card" key={risk.alarm_id ?? risk.level} className={`scroll-mt-28 brackets ${risk.level === "red" ? "brackets-red" : ""} border-2 p-5 ${look.box} ${risk.alarm && !acked ? "card-pulse" : ""}`}>
      <div className="flex flex-wrap items-center gap-3">
        <span className={`inline-flex items-center gap-2 px-3 py-1 text-lg font-bold uppercase ${look.pill}`}>
          {risk.level !== "green" && <WarningIcon />}
          {look.label}
        </span>
        <h2 className="text-2xl font-bold text-zinc-100">
          {risk.level === "green" ? "Quiet night in Avon, choom." : risk.headline}
        </h2>
      </div>
      {risk.level === "green" && risk.headline !== "All clear" && <p className="mt-2 text-base text-zinc-300">{risk.headline}.</p>}
      {risk.note && <p className="mt-2 text-lg text-zinc-300"><span className="text-zinc-500">AI note: </span>{risk.note}</p>}
      {mine.length > 0 && (
        <ul className="mt-2 space-y-0.5 text-base text-zinc-300">
          {mine.slice(0, 4).map((r, i) => (
            <li key={i}><span className="mr-2 text-zinc-500">•</span>{r.text}</li>
          ))}
        </ul>
      )}
      {others.length > 0 && (
        <p className="mt-2 text-base text-zinc-500">
          Also to check ({others.length}): {others.slice(0, 3).map((r) => r.text.split(":")[0]).join(", ")}{others.length > 3 ? ", …" : ""}. See the alerts below.
        </p>
      )}
      {risk.money.rows.length > 0 && (
        <div className="mt-3 border border-zinc-700 bg-zinc-950/40 px-4 py-3 text-base">
          <p className="text-zinc-300">
            <span className="font-semibold text-zinc-100">Cost.</span>{" "}
            One truck trip is {money(risk.money.trip_price)} and takes away {risk.money.trip_bbl} bbl.
            {risk.money.rows.length > 1 && (
              <> All together: <span className="font-semibold text-emerald-300">{money(risk.money.total_cost)}</span> to fix, {money(risk.money.total_do_nothing)} if nothing is done, saves {money(risk.money.total_saves)}.</>
            )}
          </p>
          <ul className="mt-1 space-y-0.5">
            {risk.money.rows.map((r) => (
              <li key={r.facility_id} className="flex flex-wrap gap-x-3 text-zinc-300">
                <span className="font-medium text-zinc-100">{r.name}</span>
                <span>
                  {r.trucks.trucks > 0
                    ? `${r.trucks.trucks} truck${r.trucks.trucks > 1 ? "s" : ""} x ${r.trucks.trips} trip${r.trucks.trips > 1 ? "s" : ""} = ${money(r.trucks.trucks_total)}`
                    : "no trucks"}
                  {r.trucks.shut_in_total > 0 ? ` + ${money(r.trucks.shut_in_total)} lost sales from shut-ins` : ""}
                  {r.trucks.arrive_min ? `, arrives in ${r.trucks.arrive_min} min` : ""}
                </span>
                <span className="ml-auto tabular-nums">
                  <span className="font-semibold text-emerald-300">{money(r.cost)}</span>
                  {r.do_nothing !== null && <span className="text-zinc-500"> vs {money(r.do_nothing)} doing nothing</span>}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {risk.alarm && (
        <div className="mt-3 flex flex-wrap items-center gap-3 bg-red-500/20 px-4 py-2">
          <p className="flex-1 text-base font-semibold text-red-100">
            {asOf === null ? "Alarm sent to the phone and glasses." : "Replay: an alarm would have gone off here."}
          </p>
          {acked ? (
            <span className="font-mono text-sm uppercase tracking-wider text-red-200">Acknowledged</span>
          ) : (
            <button type="button" onClick={acknowledge} className="btn-primary px-4 py-1.5 text-base font-semibold">
              Acknowledge
            </button>
          )}
        </div>
      )}
      <p className="mt-3 text-sm text-zinc-500">
        {playing
          ? "Playing: rules check only. The AI check runs when you pause. "
          : ai?.available
          ? `Level from the rules; note from ${ai.model?.split("/").pop()}. The AI never changes the level. `
          : ai?.pending
          ? "Level from the rules. AI note on its way. "
          : ai
          ? `Level from the rules (AI note not available: ${ai.error ?? "no answer"}). `
          : risk.reasons.length === 0
          ? "Nothing to check right now, so the AI was not asked. "
          : "Rules only. "}
        A person decides what to do.
        {lastOk && <> Last updated {lastOk.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}.</>}
      </p>
      {footer && <p className="mt-2 text-base text-zinc-300">{footer}</p>}
      {children && <div className="mt-4 border-t border-zinc-700/70 pt-4">{children}</div>}
    </section>
  );
}
