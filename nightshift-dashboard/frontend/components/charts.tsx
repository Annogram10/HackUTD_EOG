// Small SVG charts, no chart library.

import { unixToIso } from "@/lib/api";

const W = 640;
const PAD = { l: 52, r: 16, t: 14, b: 30 };

function ticks(min: number, max: number, n = 4) {
  return Array.from({ length: n + 1 }, (_, i) => min + ((max - min) * i) / n);
}
const fmtNum = (v: number) => (Math.abs(v) >= 100 ? Math.round(v).toString() : v.toFixed(1).replace(/\.0$/, ""));
const hhmm = (ts: number) => {
  const d = new Date(ts * 1000);
  return `${d.toLocaleDateString([], { month: "short", day: "numeric", timeZone: "UTC" })} ${String(d.getUTCHours()).padStart(2, "0")}:00`;
};

interface Line {
  value: number;
  label: string;
  color: string;
}
interface Band {
  from: number;
  to: number;
  color: string;
  label: string;
}

// A sensor over time, with limit lines and shaded bands where a problem was in progress.
export function SeriesChart({
  title, unit, points, lines = [], bands = [], height = 190, bare = false,
}: {
  title: string; unit: string; points: [number, number][]; lines?: Line[]; bands?: Band[]; height?: number; bare?: boolean;
}) {
  if (points.length < 2) return <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5 text-zinc-500">{title}: no data</div>;
  const H = height;
  const t0 = points[0][0];
  const t1 = points[points.length - 1][0];
  const vals = points.map((p) => p[1]).concat(lines.map((l) => l.value));
  let lo = Math.min(...vals);
  let hi = Math.max(...vals);
  const padv = (hi - lo || 1) * 0.08;
  lo = lo >= 0 ? Math.max(0, lo - padv) : lo - padv; // readings that can't be negative start at 0
  hi = hi + padv;
  const x = (t: number) => PAD.l + ((t - t0) / (t1 - t0 || 1)) * (W - PAD.l - PAD.r);
  const y = (v: number) => PAD.t + (1 - (v - lo) / (hi - lo)) * (H - PAD.t - PAD.b);
  const path = points.map((p) => `${x(p[0]).toFixed(1)},${y(p[1]).toFixed(1)}`).join(" ");
  const last = points[points.length - 1][1];

  return (
    <div className={bare ? "" : "rounded-xl border border-zinc-800 bg-zinc-900 p-4"}>
      <div className="flex items-baseline justify-between">
        <h3 className="text-lg text-zinc-300">{title}</h3>
        <span className="text-base tabular-nums text-zinc-100">
          {fmtNum(last)} <span className="text-zinc-500">{unit}</span>
        </span>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} className="mt-1 w-full" role="img" aria-label={title}>
        {bands.map((b, i) => {
          const a = Math.max(x(b.from), PAD.l);
          const z = Math.min(x(b.to), W - PAD.r);
          return z > a ? <rect key={i} x={a} y={PAD.t} width={z - a} height={H - PAD.t - PAD.b} fill={b.color} opacity="0.16"><title>{b.label}</title></rect> : null;
        })}
        {ticks(lo, hi).map((v, i) => (
          <g key={i}>
            <line x1={PAD.l} x2={W - PAD.r} y1={y(v)} y2={y(v)} stroke="#5a3a42" />
            <text x={PAD.l - 6} y={y(v) + 4} textAnchor="end" fontSize="12" fontFamily="var(--font-mono)" fill="#c59fb0">{fmtNum(v)}</text>
          </g>
        ))}
        {ticks(t0, t1, 4).map((t, i) => (
          <text key={i} x={x(t)} y={H - 8} textAnchor={i === 0 ? "start" : i === 4 ? "end" : "middle"} fontSize="12" fontFamily="var(--font-mono)" fill="#c59fb0">{hhmm(t)}</text>
        ))}
        {lines.map((l) => (
          <g key={l.label}>
            <line x1={PAD.l} x2={W - PAD.r} y1={y(l.value)} y2={y(l.value)} stroke={l.color} strokeDasharray="6 4" strokeWidth="1.5" />
            <text x={W - PAD.r - 2} y={y(l.value) - 4} textAnchor="end" fontSize="12" fontFamily="var(--font-mono)" fill={l.color}>{l.label}</text>
          </g>
        ))}
        <polyline points={path} fill="none" stroke="#f8eed7" strokeWidth="2" strokeLinejoin="round" />
      </svg>
    </div>
  );
}

