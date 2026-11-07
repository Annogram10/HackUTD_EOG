"use client";

// NEXT SHIFT: ranked to-do list and route, with the reasons for each stop.
// The supervisor can reorder or bump an item to the top (kept in local state for the demo).

import Link from "next/link";
import { useState } from "react";
import { LevelBadge } from "@/components/Badges";
import { useApp } from "@/components/AppProvider";
import { formatDate } from "@/lib/api";
import { usePriorities } from "@/lib/hooks";
import type { Priority, PriorityLevel } from "@/lib/types";

const BORDER: Record<PriorityLevel, string> = {
  high: "border-l-red-500",
  medium: "border-l-amber-400",
  low: "border-l-zinc-600",
};

function Btn({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button
      {...props}
      className="rounded-lg border border-zinc-700 px-3 py-1.5 text-base text-zinc-300 hover:bg-zinc-800 disabled:cursor-not-allowed disabled:opacity-30"
    >
      {children}
    </button>
  );
}

function List({ initial }: { initial: Priority[] }) {
  const [items, setItems] = useState(initial);
  const [edited, setEdited] = useState(false);

  const change = (next: Priority[]) => {
    setItems(next);
    setEdited(true);
  };
  const move = (i: number, by: number) => {
    const next = [...items];
    [next[i], next[i + by]] = [next[i + by], next[i]];
    change(next);
  };
  const bump = (i: number) => change([items[i], ...items.filter((_, j) => j !== i)]);

  if (items.length === 0) {
    return (
      <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-lg text-zinc-500">
        Nothing flagged. Normal route next shift.
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {edited && (
        <div className="no-print flex items-center gap-4 rounded-lg bg-sky-500/10 px-4 py-2 text-base text-sky-200">
          Order changed by the supervisor (demo only, not saved).
          <button
            onClick={() => {
              setItems(initial);
              setEdited(false);
            }}
            className="font-semibold underline"
          >
            Reset to suggested order
          </button>
        </div>
      )}
      <ol className="space-y-4">
        {items.map((p, i) => (
          <li
            key={p.equipment_id}
            className={`flex gap-5 rounded-xl border border-l-4 border-zinc-800 bg-zinc-900 p-5 ${BORDER[p.level]}`}
          >
            <span className="w-10 shrink-0 text-4xl font-bold tabular-nums text-zinc-500">{i + 1}</span>
            <div className="min-w-0 flex-1 space-y-2">
              <div className="flex flex-wrap items-center gap-3">
                <h3 className="text-2xl font-semibold text-zinc-100">
                  <Link href={`/facility/${p.equipment_id}`} className="hover:text-amber-300 hover:underline">
                    {p.location}
                  </Link>
                </h3>
                <LevelBadge level={p.level} />
                <span className="text-base tabular-nums text-zinc-500">score {p.score}</span>
              </div>
              <ul className="space-y-1">
                {p.reasons.map((r) => (
                  <li key={r} className="text-lg text-zinc-300">
                    <span className="mr-2 text-zinc-600">•</span>
                    {r}
                  </li>
                ))}
              </ul>
            </div>
            <div className="no-print flex shrink-0 flex-col items-stretch gap-2">
              <Btn onClick={() => bump(i)} disabled={i === 0}>⤒ Bump to top</Btn>
              <div className="flex gap-2">
                <Btn onClick={() => move(i, -1)} disabled={i === 0} aria-label="Move up">▲</Btn>
                <Btn onClick={() => move(i, 1)} disabled={i === items.length - 1} aria-label="Move down">▼</Btn>
              </div>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}

export default function NextShift() {
  const { shift } = useApp();
  const items = usePriorities(shift?.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-4xl font-bold">Next shift: what to check first</h1>
        <p className="mt-1 text-lg text-zinc-400">
          {shift ? `Based on the ${formatDate(shift.date)} night shift and the 7 nights before it. ` : ""}
          Suggested checks, not instructions. Dismissed flags are ignored.
        </p>
        <p className="mt-2 text-base text-zinc-500">
          Score: +50 confirmed flag · +25 unreviewed flag · +30/+20/+10 worst type (smoke/leak/damage) · +10 per previous
          night flagged · +15 stop missed · +60/+40/+20 sensor problem in progress (pump failure/leak/worn pump). High 60+, medium 30+.
        </p>
      </div>

      {shift && items ? (
        <List key={shift.id} initial={items} />
      ) : (
        <div className="space-y-4">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-32 animate-pulse rounded-xl bg-zinc-900" />
          ))}
        </div>
      )}
    </div>
  );
}
