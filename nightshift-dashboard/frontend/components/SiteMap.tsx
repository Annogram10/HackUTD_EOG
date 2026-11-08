"use client";

// One system drawn from its real coordinates: facilities (wells -> tank -> pump), the pipeline from each
// to the shared disposal site, and the truck yard. Chips are colored by status:
// green normal, amber worn pump / needs review, orange possible leak, red pump failure or confirmed issue.
// The blue line is the route the operator walked last shift; missed stops are dashed.

import Link from "next/link";
import { fmtHours } from "@/lib/api";
import type { FacilityCard, Shift, System } from "@/lib/types";

type Tone = "ok" | "amber" | "orange" | "red";
const BORDER: Record<Tone, string> = { ok: "border-emerald-500", amber: "border-amber-400", orange: "border-amber-500", red: "border-red-500" };
const DOT: Record<Tone, string> = { ok: "bg-emerald-500", amber: "bg-amber-400", orange: "bg-amber-500", red: "bg-red-500" };
const STROKE: Record<Tone, string> = { ok: "#4d535c", amber: "#f2b33d", orange: "#f2b33d", red: "#e5484d" };

function tone(f: FacilityCard, shift: Shift | null): Tone {
  const flags = shift?.flags.filter((x) => x.equipment_id === f.id) ?? [];
  if (f.status === "tripped" || f.status === "failure" || flags.some((x) => x.status === "confirmed")) return "red";
  const minor = f.risk_level === "green"; // a small decrease is fine: no colour
  if (f.status === "leak" && !minor) return "orange";
  if ((f.status === "worn" && !minor) || flags.some((x) => x.status === "pending")) return "amber";
  return "ok";
}

const W = 100;
const H = 56.25;
const CHIP = { w: 17, h: 14.5 }; // chip size in map units, used to keep chips from overlapping

function fit(points: [number, number][]): [number, number][] {
  const lat0 = points.reduce((a, p) => a + p[0], 0) / points.length;
  const kx = 111 * Math.cos((lat0 * Math.PI) / 180);
  const xy = points.map(([la, lo]) => [lo * kx, -la * 111] as [number, number]);
  const xs = xy.map((p) => p[0]);
  const ys = xy.map((p) => p[1]);
  const dx = Math.max(...xs) - Math.min(...xs) || 1;
  const dy = Math.max(...ys) - Math.min(...ys) || 1;
  const s = Math.min((W - 2 * 16) / dx, (H - 2 * 13) / dy);
  const cx = (Math.max(...xs) + Math.min(...xs)) / 2;
  const cy = (Math.max(...ys) + Math.min(...ys)) / 2;
  return xy.map(([x, y]) => [W / 2 + (x - cx) * s, H / 2 + (y - cy) * s]);
}

// Nudge chips apart when real locations are close, keeping them near where they really are.
function spread(p: [number, number][]): [number, number][] {
  const q = p.map((v) => [...v] as [number, number]);
  for (let it = 0; it < 80; it++) {
    for (let i = 0; i < q.length; i++) {
      for (let j = i + 1; j < q.length; j++) {
        const ox = CHIP.w - Math.abs(q[i][0] - q[j][0]);
        const oy = CHIP.h - Math.abs(q[i][1] - q[j][1]);
        if (ox > 0 && oy > 0) {
          if (ox < oy) {
            const d = (q[i][0] <= q[j][0] ? -1 : 1) * (ox / 2 + 0.2);
            q[i][0] += d; q[j][0] -= d;
          } else {
            const d = (q[i][1] <= q[j][1] ? -1 : 1) * (oy / 2 + 0.2);
            q[i][1] += d; q[j][1] -= d;
          }
        }
      }
    }
    q.forEach((v) => {
      v[0] = Math.min(W - CHIP.w / 2 - 1, Math.max(CHIP.w / 2 + 1, v[0]));
      v[1] = Math.min(H - CHIP.h / 2 - 1, Math.max(CHIP.h / 2 + 1, v[1]));
    });
  }
  return q;
}

