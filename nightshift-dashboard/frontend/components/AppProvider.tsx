"use client";

// Loads the dataset list, the selected dataset's overview and its uploaded shifts, and shares them
// with every page. Nothing is live: this fetches on load and whenever the dataset changes.

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { getDatasets, getOverview, getShifts } from "@/lib/api";
import type { DatasetInfo, Flag, Overview, Shift } from "@/lib/types";

interface Ctx {
  datasets: DatasetInfo[];
  dataset: string | null;
  setDataset: (name: string) => void;
  overview: Overview | null;
  shifts: Shift[];
  shift: Shift | null; // selected shift (default: newest)
  select: (id: string) => void;
  patchFlag: (flag: Flag) => void;
  loading: boolean;
  offline: boolean;
}

const AppContext = createContext<Ctx | null>(null);

export function useApp(): Ctx {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error("useApp must be used inside <AppProvider>");
  return ctx;
}

const KEY = "nightshift.dataset";

export default function AppProvider({ children }: { children: React.ReactNode }) {
  const [datasets, setDatasets] = useState<DatasetInfo[]>([]);
  const [dataset, setDatasetState] = useState<string | null>(null);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [shifts, setShifts] = useState<Shift[]>([]);
  const [selected, setSelected] = useState<{ dataset: string; id: string } | null>(null);
  const [loadedFor, setLoadedFor] = useState<string | null>(null);
  const [noData, setNoData] = useState(false);
  const [offline, setOffline] = useState(false);

  useEffect(() => {
    getDatasets()
      .then((list) => {
        setDatasets(list);
        let saved: string | null = null;
        try {
          saved = localStorage.getItem(KEY);
        } catch {}
        setDatasetState(list.find((d) => d.name === saved)?.name ?? list[0]?.name ?? null);
        if (!list.length) setNoData(true);
      })
      .catch(() => setOffline(true));
  }, []);

  useEffect(() => {
    if (!dataset) return;
    let alive = true;
    Promise.all([getOverview(dataset), getShifts(dataset)])
      .then(([o, s]) => {
        if (!alive) return;
        setOverview(o);
        setShifts(s);
        setOffline(false);
        setLoadedFor(dataset);
      })
      .catch(() => alive && setOffline(true));
    return () => {
      alive = false;
    };
  }, [dataset]);

  const setDataset = useCallback((name: string) => {
    try {
      localStorage.setItem(KEY, name);
    } catch {}
    setDatasetState(name);
  }, []);

  const loading = !offline && !noData && loadedFor !== dataset;
  const selectedId = selected && selected.dataset === dataset ? selected.id : null;

  const value = useMemo<Ctx>(
    () => ({
      datasets, dataset, setDataset, overview, shifts,
      shift: shifts.find((s) => s.id === selectedId) ?? shifts[0] ?? null,
      select: (id: string) => dataset && setSelected({ dataset, id }),
      patchFlag: (flag) =>
        setShifts((all) => all.map((s) => ({ ...s, flags: s.flags.map((f) => (f.id === flag.id ? { ...f, ...flag } : f)) }))),
      loading, offline,
    }),
    [datasets, dataset, setDataset, overview, shifts, selectedId, loading, offline],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}