// Tank level after the failure: doing nothing vs the recommended plan.
export function WhatIfChart({
  doNothing, withPlan, shutdown, warning, now, repairEnd, marks,
}: {
  doNothing: { ts: number; level_pct: number }[];
  withPlan: { ts: number; level_pct: number }[];
  shutdown: number; warning: number; now: number; repairEnd: number;
  marks: { min: number; label: string }[];
}) {
  const H = 260;
  const span = (repairEnd - now) / 60;
  const all = [...doNothing, ...withPlan].map((p) => p.level_pct);
  const lo = Math.max(0, Math.floor((Math.min(...all) - 5) / 5) * 5);
  const hi = Math.min(100, Math.max(shutdown + 4, Math.max(...all) + 2));
  const x = (m: number) => PAD.l + (m / span) * (W - PAD.l - PAD.r);
  const y = (v: number) => PAD.t + (1 - (v - lo) / (hi - lo)) * (H - PAD.t - PAD.b);
  const toPath = (pts: { ts: number; level_pct: number }[]) =>
    pts.map((p) => `${x((p.ts - now) / 60).toFixed(1)},${y(p.level_pct).toFixed(1)}`).join(" ");
  const trip = doNothing.length && doNothing[doNothing.length - 1].level_pct >= shutdown - 0.1;
  const tripPt = trip ? doNothing[doNothing.length - 1] : null;

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full" role="img" aria-label="Tank level with and without the plan">
      {ticks(lo, hi).map((v, i) => (
        <g key={i}>
          <line x1={PAD.l} x2={W - PAD.r} y1={y(v)} y2={y(v)} stroke="#5a3a42" />
          <text x={PAD.l - 6} y={y(v) + 4} textAnchor="end" fontSize="12" fontFamily="var(--font-mono)" fill="#c59fb0">{Math.round(v)}%</text>
        </g>
      ))}
      {ticks(0, span, 4).map((m, i) => (
        <text key={i} x={x(m)} y={H - 8} textAnchor={i === 0 ? "start" : i === 4 ? "end" : "middle"} fontSize="12" fontFamily="var(--font-mono)" fill="#c59fb0">
          {i === 0 ? "now" : `+${(m / 60).toFixed(1)} h`}
        </text>
      ))}
      <line x1={PAD.l} x2={W - PAD.r} y1={y(warning)} y2={y(warning)} stroke="#ff9f1c" strokeDasharray="6 4" />
      <text x={W - PAD.r - 2} y={y(warning) - 4} textAnchor="end" fontSize="12" fontFamily="var(--font-mono)" fill="#ff9f1c">warning {warning}%</text>
      <line x1={PAD.l} x2={W - PAD.r} y1={y(shutdown)} y2={y(shutdown)} stroke="#ff6b6b" strokeWidth="1.5" />
      <text x={W - PAD.r - 2} y={y(shutdown) - 4} textAnchor="end" fontSize="12" fontFamily="var(--font-mono)" fill="#ff6b6b">shutdown {shutdown}%</text>
      <polyline points={toPath(doNothing)} fill="none" stroke="#ff6b6b" strokeWidth="2.5" strokeDasharray="7 5" />
      <polyline points={toPath(withPlan)} fill="none" stroke="#5dd39e" strokeWidth="3" strokeLinejoin="round" />
      {tripPt && (
        <g>
          <circle cx={x((tripPt.ts - now) / 60)} cy={y(tripPt.level_pct)} r="6" fill="#ff2d2d" stroke="#342b30" strokeWidth="2" />
          {(() => {
            const tx = x((tripPt.ts - now) / 60);
            const nearRight = tx > W * 0.6; // keep the label inside the chart: put it left of the point near the edge
            return (
              <text x={nearRight ? tx - 10 : tx + 10} y={y(tripPt.level_pct) + 22} textAnchor={nearRight ? "end" : "start"} fontSize="12" fill="#ff9a9a">
                tank trips, wells shut in
              </text>
            );
          })()}
        </g>
      )}
      {marks.map((m, i) => (
        <g key={i}>
          <line x1={x(m.min)} x2={x(m.min)} y1={PAD.t} y2={H - PAD.b} stroke="#5dd39e" strokeDasharray="2 4" opacity="0.7" />
          <text x={x(m.min) + 4} y={PAD.t + 12 + i * 13} fontSize="12" fontFamily="var(--font-mono)" fill="#9be6c2">{m.label}</text>
        </g>
      ))}
    </svg>
  );
}

export { unixToIso };