export default function SiteMap({ system, shift }: { system: System; shift: Shift | null }) {
  const facs = system.facilities;
  const base = fit([...facs.map((f) => [f.lat, f.lon] as [number, number]), [system.disposal_site.lat, system.disposal_site.lon]]);
  const pts = spread(base);
  const pos = new Map(facs.map((f, i) => [f.id, pts[i]]));
  const disp = base[facs.length];
  // the truck yard is usually far away: show it at the edge of the map in its real direction
  const yardRaw = fit([...facs.map((f) => [f.lat, f.lon] as [number, number]), [system.disposal_site.lat, system.disposal_site.lon], system.truck_yard]);
  const yardDir = [yardRaw[yardRaw.length - 1][0] - W / 2, yardRaw[yardRaw.length - 1][1] - H / 2];
  const k = Math.min((W / 2 - 8) / Math.abs(yardDir[0] || 1e-6), (H / 2 - 5) / Math.abs(yardDir[1] || 1e-6));
  const yard: [number, number] = [W / 2 + yardDir[0] * k, H / 2 + yardDir[1] * k];

  const planned = (shift?.route_planned ?? []).filter((id) => pos.has(id));
  const walked = new Set(shift?.route_walked ?? []);
  const walkedPts = planned.filter((id) => walked.has(id)).map((id) => pos.get(id)!);
  const missed = planned.filter((id) => !walked.has(id));
  const pct = (p: [number, number]) => ({ left: `${p[0]}%`, top: `${(p[1] / H) * 100}%` });

  return (
    <div className="relative aspect-[16/9] w-full overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-900">
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" className="absolute inset-0 h-full w-full" aria-hidden>

        {facs.map((f) => {
          const p = pos.get(f.id)!;
          const leak = f.status === "leak";
          return (
            <line key={f.id} x1={p[0]} y1={p[1]} x2={disp[0]} y2={disp[1]} stroke={leak ? STROKE.orange : "#4d535c"} strokeWidth={leak ? 6 : 5}
              strokeDasharray={leak ? "10 6" : undefined} vectorEffect="non-scaling-stroke" strokeLinecap="round" opacity="0.9" />
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

      <div className="absolute flex -translate-x-1/2 -translate-y-1/2 flex-col items-center" style={pct(disp)}>
        <span className="h-7 w-7 rotate-45 rounded-sm border-2 border-zinc-300 bg-zinc-950" />
        <span className="mt-2 whitespace-nowrap rounded bg-zinc-950/85 px-2 py-0.5 text-sm font-semibold text-zinc-200">Disposal site</span>
        <span className="whitespace-nowrap rounded bg-zinc-950/85 px-1.5 text-xs text-zinc-400">{system.disposal_site.pressure_psi} psi</span>
      </div>
      <div className="absolute flex -translate-x-1/2 -translate-y-1/2 flex-col items-center" style={pct(yard)}>
        <span className="h-6 w-6 rounded border-2 border-zinc-300 bg-zinc-950" />
        <span className="mt-1 whitespace-nowrap rounded bg-zinc-950/85 px-2 py-0.5 text-sm text-zinc-300">
          Truck yard · {system.fleet_size} trucks
        </span>
      </div>

      {facs.map((f) => {
        const t = tone(f, shift);
        const stop = planned.indexOf(f.id) + 1;
        const isMissed = missed.includes(f.id);
        const run = f.pump_status === 1;
        return (
          <Link key={f.id} href={`/facility/${f.id}`} style={pct(pos.get(f.id)!)}
            className={`absolute w-44 -translate-x-1/2 -translate-y-1/2 rounded-xl border-2 bg-zinc-950/95 p-2.5 transition-transform hover:scale-105 ${BORDER[t]} ${isMissed ? "border-dashed" : ""}`}>
            {stop > 0 && (
              <span className="absolute -left-3 -top-3 flex h-7 w-7 items-center justify-center rounded-full bg-zinc-300 text-sm font-bold text-zinc-950 ring-2 ring-zinc-950">{stop}</span>
            )}
            <div className="flex items-center gap-2">
              <span className={`h-3 w-3 shrink-0 rounded-full ${DOT[t]}`} />
              <span className="truncate text-base font-bold text-zinc-100">{f.name}</span>
            </div>
            <div className="mt-1.5 flex items-center gap-1.5" title="wells, tank, pump">
              {f.wells.map((w) => (
                <span key={w.id} className={`h-2.5 w-2.5 rounded-full ${w.producing ? "bg-emerald-400" : "bg-zinc-600"}`} title={`${w.id} ${w.producing ? "producing" : "shut in"}`} />
              ))}
              <div className="relative h-3.5 flex-1 rounded-sm bg-zinc-800" title={`Tank ${f.level_pct}%`}>
                <div className={`h-full rounded-sm ${f.level_pct >= f.shutdown_pct - 0.1 ? "bg-red-500" : f.level_pct >= f.warning_pct ? "bg-amber-400" : "bg-sky-500"}`} style={{ width: `${f.level_pct}%` }} />
                <div className="absolute inset-y-0 w-px bg-red-300" style={{ left: `${f.shutdown_pct}%` }} />
              </div>
              <span className={`text-xs font-bold ${f.pump_status === 2 ? "text-red-400" : run ? "text-emerald-400" : "text-zinc-500"}`}>
                {f.pump_status === 2 ? "FAULT" : run ? "ON" : "off"}
              </span>
            </div>
            <div className="mt-1 text-sm tabular-nums text-zinc-400">
              Tank {f.level_pct.toFixed(0)}%
              {f.hours_to_limit && f.status !== "tripped" && <span className="ml-1 font-semibold text-red-300">· {fmtHours(f.hours_to_limit.p50)} left</span>}
              {f.status === "tripped" && <span className="ml-1 font-semibold text-red-300">· tripped</span>}
            </div>
            {isMissed && <div className="text-xs text-zinc-400">stop missed</div>}
          </Link>
        );
      })}
    </div>
  );
}

export function MapLegend() {
  return (
    <ul className="mt-3 flex flex-wrap gap-x-6 gap-y-2 text-base text-zinc-300">
      {[["bg-emerald-500", "Normal"], ["bg-amber-400", "Pump wearing out / needs review"], ["bg-amber-500", "Possible leak"], ["bg-red-500", "Pump failure / confirmed"]].map(([c, l]) => (
        <li key={l} className="flex items-center gap-2"><span className={`h-4 w-4 rounded-full ${c}`} />{l}</li>
      ))}
      <li className="flex items-center gap-2"><span className="h-1 w-8 rounded bg-sky-400" />Route walked last shift</li>
      <li className="flex items-center gap-2"><span className="h-4 w-6 rounded border-2 border-dashed border-zinc-300" />Stop missed</li>
    </ul>
  );
}
