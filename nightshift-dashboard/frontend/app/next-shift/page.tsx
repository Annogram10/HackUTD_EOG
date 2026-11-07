"use client";

// NEXT SHIFT PRIORITIES: ranked list of what to check first, with the reasons.

import { useEffect, useState } from "react";
import { LevelBadge } from "@/components/Badges";
import SourceTag from "@/components/SourceTag";
import { formatDate, formatTime } from "@/lib/api";
import { getNextShift } from "@/lib/api";
import type { Priority, PriorityLevel } from "@/lib/types";

const BORDER: Record<PriorityLevel, string> = {
  high: "border-l-red-500",
  medium: "border-l-amber-400",
  low: "border-l-zinc-600",
};

export default function NextShift() {
  const [items, setItems] = useState<Priority[]>([]);
  const [live, setLive] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getNextShift().then((res) => {
      setItems(res.data);
      setLive(res.live);
      setLoading(false);
    });
  }, []);

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold">Next shift priorities</h1>
          <p className="mt-1 text-zinc-400">Check these first, ranked by tonight&apos;s flags and past reports</p>
        </div>
        <SourceTag live={live} />
      </div>

      {loading ? (
        <div className="space-y-4">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-28 animate-pulse rounded-xl bg-zinc-900" />
          ))}
        </div>
      ) : items.length === 0 ? (
        <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-zinc-500">
          Nothing flagged. Normal route tonight.
        </div>
      ) : (
        <ol className="space-y-4">
          {items.map((p, i) => (
            <li
              key={p.location}
              className={`flex gap-5 rounded-xl border border-l-4 border-zinc-800 bg-zinc-900 p-5 ${BORDER[p.level]}`}
            >
              <span className="w-10 shrink-0 text-3xl font-bold tabular-nums text-zinc-500">{i + 1}</span>
              <div className="min-w-0 flex-1 space-y-2">
                <div className="flex flex-wrap items-center gap-3">
                  <h3 className="text-xl font-semibold text-zinc-100">{p.location}</h3>
                  <LevelBadge level={p.level} />
                  <span className="text-sm tabular-nums text-zinc-500">score {p.score}</span>
                </div>
                <ul className="space-y-1">
                  {p.reasons.map((r) => (
                    <li key={r} className="text-sm text-zinc-300">
                      <span className="mr-2 text-zinc-600">•</span>
                      {r}
                    </li>
                  ))}
                </ul>
                {p.latest_flag && (
                  <p className="text-xs text-zinc-500">
                    Last flagged {formatDate(p.latest_flag.timestamp)} at {formatTime(p.latest_flag.timestamp)}
                    {p.latest_flag.note ? `: "${p.latest_flag.note}"` : ""}
                  </p>
                )}
              </div>
            </li>
          ))}
        </ol>
      )}
    </div>
  );
}
