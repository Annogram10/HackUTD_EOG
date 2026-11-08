"use client";

// Ranked "check these first" list. A supervisor can reorder it (kept on screen only).

import Link from "next/link";
import { useState } from "react";
import type { Priority } from "@/lib/types";
import { LevelBadge } from "./Badges";

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

const isFacility = (id: string) => /^S\d+_FACILITY_/i.test(id);

export default function PriorityList({ initial }: { initial: Priority[] }) {
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
      <div className="rounded-xl border border-dashed border-zinc-800 p-10 text-center text-lg text-zinc-500">
        Nothing stands out. Normal route next shift.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {edited && (
        <div className="no-print flex flex-wrap items-center gap-4 rounded-lg bg-sky-500/10 px-4 py-2 text-base text-sky-200">
          Order changed (on screen only).
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
      <ol className="divide-y divide-zinc-800 overflow-hidden rounded-xl border border-zinc-800 bg-zinc-900">
        {items.map((p, i) => (
          <li key={p.equipment_id} className="flex gap-4 p-4">
            <span className="w-8 shrink-0 text-3xl font-bold tabular-nums text-zinc-500">{i + 1}</span>
            <div className="min-w-0 flex-1 space-y-1.5">
              <div className="flex flex-wrap items-center gap-3">
                <h3 className="text-xl font-semibold text-zinc-100">
                  {isFacility(p.equipment_id) ? (
                    <Link href={`/facility/${p.equipment_id}`} className="hover:text-amber-300 hover:underline">
                      {p.location}
                    </Link>
                  ) : (
                    p.location
                  )}
                </h3>
                <LevelBadge level={p.level} />
              </div>
              <ul className="space-y-0.5">
                {p.reasons.map((r) => (
                  <li key={r} className="text-base text-zinc-300">
                    <span className="mr-2 text-zinc-500">•</span>
                    {r}
                  </li>
                ))}
              </ul>
            </div>
            <div className="no-print flex shrink-0 flex-col items-stretch gap-2">
              <Btn onClick={() => bump(i)} disabled={i === 0}>Top</Btn>
              <div className="flex gap-2">
                <Btn onClick={() => move(i, -1)} disabled={i === 0} aria-label="Move up">Up</Btn>
                <Btn onClick={() => move(i, 1)} disabled={i === items.length - 1} aria-label="Move down">Down</Btn>
              </div>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}
