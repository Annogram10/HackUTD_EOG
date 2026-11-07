"use client";

import Link from "next/link";
import { LevelBadge } from "@/components/Badges";
import type { Priority, PriorityLevel } from "@/lib/types";

const BORDER: Record<PriorityLevel, string> = { high: "border-t-red-500", medium: "border-t-amber-400", low: "border-t-zinc-600" };

export default function RiskBrief({ items }: { items: Priority[] | null }) {
  return (
    <section>
      <div className="mb-3 flex items-baseline justify-between">
        <h2 className="text-2xl font-semibold">Risk brief: top 3 to watch</h2>
        <Link href="/next-shift" className="text-base text-sky-300 hover:text-sky-200">Full next-shift list →</Link>
      </div>
      {items === null ? (
        <div className="grid gap-4 md:grid-cols-3">{[0, 1, 2].map((i) => <div key={i} className="h-40 animate-pulse rounded-xl bg-zinc-900" />)}</div>
      ) : items.length === 0 ? (
        <p className="rounded-xl border border-dashed border-zinc-800 p-6 text-lg text-zinc-500">Nothing stands out. Normal route.</p>
      ) : (
        <div className="grid gap-4 md:grid-cols-3">
          {items.slice(0, 3).map((p, i) => (
            <Link key={p.equipment_id} href={`/facility/${p.equipment_id}`}
              className={`rounded-xl border border-t-4 border-zinc-800 bg-zinc-900 p-5 transition-colors hover:bg-zinc-800/70 ${BORDER[p.level]}`}>
              <div className="flex items-center gap-3">
                <span className="text-3xl font-bold tabular-nums text-zinc-500">{i + 1}</span>
                <h3 className="text-xl font-semibold text-zinc-100">{p.location}</h3>
                <LevelBadge level={p.level} />
              </div>
              <ul className="mt-3 space-y-1 text-base text-zinc-300">
                {p.reasons.slice(0, 2).map((r) => (
                  <li key={r}><span className="mr-2 text-zinc-600">•</span>{r}</li>
                ))}
              </ul>
            </Link>
          ))}
        </div>
      )}
    </section>
  );
}
