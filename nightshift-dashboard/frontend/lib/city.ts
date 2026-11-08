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
const MAX_LANDMARKS = 6;
const SIGN_COLORS = ["#FF2BD6", "#19E6FF", "#FFD319"];
const DISTRICTS = ["BRINELANDS", "NEON FLATS", "LOW PRESSURE", "RUST HARBOR", "SALT MESA", "PUMPTOWN", "NIGHT BASIN", "STATIC ROW"];
const GAP = 6.7; // ~80 px at a normal map width: landmarks keep this far from everything real
// the city is drawn well past the visible map so panning and zooming out never show an empty edge
const OUTER = { x: -W * 0.6, y: -H * 0.6, w: W * 2.2, h: H * 2.2 };

export interface Block { x: number; y: number; w: number; h: number; fill: string; cx: number; cy: number }
export interface Street { x1: number; y1: number; x2: number; y2: number; main: boolean }
export interface Light { x: number; y: number; color: string; opacity: number }
export interface Landmark { name: string; joke: string; x: number; y: number; w: number; h: number; sign: string }
export interface City {
  blocks: Block[];
  streets: Street[]; // minor streets and the 2-3 main avenues (incl. one diagonal)
  river: string; // SVG path of the curved river
  lights: Light[];
  district: string;
  landmarks: Landmark[];
}

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
const grow = (r: Rect, m: number): Rect => ({ x: r.x - m, y: r.y - m, w: r.w + 2 * m, h: r.h + 2 * m });

function rectPointDist(r: Rect, p: Pt) {
  const dx = Math.max(r.x - p[0], 0, p[0] - (r.x + r.w));
  const dy = Math.max(r.y - p[1], 0, p[1] - (r.y + r.h));
  return Math.hypot(dx, dy);
}
function rectNearSegment(r: Rect, a: Pt, b: Pt, clear: number) {
  for (let t = 0; t <= 1.0001; t += 0.02) {
    if (rectPointDist(r, [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]) < clear) return true;
  }
  return false;
}

/** Keep-out zones in map units: every facility card, the disposal site and the truck yard (with their labels). */
export function keepOut(l: Layout): Rect[] {
  const out: Rect[] = [...l.pos.values()].map(([x, y]) => ({ x: x - CHIP.w / 2, y: y - CHIP.h / 2, w: CHIP.w, h: CHIP.h }));
  out.push({ x: l.disp[0] - 6, y: l.disp[1] - 4, w: 12, h: 10 }); // diamond + "Disposal site" + psi
  out.push({ x: l.yard[0] - 9, y: l.yard[1] - 3.5, w: 18, h: 8 }); // square + "Truck yard · n trucks"
  return out;
}

const shade = (t: number) => {
  // between #1A141F and #241B29
  const c = (a: number, b: number) => Math.round(a + (b - a) * t).toString(16).padStart(2, "0");
  return `#${c(0x1a, 0x24)}${c(0x14, 0x1b)}${c(0x1f, 0x29)}`;
};

