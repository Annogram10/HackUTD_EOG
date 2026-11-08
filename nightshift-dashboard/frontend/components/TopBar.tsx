"use client";

// Under the nav on every page, always visible: LIVE / REPLAY (from the backend), the stale-data banner, dataset.

import { formatDate, formatDateTime } from "@/lib/api";
import AlarmStrip from "./AlarmStrip";
import { useApp } from "./AppProvider";

export default function TopBar() {
  const { datasets, dataset, setDataset, overview, mode, playing, shifts, shift, offline, lastOk, loading } = useApp();
  const replay = mode === "replay";

  return (
    <div className="no-print sticky top-0 z-40">
      {/* the alarm strip shares this sticky block, so it stacks above the bar instead of covering it */}
      <AlarmStrip />
      {offline && (
        <div role="alert" className="border-b border-red-700 bg-red-950 px-6 py-3 text-base font-semibold text-red-100">
          Backend unreachable. Data may be stale
          {lastOk ? ` (last update ${lastOk.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })})` : " (no data received yet)"}.
          <span className="ml-2 font-normal text-red-200">
            Start it with <code className="bg-zinc-900 px-2 py-0.5">scripts/demo.sh</code> or{" "}
            <code className="bg-zinc-900 px-2 py-0.5">uvicorn main:app --host 0.0.0.0 --port 8000</code> in backend/.
          </span>
        </div>
      )}
      <div className="border-b border-zinc-800 bg-zinc-900">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-6 gap-y-2 px-6 py-3">
          {/* LIVE / REPLAY, as the backend reports it (the phone and glasses see the same moment) */}
          {mode && overview && (
            <p className="flex items-center gap-3 text-base" aria-live="polite">
              {replay ? (
                <span className="flex items-center gap-1 bg-[#A83C47] px-3 py-1 text-base font-bold uppercase tracking-[0.08em] text-zinc-100">
                  {"// "}{playing ? "Replaying" : "Replay mode"}
                  <span aria-hidden className="blink-cursor">▌</span>
                </span>
              ) : (
                <span className="flex items-center gap-2 bg-emerald-500/15 px-3 py-1 text-base font-bold uppercase tracking-wide text-emerald-300 ring-1 ring-emerald-400/60">
                  <span aria-hidden className="h-2.5 w-2.5 rounded-full bg-emerald-400" />
                  <span className="text-base tracking-[0.08em]">LIVE</span>
                </span>
              )}
              <span className="font-semibold text-zinc-100">
                {replay ? "Showing " : "Latest reading "}
                {formatDateTime(overview.as_of)}
              </span>
            </p>
          )}
          <label className="flex items-center gap-3">
            <span className="text-sm uppercase tracking-wide text-zinc-500">Data</span>
            <select
              value={dataset ?? ""}
              onChange={(e) => setDataset(e.target.value)}
              className="border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-base font-semibold text-zinc-100"
            >
              {datasets.map((d) => (
                <option key={d.name} value={d.name}>
                  {d.name}
                </option>
              ))}
            </select>
          </label>
          {shift && (
            <p className="text-base text-zinc-400">
              Showing <span className="font-semibold text-zinc-200">{formatDate(shift.date)} night</span> from the phone
            </p>
          )}
          {dataset && shifts.length === 0 && !offline && <p className="text-sm text-zinc-500">No phone report for this data yet</p>}
          {loading && <span className="text-sm text-zinc-500">Loading…</span>}
          {/* the owl's home: a reserved spot, so the owl never sits on top of page content */}
          <div id="owl-home" aria-hidden className="ml-auto h-16 w-40 shrink-0" />
        </div>
        {/* the owl's bubble at home appears here, in the layout (it pushes content down, never covers it) */}
        <div id="owl-home-bubble" className="mx-auto flex max-w-7xl justify-end px-6 empty:hidden" />
      </div>
    </div>
  );
}
