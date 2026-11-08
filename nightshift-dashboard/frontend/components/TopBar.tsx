"use client";

// Under the nav on every page: dataset switcher, "now" for that dataset, shift picker.

import { formatDate, formatDateTime } from "@/lib/api";
import { useApp } from "./AppProvider";

export default function TopBar() {
  const { datasets, dataset, setDataset, overview, asOf, playing, shifts, shift, offline, loading } = useApp();

  if (offline)
    return (
      <div className="no-print border-b border-red-900 bg-red-950/40 px-6 py-3 text-base text-red-200">
        Can&apos;t reach the backend. Start it with{" "}
        <code className="rounded bg-zinc-900 px-2 py-0.5">uvicorn main:app --host 0.0.0.0 --port 8000</code> from the backend folder.
      </div>
    );

  return (
    <div className="no-print border-b border-zinc-800 bg-zinc-900/40">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-6 gap-y-2 px-6 py-3">
        <label className="flex items-center gap-3">
          <span className="text-sm uppercase tracking-wide text-zinc-500">Data</span>
          <select
            value={dataset ?? ""}
            onChange={(e) => setDataset(e.target.value)}
            className="rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-base font-semibold text-zinc-100"
          >
            {datasets.map((d) => (
              <option key={d.name} value={d.name}>
                {d.name}
              </option>
            ))}
          </select>
        </label>
        {overview && (
          <p className="flex items-center gap-2 text-base text-zinc-300">
            {asOf === null ? (
              <span className="flex items-center gap-2 bg-emerald-500/15 px-2.5 py-0.5 text-sm font-semibold text-emerald-300 ring-1 ring-emerald-400/50">
                <span className="h-2 w-2 rounded-full bg-emerald-400" />
                Live
              </span>
            ) : (
              <span className="flex items-center gap-2 bg-zinc-800 px-2.5 py-0.5 text-sm font-semibold text-zinc-200 ring-1 ring-zinc-500">
                <span className="h-2 w-2 rounded-full bg-zinc-300" />
                {playing ? "Replaying" : "Replay"}
              </span>
            )}
            <span className="font-semibold">{formatDateTime(overview.now_ts)}</span>
          </p>
        )}
        {shift && (
          <p className="text-base text-zinc-400">
            Showing <span className="font-semibold text-zinc-200">{formatDate(shift.date)} night</span> from the phone
          </p>
        )}
        {shifts.length === 0 && <p className="text-sm text-zinc-500">No phone report for this data yet</p>}
        {loading && <span className="ml-auto text-sm text-zinc-500">Loading…</span>}
      </div>
    </div>
  );
}
