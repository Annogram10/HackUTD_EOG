// Map geometry and the decorative city around the real facilities. Pure functions, no React.
// Facility, disposal-site and truck-yard positions come from their real lat/lon exactly as before; the city
// (blocks, streets, district name, landmarks) is procedural decoration seeded by the system id, so every system
// gets its own but stable layout. Landmarks never overlap a facility card, a pipeline, the disposal site or the yard.

import type { System } from "./types";

export const W = 100;
export const H = 56.25;
export const CHIP = { w: 17, h: 14.5 }; // facility card size in map units (used for spacing and keep-out zones)

export type Pt = [number, number];

function fit(points: Pt[]): Pt[] {
  const lat0 = points.reduce((a, p) => a + p[0], 0) / points.length;
  const kx = 111 * Math.cos((lat0 * Math.PI) / 180);
  const xy = points.map(([la, lo]) => [lo * kx, -la * 111] as Pt);
  const xs = xy.map((p) => p[0]);
  const ys = xy.map((p) => p[1]);
  const dx = Math.max(...xs) - Math.min(...xs) || 1;
  const dy = Math.max(...ys) - Math.min(...ys) || 1;
  const s = Math.min((W - 2 * 16) / dx, (H - 2 * 13) / dy);
  const cx = (Math.max(...xs) + Math.min(...xs)) / 2;
  const cy = (Math.max(...ys) + Math.min(...ys)) / 2;
  return xy.map(([x, y]) => [W / 2 + (x - cx) * s, H / 2 + (y - cy) * s]);
}

// Nudge cards apart when real locations are close, keeping them near where they really are.
function spread(p: Pt[]): Pt[] {
  const q = p.map((v) => [...v] as Pt);
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

export interface Layout {
  pos: Map<string, Pt>;
  disp: Pt;
  yard: Pt;
}

export function layout(system: System): Layout {
  const facs = system.facilities;
  const base = fit([...facs.map((f) => [f.lat, f.lon] as Pt), [system.disposal_site.lat, system.disposal_site.lon]]);
  const pts = spread(base);
  const pos = new Map(facs.map((f, i) => [f.id, pts[i]]));
  const disp = base[facs.length];
  // the truck yard is usually far away: show it at the edge of the map in its real direction
  const yardRaw = fit([...facs.map((f) => [f.lat, f.lon] as Pt), [system.disposal_site.lat, system.disposal_site.lon], system.truck_yard]);
  const yardDir = [yardRaw[yardRaw.length - 1][0] - W / 2, yardRaw[yardRaw.length - 1][1] - H / 2];
  const k = Math.min((W / 2 - 8) / Math.abs(yardDir[0] || 1e-6), (H / 2 - 5) / Math.abs(yardDir[1] || 1e-6));
  const yard: Pt = [W / 2 + yardDir[0] * k, H / 2 + yardDir[1] * k];
  return { pos, disp, yard };
}

// ---------- the decorative city ----------

export const LANDMARKS: { name: string; joke: string }[] = [
  { name: "Owlsaka Tower", joke: "they're always watching. So are we." },
  { name: "Brinetechnica", joke: "salt water in, salty engineers out." },
  { name: "Pumpitech", joke: "pumps so smart they file their own work orders." },
  { name: "Tank Tao", joke: "the tank that is full is not the eternal tank." },
  { name: "Megatank H10", joke: "holds ten of everything. Mostly water." },
  { name: "Hootsuka Works", joke: "night shift only. Day shift is a rumour." },
  { name: "Arroyo Pumpworks", joke: "established before the arroyo dried up." },
  { name: "Petrochem Nest", joke: "premium perches, zero vacancies." },
  { name: "Afterflow", joke: "the bar where pressure goes to unwind." },
];
const SIGN_COLORS = ["#FF2BD6", "#19E6FF", "#FFD319"];
const DISTRICTS = ["Brine Heights", "Neon Flats", "Low Pressure", "Rust Harbor", "Salt Mesa", "Pumptown", "Night Basin", "Static Row"];

export interface Block { x: number; y: number; w: number; h: number; fill: string; cx: number; cy: number }
export interface Landmark { name: string; joke: string; x: number; y: number; w: number; h: number; sign: string }
export interface City { blocks: Block[]; streetsX: number[]; streetsY: number[]; district: string; landmarks: Landmark[] }

function seeded(id: string) {
  let h = 2166136261;
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 16777619);
  let a = h >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface Rect { x: number; y: number; w: number; h: number }
const overlaps = (a: Rect, b: Rect) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

// distance from point to segment
function segDist(p: Pt, a: Pt, b: Pt) {
  const dx = b[0] - a[0], dy = b[1] - a[1];
  const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy || 1)));
  return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}
