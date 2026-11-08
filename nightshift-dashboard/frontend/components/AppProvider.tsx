"use client";

// Loads the dataset list, the selected dataset's overview, danger check and uploaded shifts, and shares them
// with every page. All three refresh through one polling loop (usePoll). Two failed polls in a row = stale.

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { CONFIG_ERROR, getClock, getDatasets, getOverview, getRisk, getShifts, setClock } from "@/lib/api";
import { usePoll } from "@/lib/usePoll";
import type { DatasetInfo, Flag, Mode, Overview, Risk, RiskLevel, Shift } from "@/lib/types";

const POLL_MS = 8000;

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
  removeFlag: (id: string) => void;
  loading: boolean;
  offline: boolean; // the backend failed twice in a row (or never answered): what is on screen may be stale
  lastOk: Date | null; // when the backend last answered
  mode: Mode | null; // live or replay, as the backend reports it
  alarmId: string | null; // the danger situation on screen (null when not in danger)
  acked: boolean; // the operator acknowledged this alarm: no more motion, no top strip
  acknowledge: () => void;
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
// Flags stay visible until they are deleted, whatever time the slider shows (the phone uses its real clock).
const seenAt = (s: Shift | null): Shift | null => s;

function shiftAt(shifts: Shift[], asOf: number | null): Shift | null {
  if (asOf === null) return shifts[0] ?? null;
  const before = [...shifts].filter((s) => toUnix(s.started_at) <= asOf).sort((a, b) => toUnix(b.started_at) - toUnix(a.started_at));
  return before[0] ?? shifts[0] ?? null; // nothing before this moment (phone uploads use its real clock): the newest
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
  const [health, setHealth] = useState<{ fails: number; lastOk: Date | null }>({ fails: 0, lastOk: null });
  const report = useCallback((ok: boolean) => {
    setHealth((h) => (ok ? { fails: 0, lastOk: new Date() } : { ...h, fails: h.fails + 1 }));
  }, []);

  // The dataset comes from the backend's clock (the same one the phone uses), else the last one picked here.
  useEffect(() => {
    Promise.all([getDatasets(), getClock().catch(() => null)])
      .then(([list, clock]) => {
        setDatasets(list);
        let saved: string | null = null;
        try {
          saved = localStorage.getItem(KEY);
        } catch {}
        const pick = [clock?.dataset, saved].find((n) => n && list.some((d) => d.name === n));
        setDatasetState(pick ?? list[0]?.name ?? null);
        if (!list.length) setNoData(true);
        report(true);
      })
      .catch(() => setHealth((h) => ({ ...h, fails: Math.max(h.fails + 1, 2) })));
  }, [report]);

  const asOf = dataset ? (asOfState && asOfState.dataset === dataset ? asOfState.now : startOf(datasets, dataset)) : null;

  // Overview (facilities, alerts, map) at the chosen moment; refreshes every few seconds.
  usePoll(
    dataset && datasets.length ? `${dataset}|${asOf ?? "live"}` : null,
    async (signal) => {
      if (!dataset) return;
      const o = await getOverview(dataset, asOf ?? undefined, signal);
      setOverview(o);
      setLoadedFor(dataset);
    },
    POLL_MS,
    report,
  );

  // The danger check for the danger card, the owl and the alarm border, on every page. If one check fails,
  // the last good one stays on screen (and the stale banner says so).
  const riskKey = dataset && loadedFor === dataset ? `${dataset}|${asOf ?? "live"}|${playing ? "rules" : "ai"}` : null;
  usePoll(
    riskKey,
    async (signal) => {
      if (!dataset) return;
      const r = await getRisk(dataset, asOf ?? undefined, !playing, signal);
      setRiskState({ dataset, data: r });
    },
    POLL_MS,
    report,
  );
  const risk = riskState && riskState.dataset === dataset ? riskState.data : null;
  const riskLevel = risk ? risk.level : null;
  useEffect(() => {
    document.documentElement.dataset.alarm = riskLevel === "red" ? "red" : "";
  }, [riskLevel]);

  // The alarm moment, once per new danger situation: for ~2 s the neon sign and skyline windows tint red and the
  // danger card pulses; then the page scrolls to the danger card and the #1 plan is highlighted. Acknowledge stops it.
  const alarmId = risk?.alarm ? risk.alarm_id : null;
  const [ackedId, setAckedId] = useState<string | null>(null);
  const acked = alarmId !== null && ackedId === alarmId;
  const acknowledge = useCallback(() => setAckedId(alarmId), [alarmId]);
  useEffect(() => {
    const html = document.documentElement;
    if (!alarmId || acked) {
      delete html.dataset.burst;
      delete html.dataset.focus;
      return;
    }
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    html.dataset.burst = "1";
    const t = setTimeout(() => {
      delete html.dataset.burst;
      document.getElementById("danger-card")?.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
      html.dataset.focus = "1";
    }, reduce ? 0 : 2000);
    return () => clearTimeout(t);
  }, [alarmId, acked]);
  useEffect(() => {
    const html = document.documentElement;
    if (acked) html.dataset.acked = "1";
    else delete html.dataset.acked;
  }, [acked]);

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

  // Phone uploads and flag decisions, without a page reload.
  usePoll(
    dataset,
    async (signal) => {
      if (!dataset) return;
      const s = await getShifts(dataset, signal);
      setShifts((old) => (JSON.stringify(old) === JSON.stringify(s) ? old : s));
    },
    POLL_MS,
    report,
  );

  const setDataset = useCallback((name: string) => {
    try {
      localStorage.setItem(KEY, name);
    } catch {}
    setDatasetState(name);
  }, []);

  const offline = health.fails >= 2;
  const loading = !offline && !noData && loadedFor !== dataset;
  const mode = overview && overview.dataset === dataset ? overview.mode : null;
  const selectedId = selected && selected.dataset === dataset ? selected.id : null;

  const value = useMemo<Ctx>(
    () => ({
      datasets, dataset, setDataset, overview, asOf, setAsOf, risk, riskLevel, playing, setPlaying, shifts,
      shift: seenAt(shifts.find((s) => s.id === selectedId) ?? shiftAt(shifts, asOf)),
      select: (id: string) => dataset && setSelected({ dataset, id }),
      patchFlag: (flag) =>
        setShifts((all) => all.map((s) => ({ ...s, flags: s.flags.map((f) => (f.id === flag.id ? { ...f, ...flag } : f)) }))),
      removeFlag: (id: string) => setShifts((all) => all.map((s) => ({ ...s, flags: s.flags.filter((f) => f.id !== id) }))),
      loading, offline, lastOk: health.lastOk, mode, alarmId, acked, acknowledge,
    }),
    [datasets, dataset, setDataset, overview, asOf, setAsOf, risk, riskLevel, playing, setPlaying, shifts, selectedId, loading, offline, health.lastOk, mode, alarmId, acked, acknowledge],
  );

  if (CONFIG_ERROR)
    return (
      <div role="alert" className="flex min-h-screen items-center justify-center bg-zinc-950 p-8">
        <div className="max-w-xl border-2 border-red-500 bg-zinc-900 p-8">
          <h1 className="text-3xl font-bold text-red-300">Backend address not set</h1>
          <p className="mt-3 text-lg text-zinc-200">
            This build has no <code>NEXT_PUBLIC_API_URL</code>, so it cannot know where the NightShift backend is.
            Rebuild with it set, for example <code>NEXT_PUBLIC_API_URL=http://localhost:8000 npm run build</code>, or run{" "}
            <code>scripts/demo.sh</code>.
          </p>
        </div>
      </div>
    );
  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}
