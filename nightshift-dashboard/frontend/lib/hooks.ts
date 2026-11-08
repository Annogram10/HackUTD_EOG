"use client";

import { useEffect, useState } from "react";
import { getNextShift, getReport } from "./api";
import type { Priority, Report, Shift } from "./types";

// Refetch whenever the shift changes OR any of its flags change (new upload, new decision).
const keyOf = (s?: Shift | null) => (s ? `${s.id}|${s.flags.map((f) => `${f.id}:${f.status}`).join(",")}` : undefined);

// Fetches once per key. `data` is null while loading (or if the request failed).
function useFetched<T>(key: string | undefined, load: (k: string) => Promise<T>) {
  const [state, setState] = useState<{ key: string; data: T | null } | null>(null);
  useEffect(() => {
    if (!key) return;
    let alive = true;
    load(key).then((data) => alive && setState({ key, data })).catch(() => alive && setState({ key, data: null }));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return state && state.key === key ? state.data : null;
}

// Works with or without an uploaded shift (with none, priorities come from the sensors alone) and follows the replay time.
export const usePriorities = (shift: Shift | null | undefined, dataset: string | null | undefined, asOf: number | null = null) =>
  useFetched<Priority[]>(dataset ? `${dataset}|${asOf ?? "live"}|${keyOf(shift) ?? ""}` : undefined, (k) => {
    const [ds, at, rest] = [k.split("|")[0], k.split("|")[1], k.split("|")[2]];
    return getNextShift(rest || undefined, ds, at === "live" ? undefined : Number(at));
  });
export const useReport = (shift?: Shift | null, asOf: number | null = null) =>
  useFetched<Report>(keyOf(shift), (k) => getReport(k.split("|")[0], asOf ?? undefined));
export const flagSignature = keyOf;
