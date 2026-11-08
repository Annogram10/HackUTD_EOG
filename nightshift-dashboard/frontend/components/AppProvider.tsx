"use client";

// Loads the dataset list, the selected dataset's overview and its uploaded shifts, and shares them
// with every page. Nothing is live: this fetches on load and whenever the dataset changes.

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { getDatasets, getOverview, getRisk, getShifts, setClock } from "@/lib/api";
import type { DatasetInfo, Flag, Overview, Risk, RiskLevel, Shift } from "@/lib/types";

interface Ctx {
  datasets: DatasetInfo[];
  dataset: string | null;
  setDataset: (name: string) => void;
  overview: Overview | null;
  asOf: number | null; // time travel: unix seconds. A dataset opens at its start; null = the latest reading
  setAsOf: (t: number | null, followPhone?: boolean) => void;
  risk: Risk | null; // last good danger check for this dataset (kept while the next one loads)
  riskLevel: RiskLevel | null; // how the shift is going at the chosen time (drives the owl and the alarm border)
  playing: boolean; // time travel is playing (the AI check waits until it pauses)
  setPlaying: (v: boolean) => void;
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

// A dataset opens at its start, like a shift beginning. This matches the first moment of the time-travel bar
// (the first reading plus 6 hours, because detection needs some history before it can judge).
const START_OFFSET_S = 6 * 3600;
const startOf = (datasets: DatasetInfo[], name: string | null) => {
  const d = datasets.find((x) => x.name === name);
  return d ? Math.floor(Date.parse(d.first_ts) / 1000) + START_OFFSET_S : null;
};

const toUnix = (iso: string) => Date.parse(/[zZ]|[+-]\d\d:?\d\d$/.test(iso) ? iso : `${iso}Z`) / 1000;

// Which shift to show: the newest at the latest data; during a replay, the shift in progress at that moment
// (or the last one that started before it). Nothing from a shift that has not started yet.
// In a replay a flag does not exist before its own time: hide the ones from later than the moment on screen.
function seenAt(s: Shift | null, asOf: number | null): Shift | null {
  if (!s || asOf === null) return s;
  return { ...s, flags: s.flags.filter((f) => toUnix(f.timestamp) <= asOf) };
}

function shiftAt(shifts: Shift[], asOf: number | null): Shift | null {
  if (asOf === null) return shifts[0] ?? null;
  return [...shifts].filter((s) => toUnix(s.started_at) <= asOf).sort((a, b) => toUnix(b.started_at) - toUnix(a.started_at))[0] ?? null;
}

export default function AppProvider({ children }: { children: React.ReactNode }) {
  const [datasets, setDatasets] = useState<DatasetInfo[]>([]);
  const [dataset, setDatasetState] = useState<string | null>(null);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [shifts, setShifts] = useState<Shift[]>([]);
  const [selected, setSelected] = useState<{ dataset: string; id: string } | null>(null);
  const [loadedFor, setLoadedFor] = useState<string | null>(null);
  const [asOfState, setAsOfState] = useState<{ dataset: string; now: number | null } | null>(null); // now null = latest
  const [playing, setPlaying] = useState(false);
  const [riskState, setRiskState] = useState<{ dataset: string; data: Risk } | null>(null);
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

  const asOf = dataset ? (asOfState && asOfState.dataset === dataset ? asOfState.now : startOf(datasets, dataset)) : null;

  useEffect(() => {
    if (!dataset) return;
    let alive = true;
    Promise.all([getOverview(dataset, startOf(datasets, dataset) ?? undefined), getShifts(dataset)])
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
  }, [dataset, datasets]);

  // Time travel: reload the overview as of the chosen moment.
  useEffect(() => {
    if (!dataset || loadedFor !== dataset) return;
    let alive = true;
    getOverview(dataset, asOf ?? undefined)
      .then((o) => alive && setOverview(o))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [dataset, asOf, loadedFor]);

  // The danger check for the danger card, the owl and the alarm border, on every page. If one check fails,
  // the last good one stays on screen.
  const riskKey = dataset ? `${dataset}|${asOf ?? "live"}|${playing ? "rules" : "ai"}` : null;
  useEffect(() => {
    if (!dataset || !riskKey || loadedFor !== dataset) return;
    let alive = true;
    getRisk(dataset, asOf ?? undefined, !playing)
      .then((r) => alive && setRiskState({ dataset, data: r }))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [dataset, asOf, playing, riskKey, loadedFor]);
  const risk = riskState && riskState.dataset === dataset ? riskState.data : null;
  const riskLevel = risk ? risk.level : null;
  useEffect(() => {
    document.documentElement.dataset.alarm = riskLevel === "red" ? "red" : "";
  }, [riskLevel]);

  // The phone and glasses start at the same moment the dashboard opens on.
  const clockSet = asOfState !== null && asOfState.dataset === dataset;
  useEffect(() => {
    if (!dataset || loadedFor !== dataset || clockSet) return;
    const t = startOf(datasets, dataset);
    if (t !== null) setClock(dataset, t);
  }, [dataset, loadedFor, clockSet, datasets]);

  const setAsOf = useCallback(
    (t: number | null, followPhone = true) => {
      if (!dataset) return;
      setAsOfState({ dataset, now: t });
      setSelected(null); // the shift follows the replay time again
      setClock(dataset, followPhone ? t : null);
    },
    [dataset],
  );

  // Pick up new phone uploads and flag decisions without a page reload.
  useEffect(() => {
    if (!dataset) return;
    const id = setInterval(() => {
      getShifts(dataset)
        .then((s) => setShifts((old) => (JSON.stringify(old) === JSON.stringify(s) ? old : s)))
        .catch(() => {});
    }, 8000);
    return () => clearInterval(id);
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
      datasets, dataset, setDataset, overview, asOf, setAsOf, risk, riskLevel, playing, setPlaying, shifts,
      shift: seenAt(shifts.find((s) => s.id === selectedId) ?? shiftAt(shifts, asOf), asOf),
      select: (id: string) => dataset && setSelected({ dataset, id }),
      patchFlag: (flag) =>
        setShifts((all) => all.map((s) => ({ ...s, flags: s.flags.map((f) => (f.id === flag.id ? { ...f, ...flag } : f)) }))),
      loading, offline,
    }),
    [datasets, dataset, setDataset, overview, asOf, setAsOf, risk, riskLevel, playing, setPlaying, shifts, selectedId, loading, offline],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}
