"use client";

// The red strip across the top while a new danger is unacknowledged: "// ALERT · S1 Facility C · SHUTDOWN IN 4.1H".
// Acknowledge (on the danger card or here) removes it. Facility and hours come from the loaded data.

import { facName } from "@/lib/api";
import { useApp } from "./AppProvider";

export default function AlarmStrip() {
  const { risk, overview, acked, acknowledge } = useApp();
  if (!risk?.alarm || acked) return null;
  const fid = risk.reasons.find((r) => r.level === "red")?.facility_id;
  const a = overview?.alerts.find((x) => x.facility_id === fid && x.category === "pump_failure");
  const when = a?.tripped ? "TANK AT SHUTDOWN" : a?.hours_to_limit ? `SHUTDOWN IN ${a.hours_to_limit.p50.toFixed(1)}H` : "";
  return (
    <div role="alert" className="no-print sticky top-0 z-50 flex flex-wrap items-center justify-center gap-x-4 gap-y-1 bg-red-500 px-4 py-2 font-mono text-sm font-bold uppercase tracking-wider text-zinc-950">
      <span>{["// ALERT", fid ? facName(fid) : null, when].filter(Boolean).join(" · ")}</span>
      <button type="button" onClick={acknowledge} className="border border-zinc-950 px-3 py-0.5 text-sm font-bold uppercase hover:bg-zinc-950/10">
        Acknowledge
      </button>
    </div>
  );
}