export function buildCity(systemId: string, l: Layout): City {
  const rnd = seeded(systemId);
  const streets: Street[] = [];
  const leaves: Rect[] = [];

  // recursive subdivision: big blocks, small lots and odd shapes, not a grid
  const split = (r: Rect, depth: number) => {
    const big = Math.max(r.w, r.h);
    const stopP = big < 3 ? 1 : big < 6 ? 0.55 : big < 10 ? 0.25 : big < 16 ? 0.08 : 0;
    if (depth > 1 && rnd() < stopP) return leaves.push(r);
    const vertical = r.w > r.h * 1.25 ? true : r.h > r.w * 1.25 ? false : rnd() < 0.5;
    const t = 0.28 + rnd() * 0.44;
    const gap = 0.55;
    if (vertical) {
      const x = r.x + r.w * t;
      streets.push({ x1: x, y1: r.y, x2: x, y2: r.y + r.h, main: false });
      split({ x: r.x, y: r.y, w: x - r.x - gap / 2, h: r.h }, depth + 1);
      split({ x: x + gap / 2, y: r.y, w: r.x + r.w - x - gap / 2, h: r.h }, depth + 1);
    } else {
      const y = r.y + r.h * t;
      streets.push({ x1: r.x, y1: y, x2: r.x + r.w, y2: y, main: false });
      split({ x: r.x, y: r.y, w: r.w, h: y - r.y - gap / 2 }, depth + 1);
      split({ x: r.x, y: y + gap / 2, w: r.w, h: r.y + r.h - y - gap / 2 }, depth + 1);
    }
  };

  // two straight main avenues (one each way) cut the city first; everything else subdivides inside them
  const ax = W * (0.25 + rnd() * 0.5);
  const ay = H * (0.25 + rnd() * 0.5);
  const mg = 1.4;
  streets.push({ x1: ax, y1: OUTER.y, x2: ax, y2: OUTER.y + OUTER.h, main: true });
  streets.push({ x1: OUTER.x, y1: ay, x2: OUTER.x + OUTER.w, y2: ay, main: true });
  for (const [x0, x1] of [[OUTER.x, ax - mg], [ax + mg, OUTER.x + OUTER.w]])
    for (const [y0, y1] of [[OUTER.y, ay - mg], [ay + mg, OUTER.y + OUTER.h]])
      split({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, 0);

  // a diagonal avenue and a curved river cut through; blocks under them are cleared
  const dx0 = W * (0.1 + rnd() * 0.5);
  const diag: [Pt, Pt] = [[dx0 - 40, -30], [dx0 + 60, H + 30]];
  streets.push({ x1: diag[0][0], y1: diag[0][1], x2: diag[1][0], y2: diag[1][1], main: true });
  const ry = [H * (0.2 + rnd() * 0.6), H * (rnd() * 1.2 - 0.1), H * (0.2 + rnd() * 0.6)];
  const riverPts: Pt[] = [];
  for (let i = 0; i <= 60; i++) {
    const t = i / 60;
    const x = -30 + (W + 60) * t;
    const y = (1 - t) * (1 - t) * ry[0] + 2 * (1 - t) * t * ry[1] + t * t * ry[2];
    riverPts.push([x, y]);
  }
  const river = `M${riverPts.map((p) => p.map((v) => v.toFixed(2)).join(" ")).join(" L")}`;

  const blocks: Block[] = [];
  const lights: Light[] = [];
  for (const r of leaves) {
    if (r.w < 0.6 || r.h < 0.6) continue;
    if (rectNearSegment(r, diag[0], diag[1], 1.1)) continue;
    if (riverPts.some((p) => rectPointDist(r, p) < 1.9)) continue;
    // now and then a big block is cut into tiny lots
    const lots: Rect[] = r.w > 4 && r.h > 3 && rnd() < 0.2
      ? [0, 1].flatMap((i) => [0, 1].map((j) => ({ x: r.x + (i * r.w) / 2 + 0.12, y: r.y + (j * r.h) / 2 + 0.12, w: r.w / 2 - 0.24, h: r.h / 2 - 0.24 })))
      : [r];
    for (const b of lots) {
      blocks.push({ ...b, fill: shade(rnd()), cx: b.x + b.w / 2, cy: b.y + b.h / 2 });
      const n = rnd() < 0.08 ? 1 : 0; // a few lit windows, not a light show
      for (let k = 0; k < n; k++)
        lights.push({ x: b.x + 0.3 + rnd() * Math.max(0, b.w - 0.6), y: b.y + 0.3 + rnd() * Math.max(0, b.h - 0.6),
          color: rnd() < 0.7 ? "#FFD319" : "#FF2BD6", opacity: 0.2 + rnd() * 0.25 });
    }
  }

  // landmark signs: on blocks in empty space, at most six, ~80 px from anything real and from each other
  const zones = keepOut(l).map((z) => grow(z, GAP));
  const pipes: [Pt, Pt][] = [...l.pos.values()].map((p) => [p, l.disp]);
  const placed: Landmark[] = [];
  const candidates = blocks
    .filter((b) => b.x > 2 && b.y > 3 && b.x + b.w < W - 2 && b.y + b.h < H - 2 && b.w > 2.5 && b.h > 1.6)
    .map((b) => ({ b, r: rnd() }))
    .sort((p, q) => p.r - q.r)
    .map((p) => p.b);
  for (const b of candidates) {
    if (placed.length >= Math.min(MAX_LANDMARKS, LANDMARKS.length)) break;
    const lm = LANDMARKS[placed.length];
    const w = lm.name.length * 0.62 + 1.2; // label width in map units at 12 px
    const h = 1.7;
    const r: Rect = { x: b.cx - w / 2, y: b.cy - h / 2, w, h };
    if (r.x < 1 || r.x + r.w > W - 1 || r.y < 3 || r.y + r.h > H - 1) continue;
    if (zones.some((z) => overlaps(r, z))) continue;
    if (pipes.some(([a, c]) => rectNearSegment(r, a, c, GAP))) continue;
    if (placed.some((p) => overlaps(r, grow(p, GAP)))) continue;
    placed.push({ ...lm, ...r, sign: SIGN_COLORS[placed.length % SIGN_COLORS.length] });
  }

  return { blocks, streets, river, lights, district: DISTRICTS[Math.floor(rnd() * DISTRICTS.length)], landmarks: placed };
}

/** City blocks within `radius` map units of a point (used to light up blocks around a facility in danger). */
export const near = (b: Block, p: Pt, radius: number) => Math.hypot(b.cx - p[0], b.cy - p[1]) < radius;
