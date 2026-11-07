"use client";

import { useEffect, useState } from "react";
import { getNextShift, getReport } from "./api";
import type { Priority, Report } from "./types";

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

export const usePriorities = (shiftId?: string) => useFetched<Priority[]>(shiftId, getNextShift);
export const useReport = (shiftId?: string) => useFetched<Report>(shiftId, getReport);
