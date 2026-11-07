"use client";

// ALERTS: every problem still in progress. Pump failures first (soonest shutdown first), then leaks and worn pumps.

import AlertCard from "@/components/AlertCard";
import { useApp } from "@/components/AppProvider";
import { formatDateTime } from "@/lib/api";

export default function Alerts() {
  const { overview } = useApp();
  if (!overview) return <div className="h-96 animate-pulse rounded-2xl bg-zinc-900" />;
  const alerts = overview.alerts;
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-4xl font-bold">Alerts</h1>
        <p className="mt-1 text-lg text-zinc-400">
          Problems in progress as of {formatDateTime(overview.now_ts)}. Pump failures first, soonest shutdown first (ties go to higher lost revenue), then leaks and worn pumps.
        </p>
      </div>
      {alerts.length === 0 ? (
        <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-lg text-zinc-500">No problems in progress. Normal round.</div>
      ) : (
        <div className="space-y-4">{alerts.map((a) => <AlertCard key={a.event_id} a={a} />)}</div>
      )}
      <p className="text-base text-zinc-500">Plans are suggestions for a person to approve. Nothing here operates equipment.</p>
    </div>
  );
}
