"use client";

// Time travel with a real play button. The data has one reading every 5 minutes, so each tick is one reading:
// the page moves forward 5 minutes of data at a time, like the data arriving live. Drag the bar to jump anywhere.
// Amber and red stretches that have already happened show on the bar. It never shows what comes next.
// The phone and glasses can follow.

import { useEffect, useRef, useState } from "react";
import { facName, formatDateTime, formatTime, getTimeline, unixToIso } from "@/lib/api";
import type { Timeline } from "@/lib/types";
import { useApp } from "./AppProvider";
import { PauseIcon, PlayIcon } from "./Icons";
import { CardSkeleton } from "./Skeleton";

const BAND = { amber: "bg-amber-400/70", red: "bg-red-500", green: "" } as const;

// How long one 5-minute reading lasts on screen.
const SPEEDS = [
  { label: "Real time (5 minutes per reading)", ms: 300000 },
  { label: "10 seconds per reading", ms: 10000 },
  { label: "1 second per reading", ms: 1000 },
  { label: "Fast (0.25 s per reading)", ms: 250 },
  { label: "Very fast (0.1 s per reading)", ms: 100 },
];

// Timelines already loaded, per dataset, for the whole session: switching back to a dataset shows its bar at once
// (no placeholder while it reloads, even if the backend is busy just after a restart).
const timelineCache = new Map<string, Timeline>();
const RETRY_MS = [2000, 4000, 8000]; // quiet retries before showing "Couldn't load"

