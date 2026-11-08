"use client";

// One system as a top-down neon city. Facilities, the disposal site and the truck yard sit at their real lat/lon
// positions (same layout as before); the city blocks, streets, district name and landmarks are procedural
// decoration seeded by the system id (lib/city.ts). Facility cards keep their text status labels and the backend's
// severity colour. Pipelines glow, with flow pulses toward the disposal site (none from a failed pump).
// Drag to pan, wheel or pinch to zoom (0.6x-3x). Cards and labels stay readable (never below 12 px).
// The light line is the route the operator walked last shift; missed stops are dashed.
// prefers-reduced-motion: no pulses, flicker or glow animation (globals.css).

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { fmtHours } from "@/lib/api";
import { buildCity, H, layout, near, W, type Pt } from "@/lib/city";
import type { FacilityCard, Shift, System } from "@/lib/types";
import { sevInfo } from "./Badges";

type Tone = "ok" | "amber" | "red";
const BORDER: Record<Tone, string> = { ok: "border-emerald-500", amber: "border-amber-400", red: "border-red-500" };
const DOT: Record<Tone, string> = { ok: "bg-emerald-500", amber: "bg-amber-400", red: "bg-red-500" };

// Card colour = the backend's severity for this facility (never worked out here).
const tone = (f: FacilityCard): Tone => sevInfo(f.severity).tone;
const failed = (f: FacilityCard) => f.pump_status === 2 || f.status === "failure" || f.status === "tripped";

const ZMIN = 0.6;
const ZMAX = 3;
const clampZ = (z: number) => Math.min(ZMAX, Math.max(ZMIN, z));
type View = { z: number; x: number; y: number }; // zoom, pan in px
const HOME: View = { z: 1, x: 0, y: 0 };

export default function SiteMap(props: { system: System; shift: Shift | null }) {
  return <CityMap key={props.system.id} {...props} />; // a new system starts at the default view
}

