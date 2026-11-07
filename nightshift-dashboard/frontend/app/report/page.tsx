"use client";

// SHIFT REPORT: "End shift" pulls the summary from the backend.

import { useState } from "react";
import FlagCard from "@/components/FlagCard";
import SourceTag from "@/components/SourceTag";
import Stat from "@/components/Stat";
import { formatTime, getReport } from "@/lib/api";
import type { Report } from "@/lib/types";

export default function ShiftReport() {
  const [report, setReport] = useState<Report | null>(null);
  const [live, setLive] = useState(false);
  const [loading, setLoading] = useState(false);

  async function endShift() {
    setLoading(true);
    const res = await getReport();
    setReport(res.data);
    setLive(res.live);
    setLoading(false);
  }

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold">Shift report</h1>
          <p className="mt-1 text-zinc-400">Written automatically from tonight&apos;s flags and voice notes</p>
        </div>
        <div className="no-print flex items-center gap-4">
          {report && <SourceTag live={live} />}
          {report && (
            <button
              onClick={() => window.print()}
              className="rounded-lg border border-zinc-700 px-4 py-2 text-sm font-medium text-zinc-300 hover:bg-zinc-800"
            >
              Print
            </button>
          )}
          <button
            onClick={endShift}
            disabled={loading}
            className="rounded-lg bg-amber-400 px-5 py-2.5 text-sm font-semibold text-zinc-950 hover:bg-amber-300 disabled:opacity-50"
          >
            {loading ? "Generating..." : report ? "Refresh report" : "End shift"}
          </button>
        </div>
      </div>

      {!report ? (
        <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-zinc-500">
          Hit <span className="font-semibold text-zinc-300">End shift</span> to generate tonight&apos;s report.
        </div>
      ) : (
        <>
          <p className="text-sm text-zinc-500">
            Shift started {formatTime(report.shift_start)} · generated {formatTime(report.generated_at)}
          </p>

          <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <Stat label="Total flags" value={report.totals.total} />
            <Stat label="Confirmed" value={report.totals.confirmed} tone="text-red-400" />
            <Stat label="Unreviewed" value={report.totals.pending} tone="text-amber-400" />
            <Stat label="Dismissed" value={report.totals.dismissed} tone="text-zinc-400" />
          </div>

          <div className="flex flex-wrap gap-3">
            {Object.entries(report.by_type).map(([type, n]) => (
              <span key={type} className="rounded-lg bg-zinc-900 px-3 py-1.5 text-sm text-zinc-300">
                {n} {type}
              </span>
            ))}
          </div>

          <section className="space-y-4">
            <h2 className="text-xl font-semibold text-red-300">Confirmed issues</h2>
            {report.confirmed.length ? (
              report.confirmed.map((f) => <FlagCard key={f.id} flag={f} />)
            ) : (
              <p className="text-zinc-500">Nothing confirmed tonight.</p>
            )}
          </section>

          <section className="space-y-4">
            <h2 className="text-xl font-semibold text-amber-300">Unreviewed, carried to next shift</h2>
            {report.pending.length ? (
              report.pending.map((f) => <FlagCard key={f.id} flag={f} />)
            ) : (
              <p className="text-zinc-500">Everything was reviewed.</p>
            )}
          </section>

          <section className="space-y-3">
            <h2 className="text-xl font-semibold">Operator notes</h2>
            {report.notes.length ? (
              <ul className="divide-y divide-zinc-800 rounded-xl border border-zinc-800 bg-zinc-900">
                {report.notes.map((n, i) => (
                  <li key={i} className="flex gap-4 px-5 py-3">
                    <span className="w-20 shrink-0 text-sm text-zinc-500">{formatTime(n.timestamp)}</span>
                    <span className="w-36 shrink-0 font-medium text-zinc-200">{n.location}</span>
                    <span className="text-zinc-300">{n.note}</span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-zinc-500">No voice notes tonight.</p>
            )}
          </section>
        </>
      )}
    </div>
  );
}