function rectNearSegment(r: Rect, a: Pt, b: Pt, clear: number) {
  const corners: Pt[] = [[r.x, r.y], [r.x + r.w, r.y], [r.x, r.y + r.h], [r.x + r.w, r.y + r.h], [r.x + r.w / 2, r.y + r.h / 2]];
  if (corners.some((c) => segDist(c, a, b) < clear)) return true;
  // the segment passing through the rect
  for (let t = 0; t <= 1; t += 0.05) {
    const p: Pt = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
    if (p[0] > r.x - clear && p[0] < r.x + r.w + clear && p[1] > r.y - clear && p[1] < r.y + r.h + clear) return true;
  }
  return false;
}

/** Keep-out zones in map units: every facility card, the disposal site and the truck yard (with their labels). */
export function keepOut(l: Layout): Rect[] {
  const m = 1;
  const out: Rect[] = [...l.pos.values()].map(([x, y]) => ({ x: x - CHIP.w / 2 - m, y: y - CHIP.h / 2 - m, w: CHIP.w + 2 * m, h: CHIP.h + 2 * m }));
  out.push({ x: l.disp[0] - 6, y: l.disp[1] - 4, w: 12, h: 10 }); // diamond + "Disposal site" + psi
  out.push({ x: l.yard[0] - 9, y: l.yard[1] - 3.5, w: 18, h: 8 }); // square + "Truck yard · n trucks"
  return out;
}

export function buildCity(systemId: string, l: Layout): City {
  const rnd = seeded(systemId);
  const cellW = 7 + rnd() * 1.5;
  const cellH = 5.2 + rnd() * 1;
  const street = 1.1;
  const ox = -rnd() * cellW;
  const oy = -rnd() * cellH;
  const streetsX: number[] = [];
  const streetsY: number[] = [];
  for (let x = ox; x < W + cellW; x += cellW) streetsX.push(x);
  for (let y = oy; y < H + cellH; y += cellH) streetsY.push(y);

  const blocks: Block[] = [];
  for (const x0 of streetsX) {
    for (const y0 of streetsY) {
      if (rnd() < 0.12) continue; // a plaza
      const split = rnd() < 0.35;
      const parts = split ? 2 : 1;
      const innerW = cellW - street;
      for (let i = 0; i < parts; i++) {
        const w = split ? innerW / 2 - 0.3 : innerW - rnd() * 1.2;
        const x = x0 + street / 2 + (split ? i * (innerW / 2 + 0.3) : rnd() * 0.6);
        const h = cellH - street - rnd() * 1.2;
        const y = y0 + street / 2 + rnd() * 0.5;
        blocks.push({ x, y, w, h, fill: rnd() < 0.5 ? "#221B26" : "#2A2130", cx: x + w / 2, cy: y + h / 2 });
      }
    }
  }

  // landmarks: on city blocks in empty space, in list order, up to all nine
  const zones = keepOut(l);
  const pipes: [Pt, Pt][] = [...l.pos.values()].map((p) => [p, l.disp]);
  const placed: Landmark[] = [];
  const candidates = blocks
    .filter((b) => b.x > 1 && b.y > 1 && b.x + b.w < W - 1 && b.y + b.h < H - 1 && b.w > 3.5 && b.h > 3)
    .map((b) => ({ b, r: rnd() }))
    .sort((p, q) => p.r - q.r)
    .map((p) => p.b);
  for (const b of candidates) {
    if (placed.length >= LANDMARKS.length) break;
    const w = Math.min(b.w, 5 + rnd() * 2);
    const h = Math.min(b.h, 3.6 + rnd() * 1);
    const r: Rect = { x: b.cx - w / 2, y: b.cy - h / 2, w, h };
    const sign: Rect = { x: r.x - 3, y: r.y - 3, w: r.w + 6, h: 3 }; // the rooftop sign label above it
    const both = [r, sign];
    if (both.some((x) => zones.some((z) => overlaps(x, z)))) continue;
    if (both.some((x) => pipes.some(([a, c]) => rectNearSegment(x, a, c, 1.2)))) continue;
    if (placed.some((p) => both.some((x) => overlaps(x, { x: p.x - 3.5, y: p.y - 3.5, w: p.w + 7, h: p.h + 7 })))) continue;
    if (sign.y < 0.5) continue;
    const i = placed.length;
    placed.push({ ...LANDMARKS[i], ...r, sign: SIGN_COLORS[i % SIGN_COLORS.length] });
  }

  return { blocks, streetsX, streetsY, district: DISTRICTS[Math.floor(rnd() * DISTRICTS.length)], landmarks: placed };
}

/** City blocks within `radius` map units of a point (used to light up blocks around a facility in danger). */
export const near = (b: Block, p: Pt, radius: number) => Math.hypot(b.cx - p[0], b.cy - p[1]) < radius;