function CityMap({ system, shift }: { system: System; shift: Shift | null }) {
  const facs = system.facilities;
  const lay = useMemo(() => layout(system), [system]);
  const city = useMemo(() => buildCity(system.id, lay), [system.id, lay]);
  const { pos, disp, yard } = lay;

  const [view, setView] = useState<View>(HOME);
  const [hover, setHover] = useState<{ kind: "fac" | "lm"; id: string } | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const dragged = useRef(false);

  const planned = (shift?.route_planned ?? []).filter((id) => pos.has(id));
  const walked = new Set(shift?.route_walked ?? []);
  const walkedPts = planned.filter((id) => walked.has(id)).map((id) => pos.get(id)!);
  const missed = planned.filter((id) => !walked.has(id));
  const dangerKey = facs.filter((f) => f.severity === "high").map((f) => f.id).join(",");

  // The city never changes while panning, so it is built once (per system and danger state) and reused.
  const cityLayer = useMemo(() => {
    const danger = dangerKey ? dangerKey.split(",").map((id) => pos.get(id)!) : [];
    return (
      <>
        {/* river */}
        <path d={city.river} fill="none" stroke="#0b1622" strokeWidth="3.4" strokeLinecap="round" />
        <path d={city.river} fill="none" stroke="#19E6FF" strokeOpacity="0.07" strokeWidth="1" vectorEffect="non-scaling-stroke" />
        {/* minor streets: thin and dark; main avenues: wider, faint glow */}
        <g stroke="#19E6FF" strokeOpacity="0.08" strokeWidth="1.5" vectorEffect="non-scaling-stroke">
          {city.streets.filter((t) => !t.main).map((t, i) => <line key={i} x1={t.x1} y1={t.y1} x2={t.x2} y2={t.y2} />)}
        </g>
        <g stroke="#19E6FF" strokeOpacity="0.2" strokeWidth="5" vectorEffect="non-scaling-stroke" filter={`url(#glow-${system.id})`} strokeLinecap="round">
          {city.streets.filter((t) => t.main).map((t, i) => <line key={i} x1={t.x1} y1={t.y1} x2={t.x2} y2={t.y2} />)}
        </g>
        {/* blocks; the ones near a facility in danger glow red */}
        {city.blocks.map((b, i) => {
          const hot = danger.some((p) => near(b, p, 13));
          return hot ? (
            <rect key={i} x={b.x} y={b.y} width={b.w} height={b.h} fill="#34161d" stroke="#e5484d" strokeOpacity="0.55"
              strokeWidth="1" vectorEffect="non-scaling-stroke" className="city-danger" />
          ) : (
            <rect key={i} x={b.x} y={b.y} width={b.w} height={b.h} fill={b.fill} />
          );
        })}
        {/* a few lit windows */}
        {city.lights.map((w, i) => <circle key={i} cx={w.x} cy={w.y} r="0.12" fill={w.color} opacity={w.opacity} />)}
      </>
    );
  }, [city, dangerKey, pos, system.id]);

  // keep at least part of the map on screen
  const clampPan = (v: View): View => {
    const r = box.current?.getBoundingClientRect();
    if (!r) return v;
    return { z: v.z, x: Math.min(r.width * 0.7, Math.max(r.width * 0.3 - r.width * v.z, v.x)), y: Math.min(r.height * 0.7, Math.max(r.height * 0.3 - r.height * v.z, v.y)) };
  };
  const zoomAt = (factor: number, cx: number, cy: number) =>
    setView((v) => {
      const z = clampZ(v.z * factor);
      return clampPan({ z, x: cx - ((cx - v.x) * z) / v.z, y: cy - ((cy - v.y) * z) / v.z });
    });

  // wheel zoom around the cursor (non-passive, so the page does not scroll while zooming the map)
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const r = el.getBoundingClientRect();
      zoomAt(Math.exp(-e.deltaY * 0.0015), e.clientX - r.left, e.clientY - r.top);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  });

  // drag to pan, two fingers to pinch-zoom. One gesture session at a time; a second finger joins it.
  const gesture = useRef<{ pts: Map<number, Pt>; last: { x: number; y: number; d: number }; start: Pt } | null>(null);
  const resetLast = (g: NonNullable<typeof gesture.current>) => {
    const [a, b] = [...g.pts.values()];
    g.last = b ? { x: (a[0] + b[0]) / 2, y: (a[1] + b[1]) / 2, d: Math.hypot(a[0] - b[0], a[1] - b[1]) } : { x: a[0], y: a[1], d: 0 };
  };
  const onPointerDown = (e: React.PointerEvent) => {
    if (e.pointerType === "mouse" && e.button !== 0) return;
    const el = box.current;
    if (!el) return;
    if (gesture.current) { // second finger
      gesture.current.pts.set(e.pointerId, [e.clientX, e.clientY]);
      resetLast(gesture.current);
      return;
    }
    dragged.current = false;
    const g = { pts: new Map<number, Pt>([[e.pointerId, [e.clientX, e.clientY]]]), last: { x: e.clientX, y: e.clientY, d: 0 }, start: [e.clientX, e.clientY] as Pt };
    gesture.current = g;
    const move = (ev: PointerEvent) => {
      if (!g.pts.has(ev.pointerId)) return;
      g.pts.set(ev.pointerId, [ev.clientX, ev.clientY]);
      if (Math.hypot(ev.clientX - g.start[0], ev.clientY - g.start[1]) > 4) dragged.current = true;
      const [a, b] = [...g.pts.values()];
      const last = g.last;
      if (b) {
        const mid = { x: (a[0] + b[0]) / 2, y: (a[1] + b[1]) / 2, d: Math.hypot(a[0] - b[0], a[1] - b[1]) };
        const r = el.getBoundingClientRect();
        if (last.d > 0) zoomAt(mid.d / last.d, mid.x - r.left, mid.y - r.top);
        setView((v) => clampPan({ ...v, x: v.x + mid.x - last.x, y: v.y + mid.y - last.y }));
        g.last = mid;
      } else {
        setView((v) => clampPan({ ...v, x: v.x + ev.clientX - last.x, y: v.y + ev.clientY - last.y }));
        g.last = { x: ev.clientX, y: ev.clientY, d: 0 };
      }
    };
    const up = (ev: PointerEvent) => {
      g.pts.delete(ev.pointerId);
      if (g.pts.size) return resetLast(g);
      gesture.current = null;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  };

  // screen position of a map point, for the HTML layer (cards and labels do not scale with the SVG)
  const at = (p: Pt): React.CSSProperties => ({
    left: `calc(${p[0] * view.z}% + ${view.x}px)`,
    top: `calc(${(p[1] / H) * 100 * view.z}% + ${view.y}px)`,
  });
  const cardScale = Math.min(1.2, Math.max(0.86, view.z)); // 14 px x 0.86 = 12 px minimum
  const hovered = hover?.kind === "fac" ? facs.find((f) => f.id === hover.id) : null;
  const hoveredLm = hover?.kind === "lm" ? city.landmarks.find((l) => l.name === hover.id) : null;

  return (
    <div
      ref={box}
      onPointerDown={onPointerDown}
      onClickCapture={(e) => {
        if (dragged.current) { e.preventDefault(); e.stopPropagation(); } // a drag is not a click
      }}
      className="relative aspect-[16/9] w-full cursor-grab touch-none select-none overflow-hidden border border-zinc-800 bg-[#120e16] active:cursor-grabbing"
      aria-label={`Map of ${system.id}. Drag to pan, scroll or pinch to zoom.`}
    >
      {/* the city, pipelines and route: one SVG that pans and zooms */}
      <div className="absolute inset-0 origin-top-left" style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.z})` }}>
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" className="absolute inset-0 h-full w-full overflow-visible">
          <defs>
            <filter id={`glow-${system.id}`} x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="0.5" result="b" />
              <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
            </filter>
          </defs>

          {cityLayer}

          {/* pipelines to the disposal site: glow, plus flow pulses unless the pump has failed */}
          {facs.map((f) => {
            const p = pos.get(f.id)!;
            const leak = f.status === "leak";
            return (
              <g key={f.id}>
                <line x1={p[0]} y1={p[1]} x2={disp[0]} y2={disp[1]} stroke={leak ? "#f2b33d" : "#19E6FF"} strokeOpacity="0.3"
                  strokeWidth="10" vectorEffect="non-scaling-stroke" strokeLinecap="round" filter={`url(#glow-${system.id})`} />
                <line x1={p[0]} y1={p[1]} x2={disp[0]} y2={disp[1]} stroke={leak ? "#f2b33d" : "#19E6FF"} strokeWidth="3"
                  strokeDasharray={leak ? "10 6" : undefined} vectorEffect="non-scaling-stroke" strokeLinecap="round" opacity="0.9" />
                {!failed(f) && (
                  <line x1={p[0]} y1={p[1]} x2={disp[0]} y2={disp[1]} stroke="#E6FDFF" strokeWidth="2.5" strokeDasharray="2 22"
                    vectorEffect="non-scaling-stroke" strokeLinecap="round" className="city-flow" />
                )}
              </g>
            );
          })}

          {missed.map((id) => (
            <line key={id} x1={pos.get(id)![0]} y1={pos.get(id)![1]} x2={(walkedPts.at(-1) ?? pos.get(id)!)[0]} y2={(walkedPts.at(-1) ?? pos.get(id)!)[1]}
              stroke="#a9afb8" strokeDasharray="4 6" strokeWidth="3" vectorEffect="non-scaling-stroke" opacity="0.7" />
          ))}
          {walkedPts.length > 1 && (
            <polyline points={walkedPts.map((p) => p.join(",")).join(" ")} fill="none" stroke="#c8ccd2" strokeWidth="4" strokeLinecap="round"
              strokeLinejoin="round" vectorEffect="non-scaling-stroke" opacity="0.9" />
          )}
        </svg>
      </div>

      {/* vignette: darker toward the edges */}
      <div aria-hidden className="pointer-events-none absolute inset-0" style={{ background: "radial-gradient(ellipse at center, transparent 50%, rgba(8,6,10,0.75) 100%)" }} />

      {/* landmark rooftop signs: small, dim, decoration only (HTML so the text stays readable at any zoom) */}
      {city.landmarks.map((l) => (
        <span key={l.name} onPointerEnter={() => setHover({ kind: "lm", id: l.name })} onPointerLeave={() => setHover(null)}
          className="city-sign absolute -translate-x-1/2 -translate-y-1/2 whitespace-nowrap font-mono text-[12px] font-medium uppercase tracking-wider"
          style={{ ...at([l.x + l.w / 2, l.y + l.h / 2]), color: l.sign, opacity: 0.6, textShadow: `0 0 4px ${l.sign}66` }}>
          {l.name}
        </span>
      ))}

      {/* district label */}
      <span className="pointer-events-none absolute left-3 top-3 z-20 font-mono text-sm tracking-widest text-zinc-300 opacity-70">
        {system.id} {"//"} {city.district}
      </span>

      <div className="pointer-events-none absolute flex -translate-x-1/2 -translate-y-1/2 flex-col items-center" style={{ ...at(disp), transform: `scale(${cardScale})` }}>
        <span className="h-7 w-7 rotate-45 border-2 border-cyan-200 bg-zinc-950 shadow-[0_0_12px_#19E6FF80]" />
        <span className="mt-2 whitespace-nowrap bg-zinc-950/85 px-2 py-0.5 text-sm font-semibold text-zinc-200">Disposal site</span>
        <span className="whitespace-nowrap bg-zinc-950/85 px-1.5 text-sm text-zinc-400">{system.disposal_site.pressure_psi} psi</span>
      </div>
      <div className="pointer-events-none absolute flex -translate-x-1/2 -translate-y-1/2 flex-col items-center" style={{ ...at(yard), transform: `scale(${cardScale})` }}>
        <span className="h-6 w-6 border-2 border-zinc-300 bg-zinc-950" />
        <span className="mt-1 whitespace-nowrap bg-zinc-950/85 px-2 py-0.5 text-sm text-zinc-300">Truck yard · {system.fleet_size} trucks</span>
      </div>

      {facs.map((f) => {
        const t = tone(f);
        const flagCount = shift?.flags.filter((x) => x.equipment_id === f.id && x.status !== "dismissed").length ?? 0;
        const stop = planned.indexOf(f.id) + 1;
        const isMissed = missed.includes(f.id);
        const run = f.pump_status === 1;
        return (
          <Link key={`${f.id}-${f.severity}`} href={`/facility/${f.id}`} draggable={false}
            onPointerEnter={() => setHover({ kind: "fac", id: f.id })} onPointerLeave={() => setHover(null)}
            style={{ ...at(pos.get(f.id)!), transform: `scale(${cardScale})` }}
            className={`fac-card absolute w-44 -translate-x-1/2 -translate-y-1/2 border-2 bg-zinc-950 p-2.5 ${BORDER[t]} ${isMissed ? "border-dashed" : ""} ${t === "red" ? "fac-danger" : ""}`}>
            {stop > 0 && (
              <span className="absolute -left-3 -top-3 flex h-7 w-7 items-center justify-center rounded-full bg-zinc-300 text-sm font-bold text-zinc-950 ring-2 ring-zinc-950">{stop}</span>
            )}
            <div className="flex items-center gap-2">
              <span className={`h-3 w-3 shrink-0 rounded-full ${DOT[t]}`} />
              <span className={`truncate text-base font-bold ${t === "red" ? "fac-sign text-red-300" : "text-zinc-100"}`}>{f.name}</span>
            </div>
            <div className="mt-1.5 flex items-center gap-1.5">
              {f.wells.map((w) => (
                <span key={w.id} className={`h-2.5 w-2.5 rounded-full ${w.producing ? "bg-emerald-400" : "bg-zinc-600"}`} title={`${w.id} ${w.producing ? "producing" : "shut in"}`} />
              ))}
              <div className="relative h-3.5 flex-1 bg-zinc-800">
                <div className={`h-full ${f.level_pct >= f.shutdown_pct - 0.1 ? "bg-red-500" : f.level_pct >= f.warning_pct ? "bg-amber-400" : "bg-sky-500"}`} style={{ width: `${f.level_pct}%` }} />
                <div className="absolute inset-y-0 w-px bg-red-300" style={{ left: `${f.shutdown_pct}%` }} />
              </div>
              <span className={`text-sm font-bold ${f.pump_status === 2 ? "text-red-400" : run ? "text-emerald-400" : "text-zinc-500"}`}>
                {f.pump_status === 2 ? "FAULT" : run ? "ON" : "off"}
              </span>
            </div>
            <div className="mt-1 text-sm tabular-nums text-zinc-400">
              Tank {f.level_pct.toFixed(0)}%
              {f.hours_to_limit && f.status !== "tripped" && <span className="ml-1 font-semibold text-red-300">· {fmtHours(f.hours_to_limit.p50)} left</span>}
              {f.status === "tripped" && <span className="ml-1 font-semibold text-red-300">· tripped</span>}
            </div>
            <div className="mt-1 text-sm font-semibold text-zinc-200">
              {sevInfo(f.severity).label}{flagCount ? ` · ${flagCount} flag${flagCount > 1 ? "s" : ""}` : ""}
            </div>
            {isMissed && <div className="text-sm text-zinc-400">stop missed</div>}
          </Link>
        );
      })}

      {/* tooltips */}
      {hovered && (
        <div role="tooltip" className="pointer-events-none absolute z-10 -translate-x-1/2 whitespace-nowrap border border-zinc-600 bg-zinc-950 px-3 py-1.5 text-sm text-zinc-100"
          style={at([pos.get(hovered.id)![0], pos.get(hovered.id)![1] + 8.5 / view.z])}>
          {hovered.name}: tank {hovered.level_pct.toFixed(0)}%
          {hovered.status === "tripped" ? " · tank at shutdown" : hovered.hours_to_limit ? ` · shutdown in ${fmtHours(hovered.hours_to_limit.p50)}` : " · no countdown"}
        </div>
      )}
      {hoveredLm && (
        <div role="tooltip" className="pointer-events-none absolute z-10 -translate-x-1/2 whitespace-nowrap border border-zinc-700 bg-zinc-950 px-3 py-1.5 text-sm text-zinc-300"
          style={at([hoveredLm.x + hoveredLm.w / 2, hoveredLm.y + hoveredLm.h + 1.4 / view.z])}>
          <span className="font-semibold" style={{ color: hoveredLm.sign }}>{hoveredLm.name}:</span> {hoveredLm.joke}
        </div>
      )}

      {/* controls */}
      <div className="absolute right-3 top-3 z-20 flex gap-1" onPointerDown={(e) => e.stopPropagation()}>
        {[["−", 1 / 1.25, "Zoom out"], ["+", 1.25, "Zoom in"]].map(([label, f, name]) => (
          <button key={name as string} type="button" aria-label={name as string}
            onClick={() => { const r = box.current!.getBoundingClientRect(); zoomAt(f as number, r.width / 2, r.height / 2); }}
            className="h-9 w-9 border border-zinc-600 bg-zinc-950/90 text-lg font-bold text-zinc-100 hover:bg-zinc-800">{label}</button>
        ))}
        <button type="button" onClick={() => setView(HOME)} className="h-9 border border-zinc-600 bg-zinc-950/90 px-3 text-sm font-semibold text-zinc-100 hover:bg-zinc-800">
          Reset view
        </button>
      </div>
    </div>
  );
}

export function MapLegend() {
  return (
    <ul className="mt-3 flex flex-wrap gap-x-6 gap-y-2 text-base text-zinc-300">
      {[["bg-emerald-500", "Normal or minor"], ["bg-amber-400", "Check soon"], ["bg-red-500", "Danger"]].map(([c, l]) => (
        <li key={l} className="flex items-center gap-2"><span className={`h-4 w-4 rounded-full ${c}`} />{l}</li>
      ))}
      <li className="flex items-center gap-2"><span className="h-1 w-8 bg-cyan-300" />Pipeline, dots show flow</li>
      <li className="flex items-center gap-2"><span className="h-1 w-8 bg-zinc-300" />Route walked last shift</li>
      <li className="flex items-center gap-2"><span className="h-4 w-6 border-2 border-dashed border-zinc-300" />Stop missed</li>
      <li className="text-zinc-500">Drag to move, scroll or pinch to zoom. Named buildings are decoration.</li>
    </ul>
  );
}
