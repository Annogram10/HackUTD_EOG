"use client";

// LIVE SHIFT: polls the backend every 2 sec, newest flags on top,
// new ones flash amber for 3 sec.

import { useEffect, useRef, useState } from "react";
import FlagCard from "@/components/FlagCard";
import SourceTag from "@/components/SourceTag";
import Stat from "@/components/Stat";
import { getFlags } from "@/lib/api";
import type { Flag } from "@/lib/types";

const POLL_MS = 2000;

export default function LiveShift() {
  const [flags, setFlags] = useState<Flag[]>([]);
  const [live, setLive] = useState(false);
  const [loading, setLoading] = useState(true);
  const [newIds, setNewIds] = useState<Set<string>>(new Set());
  const seen = useRef<Set<string> | null>(null);

  useEffect(() => {
    let alive = true;

    async function load() {
      const res = await getFlags();
      if (!alive) return;

      const sorted = [...res.data].sort(
        (a, b) => new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime(),
      );

      // Anything we haven't seen before (after the first load) counts as new
      if (seen.current) {
        const fresh = sorted.filter((f) => !seen.current!.has(f.id)).map((f) => f.id);
        if (fresh.length) {
          setNewIds((prev) => new Set([...prev, ...fresh]));
          setTimeout(() => {
            setNewIds((prev) => {
              const next = new Set(prev);
              fresh.forEach((id) => next.delete(id));
              return next;
            });
          }, 3000);
        }
      }
      seen.current = new Set(sorted.map((f) => f.id));

      setFlags(sorted);
      setLive(res.live);
      setLoading(false);
    }

    load();
    const timer = setInterval(load, POLL_MS);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, []);

  const confirmed = flags.filter((f) => f.status === "confirmed").length;
  const pending = flags.filter((f) => f.status === "pending").length;

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-3xl font-bold">Live shift</h1>
          <p className="mt-1 text-zinc-400">Flags spotted by the operator&apos;s glasses, newest first</p>
        </div>
        <SourceTag live={live} />
      </div>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Stat label="Flags tonight" value={flags.length} />
        <Stat label="Confirmed" value={confirmed} tone="text-red-400" />
        <Stat label="Awaiting review" value={pending} tone="text-amber-400" />
      </div>

      {loading ? (
        <div className="space-y-4">
          {[0, 1, 2].map((i) => (
            <div key={i} className="h-36 animate-pulse rounded-xl bg-zinc-900" />
          ))}
        </div>
      ) : flags.length === 0 ? (
        <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-zinc-500">
          No flags yet tonight. They&apos;ll show up here the moment the glasses spot something.
        </div>
      ) : (
        <div className="space-y-4">
          {flags.map((f) => (
            <FlagCard key={f.id} flag={f} isNew={newIds.has(f.id)} />
          ))}
        </div>
      )}
    </div>
  );
}
