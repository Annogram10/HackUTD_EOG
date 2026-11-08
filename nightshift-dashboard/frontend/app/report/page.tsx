"use client";

// HANDOVER REPORT: the sensor handoff plus what the operator uploaded from the iPhone. Print or export.

import Link from "next/link";
import { useEffect, useState } from "react";
import { useApp } from "@/components/AppProvider";
import { PageSkeleton } from "@/components/Skeleton";
import FlagCard from "@/components/FlagCard";
import Stat from "@/components/Stat";
import { eventsUrl, facName, formatDate, formatDateTime, formatTime, getHandoff } from "@/lib/api";
import PriorityList from "@/components/PriorityList";
import { flagSignature, usePriorities, useReport } from "@/lib/hooks";
import type { Handoff } from "@/lib/types";

export default function Report() {
  const { shift, dataset, loading, asOf } = useApp();
  const report = useReport(shift, asOf);
  const priorities = usePriorities(shift, dataset, asOf);
  const [hand, setHand] = useState<Handoff | null>(null);

  useEffect(() => {
    if (!dataset) return;
    getHandoff(dataset, asOf ?? undefined).then(setHand).catch(() => setHand(null));
  }, [dataset, asOf]);

  if (loading || !dataset) return <PageSkeleton cards={2} />;

  const checkFirst = (
    <section className="space-y-3">
      <div>
        <h2 className="text-2xl font-semibold">Check these first next shift</h2>
        <p className="text-base text-zinc-500">
          {shift ? `From the ${formatDate(shift.date)} night shift` : "From the sensors"} plus problems still in progress. These are checks for a person to make. Dismissed flags are left out.
        </p>
      </div>
      {priorities ? <PriorityList key={flagSignature(shift) ?? dataset} initial={priorities} /> : <div className="h-32 animate-pulse rounded-xl bg-zinc-900" />}
    </section>
  );

  const handoffBlock = hand && (
    <section className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <h2 className="text-2xl font-semibold">Summary: {hand.headline}</h2>
      <p className="mb-3 text-sm text-zinc-500">
        As of {formatDateTime(hand.as_of)}
        {hand.agent_engine ? ` · triage agent engine: ${hand.agent_engine === "nemotron" ? "Nemotron (live model)" : "offline script (no model)"}` : ""}
      </p>
      <ul className="space-y-1.5 text-lg text-zinc-200">
        {hand.lines.map((l, i) => <li key={i}>{l}</li>)}
      </ul>
    </section>
  );

  // No phone upload for this dataset yet: still show everything the sensors know.
  if (!shift || !report)
    return (
      <div className="space-y-8">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <h1 className="text-3xl font-bold">Handover</h1>
          <div className="no-print flex gap-3">
            <a href={eventsUrl(dataset)} className="rounded-lg border border-zinc-700 px-5 py-2.5 text-base font-semibold text-zinc-200 hover:bg-zinc-800">Export events.json</a>
            <button onClick={() => window.print()} className="btn-primary px-5 py-2.5 text-base font-semibold">Print</button>
          </div>
        </div>
        <p className="rounded-xl border border-dashed border-zinc-800 p-6 text-lg text-zinc-400">
          {asOf !== null ? "No shift had started yet at this time." : "No phone report for this dataset yet."} When the operator ends a shift on the phone, their flags, notes and route appear here.
        </p>
        {handoffBlock}
        {checkFirst}
      </div>
    );

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold">Handover: {formatDate(report.shift.date)} night</h1>
          <p className="mt-1 text-lg text-zinc-400">
            Operator {report.shift.operator} · {formatDateTime(report.shift.started_at)} to {formatDateTime(report.shift.ended_at)} · uploaded {formatDateTime(report.shift.uploaded_at)}
          </p>
        </div>
        <div className="no-print flex gap-3">
          {dataset && (
            <a href={eventsUrl(dataset)} className="rounded-lg border border-zinc-700 px-5 py-2.5 text-base font-semibold text-zinc-200 hover:bg-zinc-800">
              Export events.json
            </a>
          )}
          <button onClick={() => window.print()} className="btn-primary px-5 py-2.5 text-base font-semibold">
            Print
          </button>
        </div>
      </div>

      {handoffBlock}

      {checkFirst}

      <div className="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-zinc-800 bg-zinc-800 lg:grid-cols-4">
        <Stat bare label="Flags" value={report.totals.total} />
        <Stat bare label="Confirmed issues" value={report.totals.confirmed} tone="text-red-400" />
        <Stat bare label="Needs review" value={report.totals.pending} tone="text-amber-400" />
        <Stat bare label="Dismissed" value={report.totals.dismissed} tone="text-zinc-400" />
      </div>

      <section className="space-y-4">
        <h2 className="text-2xl font-semibold text-red-300">Confirmed issues</h2>
        {report.confirmed.length ? report.confirmed.map((f) => <FlagCard key={f.id} flag={f} />) : <p className="text-lg text-zinc-500">The operator confirmed nothing this shift.</p>}
      </section>

      <section className="space-y-4">
        <div>
          <h2 className="text-2xl font-semibold text-amber-300">Unreviewed flags, carried to the next shift</h2>
          <p className="text-base text-zinc-500">Nobody has confirmed or dismissed these yet.</p>
        </div>
        {report.pending.length ? report.pending.map((f) => <FlagCard key={f.id} flag={f} />) : <p className="text-lg text-zinc-500">Everything was reviewed.</p>}
      </section>

      <section className="space-y-3">
        <h2 className="text-2xl font-semibold">Notes</h2>
        {report.notes.length ? (
          <ul className="divide-y divide-zinc-800 rounded-xl border border-zinc-800 bg-zinc-900">
            {report.notes.map((n, i) => (
              <li key={i} className="flex flex-wrap gap-x-4 gap-y-1 px-5 py-3 text-lg">
                <span className="w-24 shrink-0 text-zinc-500">{formatTime(n.timestamp)}</span>
                <span className="w-40 shrink-0 font-medium text-zinc-200">{n.location}</span>
                <span className={`w-32 shrink-0 ${n.author === "control" ? "text-sky-300" : "text-zinc-400"}`}>{n.author === "control" ? "Control room" : "Operator"}</span>
                <span className="text-zinc-300">{n.note.replace(/^operator:\s*/i, "")}</span>
              </li>
            ))}
          </ul>
        ) : <p className="text-lg text-zinc-500">No notes this shift.</p>}
      </section>

      <section className="space-y-3">
        <h2 className="text-2xl font-semibold">Stops checked: {report.stops_walked} of {report.stops_planned}</h2>
        {report.missed_stops.length ? (
          <>
            <p className="text-base text-zinc-500">Planned but not checked. These get priority next shift.</p>
            <ul className="flex flex-wrap gap-3">
              {report.missed_stops.map((s) => (
                <li key={s}>
                  <Link href={`/facility/${s}`} className="inline-block rounded-lg border-2 border-dashed border-amber-400/60 px-4 py-2 text-lg font-medium text-amber-200 hover:bg-amber-400/10">{facName(s)}</Link>
                </li>
              ))}
            </ul>
          </>
        ) : <p className="text-lg text-zinc-500">The operator walked the full route.</p>}
      </section>
    </div>
  );
}