export default function TimeTravel({ bare = false }: { bare?: boolean }) {
  const { dataset, asOf, setAsOf, playing, setPlaying, overview } = useApp();
  const [got, setGot] = useState<{ dataset: string; data: Timeline | null } | null>(null);
  const [draft, setDraft] = useState<number | null>(null);
  const [follow, setFollow] = useState(true);
  const [speed, setSpeed] = useState(1000);
  const [pauseOnAlarm, setPauseOnAlarm] = useState(true);
  const [hopTo, setHopTo] = useState<number | null>(null); // the alarm the replay buddy last hopped onto
  const [attempt, setAttempt] = useState(0);
  const cached = dataset ? timelineCache.get(dataset) ?? null : null;
  const loaded = (got && got.dataset === dataset) || !!cached;
  const tl = (got && got.dataset === dataset ? got.data : null) ?? cached;
  const valueRef = useRef(0);

  useEffect(() => {
    if (!dataset) return;
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const load = (tries: number) => {
      getTimeline(dataset)
        .then((d) => {
          timelineCache.set(dataset, d);
          if (alive) setGot({ dataset, data: d });
        })
        .catch(() => {
          if (!alive) return;
          if (tries < RETRY_MS.length) timer = setTimeout(() => load(tries + 1), RETRY_MS[tries]);
          else setGot({ dataset, data: null }); // the cached bar (if any) stays on screen
        });
    };
    load(0);
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [dataset, attempt]);

  const value = draft ?? asOf ?? tl?.last ?? 0;
  useEffect(() => {
    valueRef.current = value;
  }, [value]);

  // Dragging: wait for the hand to stop before asking the backend.
  useEffect(() => {
    if (draft === null || !tl) return;
    const t = setTimeout(() => {
      setAsOf(draft >= tl.last - tl.step_s ? null : draft, follow);
      setDraft(null);
    }, 300);
    return () => clearTimeout(t);
  }, [draft, tl, follow, setAsOf]);

  // Playing: one reading (5 minutes of data) per tick.
  useEffect(() => {
    if (!playing || !tl) return;
    const id = setInterval(() => {
      const cur = valueRef.current;
      const next = cur + tl.step_s;
      if (next >= tl.last) {
        setAsOf(null, follow); // reached the newest reading
        setPlaying(false);
        return;
      }
      const hit = pauseOnAlarm ? tl.alarms.find((a) => a > cur && a <= next) : undefined;
      if (hit !== undefined) {
        setAsOf(hit, follow);
        setPlaying(false);
        setHopTo(hit); // the replay buddy hops onto the alarm marker
        return;
      }
      setAsOf(next, follow);
    }, speed);
    return () => clearInterval(id);
  }, [playing, tl, speed, follow, pauseOnAlarm, setAsOf, setPlaying]);

  // Leaving the page stops the playback.
  useEffect(() => () => setPlaying(false), [setPlaying]);

  if (!tl)
    return loaded ? (
      <section className={`text-lg text-zinc-400 ${bare ? "" : "border border-zinc-800 bg-zinc-900 p-4"}`}>
        Couldn&apos;t load the time-travel bar.{" "}
        <button onClick={() => { setGot(null); setAttempt((n) => n + 1); }} className="font-semibold text-sky-400 underline underline-offset-2">Try again</button>
      </section>
    ) : (
      <CardSkeleton lines={2} />
    );
  const span = tl.last - tl.first || 1;
  const live = asOf === null && draft === null;
  const pct = (t: number) => `${(Math.max(0, Math.min(1, (t - tl.first) / span)) * 100).toFixed(2)}%`;
  const prev = [...tl.alarms].reverse().find((a) => a < value - 60);
  const jump = (t: number) => {
    setPlaying(false);
    setAsOf(t, follow);
  };
  const reading = Math.round((value - tl.first) / tl.step_s) + 1;
  const total = Math.round(span / tl.step_s) + 1;

  function togglePlay() {
    if (playing) return setPlaying(false);
    if (live) setAsOf(tl!.first, follow); // at the end: start over from the beginning
    setPlaying(true);
  }

  // Events as the data came in: when each problem started and when the system noticed it.
  const feed = [...(overview?.alerts ?? [])].sort((a, b) => b.detected_ts.localeCompare(a.detected_ts));

  return (
    <section className={bare ? "" : "rounded-xl border border-zinc-800 bg-zinc-900 p-4"}>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
        <button onClick={togglePlay} aria-label={playing ? "Pause" : "Play"}
          className="flex items-center gap-2 btn-primary px-5 py-3 text-lg font-semibold">
          {playing ? <PauseIcon /> : <PlayIcon />}
          {playing ? "Pause" : "Play"}
        </button>
        <div>
          <p className="hud">SYS//TIMELINE · Neural replay · {playing ? "playing" : live ? "latest data" : "paused"}</p>
          <p className={`text-2xl font-bold tabular-nums ${draft !== null ? "glitch-text" : ""}`}>{formatDateTime(unixToIso(value))}</p>
          <p className="text-sm text-zinc-500">
            Reading {reading} of {total} · a new reading every 5 minutes
            {value < tl.last ? ` · next at ${formatTime(unixToIso(value + tl.step_s))} UTC` : " · newest reading"}
          </p>
        </div>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          <select value={speed} onChange={(e) => setSpeed(Number(e.target.value))} aria-label="Playback speed"
            className="rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-base text-zinc-100">
            {SPEEDS.map((s) => <option key={s.ms} value={s.ms}>{s.label}</option>)}
          </select>
          <button onClick={() => prev && jump(prev)} disabled={!prev}
            className="rounded-lg border border-zinc-700 px-3 py-2 text-base text-zinc-200 hover:bg-zinc-800 disabled:opacity-30">Earlier alarm</button>
          <button onClick={() => { setPlaying(false); setAsOf(null, follow); }} disabled={live}
            className="rounded-lg border border-zinc-700 px-3 py-2 text-base font-semibold text-zinc-100 hover:bg-zinc-800 disabled:opacity-30">Latest</button>
        </div>
      </div>

      <div className="relative mt-3 h-9">
        <div className="absolute inset-x-0 top-3 h-2 rounded bg-zinc-800">
          {/* Only the past: nothing after the chosen moment is drawn, so the bar never gives away what comes next. */}
          {tl.bands.filter((b) => b.start <= value).map((b, i) => (
            <div key={i} className={`absolute inset-y-0 rounded-sm ${BAND[b.level]}`}
              style={{ left: pct(b.start), width: `max(3px, calc(${pct(Math.min(b.end, value))} - ${pct(b.start)}))` }} />
          ))}
        </div>
        {/* thin strip: a leak or a worn pump is open (these last for days, so they do not colour the main bar) */}
        <div className="absolute inset-x-0 top-6 h-1 bg-zinc-800">
          {tl.slow_bands.filter((b) => b.start <= value).map((b, i) => (
            <div key={i} className="absolute inset-y-0 bg-zinc-500"
              style={{ left: pct(b.start), width: `max(3px, calc(${pct(Math.min(b.end, value))} - ${pct(b.start)}))` }} />
          ))}
        </div>
        {/* tick marks: one per day (taller) and every 6 hours */}
        <div aria-hidden className="pointer-events-none absolute inset-x-0 top-[30px] h-2">
          {Array.from({ length: Math.floor((tl.last - tl.first) / 21600) + 1 }, (_, i) => {
            const t = Math.ceil(tl.first / 21600) * 21600 + i * 21600;
            if (t > tl.last) return null;
            const day = t % 86400 === 0;
            return <span key={t} className={`absolute top-0 w-px ${day ? "h-2 bg-[#AD6564]" : "h-1 bg-[#AD6564]/60"}`} style={{ left: pct(t) }} />;
          })}
        </div>
        {/* replay buddy: a mini owl on the playhead; it hops onto an alarm marker when replay pauses there */}
        <span aria-hidden key={hopTo ?? "buddy"} className={`pointer-events-none absolute -top-5 -translate-x-1/2 ${hopTo === value ? "buddy-hop" : ""}`}
          style={{ left: pct(value) }}>
          <svg viewBox="0 0 20 18" width="20" height="18">
            <path d="M4 7 L3 1 L7 5 Q10 3.6 13 5 L17 1 L16 7 Q17.5 15 10 17 Q2.5 15 4 7 Z" fill="#c9b8b0" />
            <path d="M4.6 7.4 Q7 6.2 9.4 7.4 Q9.6 9.8 7 10.2 Q4.4 9.8 4.6 7.4 Z M10.6 7.4 Q13 6.2 15.4 7.4 Q15.6 9.8 13 10.2 Q10.4 9.8 10.6 7.4 Z" fill="#1a0710" />
            <path d="M9.2 10.6 L10.8 10.6 L10 12.4 Z" fill="#bc7579" />
          </svg>
        </span>
        <input type="range" min={tl.first} max={tl.last} step={tl.step_s} value={value}
          onChange={(e) => { setPlaying(false); setDraft(Number(e.target.value)); }}
          aria-label="Time travel slider" className="timeslider absolute inset-0 w-full" />
      </div>

      <div className="mt-1 flex flex-wrap items-center justify-between gap-2 text-sm text-zinc-500">
        <span>{formatDateTime(unixToIso(tl.first))}</span>
        <span className="flex items-center gap-3">
          <span><span className="mr-1 inline-block h-2 w-3 bg-amber-400/70" />pump failed, tank can wait</span>
          <span><span className="mr-1 inline-block h-2 w-3 bg-red-500" />danger, alarm</span>
          <span><span className="mr-1 inline-block h-1 w-3 bg-zinc-500" />leak or worn pump open</span>
        </span>
        <span>{formatDateTime(unixToIso(tl.last))}</span>
      </div>

      <div className="mt-3 flex flex-wrap gap-x-6 gap-y-2 text-base text-zinc-300">
        <label className="flex cursor-pointer items-center gap-2">
          <input type="checkbox" checked={pauseOnAlarm} onChange={(e) => setPauseOnAlarm(e.target.checked)} className="h-4 w-4 accent-sky-500" />
          Pause when an alarm starts
        </label>
        <label className="flex cursor-pointer items-center gap-2">
          <input type="checkbox" checked={follow} onChange={(e) => {
            setFollow(e.target.checked);
            if (asOf !== null) setAsOf(asOf, e.target.checked);
          }} className="h-4 w-4 accent-sky-500" />
          The phone and glasses follow this time
        </label>
      </div>

      {feed.length > 0 && (
        <div className="mt-4 border-t border-zinc-800 pt-3">
          <p className="mb-1 text-sm uppercase tracking-wide text-zinc-500">Found so far</p>
          <ul className="space-y-1 text-base">
            {feed.slice(0, 6).map((a) => (
              <li key={a.event_id} className="flex flex-wrap gap-x-3 text-zinc-300">
                <span className="w-36 shrink-0 whitespace-nowrap font-mono text-zinc-400">{formatTime(a.detected_ts)} UTC</span>
                <span className="font-medium text-zinc-100">{facName(a.facility_id)}</span>
                <span className="text-zinc-400">
                  {a.category === "pump_failure" ? "pump failure" : a.category === "pipeline_leak" ? "possible leak" : "pump wearing out"}
                  {" "}· started {formatTime(a.onset_ts)}, noticed {formatTime(a.detected_ts)}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
