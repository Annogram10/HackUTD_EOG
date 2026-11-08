"use client";

// Header: the NightShift neon-tube sign, the tagline, HUD-style tabs, and a flat skyline behind it (decoration only:
// windows that switch on and off, small neon rooftop signs, faint scanlines). Original drawing, no external assets.
// Demo path only in the menu. /flags and /facility/[id] still work (linked from the pages).
// Reduced motion: no flicker, no window toggling (globals.css).

import Link from "next/link";
import { usePathname } from "next/navigation";

const LINKS = [
  { href: "/", label: "Now" },
  { href: "/report", label: "Handover" },
  { href: "/agent", label: "How it decided" },
];

// A fixed, hand-tuned skyline (same on every page). x, width, height in a 1400 x 80 strip along the bottom of the
// header (heights scaled so every rooftop sign fits inside the strip).
const BUILDINGS: [number, number, number][] = ([
  [0, 70, 46], [64, 48, 72], [108, 90, 38], [192, 56, 88], [244, 74, 54], [314, 40, 96], [350, 92, 44], [438, 60, 70],
  [494, 84, 34], [574, 52, 82], [622, 70, 58], [688, 46, 100], [730, 96, 42], [822, 58, 76], [876, 80, 50],
  [952, 50, 92], [998, 88, 40], [1082, 62, 68], [1140, 44, 86], [1180, 90, 46], [1266, 56, 80], [1318, 82, 52],
] as [number, number, number][]).map(([x, w, h]) => [x, w, Math.round(h * 0.55)]);
const SIGNS: { b: number; name: string; color: string }[] = [
  { b: 3, name: "Owlsaka Tower", color: "#FF2BD6" },
  { b: 5, name: "Brinetechnica", color: "#19E6FF" },
  { b: 9, name: "Pumpitech", color: "#E8D25A" },
  { b: 11, name: "Tank Tao", color: "#FF2BD6" },
  { b: 15, name: "Megatank H10", color: "#19E6FF" },
  { b: 18, name: "Hootsuka Works", color: "#E8D25A" },
  { b: 20, name: "Afterflow", color: "#FF2BD6" },
];
const WINDOWS: { x: number; y: number; d: number }[] = [];
BUILDINGS.forEach(([x, w, h], i) => {
  for (let k = 0; k < 3; k++) {
    const wx = x + 8 + ((i * 37 + k * 23) % Math.max(8, w - 16));
    const wy = 80 - h + 8 + ((i * 13 + k * 29) % Math.max(6, h - 14));
    WINDOWS.push({ x: wx, y: wy, d: (i * 7 + k * 11) % 23 });
  }
});

function Skyline() {
  return (
    <svg aria-hidden viewBox="0 0 1400 80" preserveAspectRatio="xMidYMax slice" className="pointer-events-none absolute inset-0 h-full w-full">
      {BUILDINGS.map(([x, w, h], i) => (
        <rect key={i} x={x} y={80 - h} width={w} height={h} fill={i % 2 ? "#1d1722" : "#221a28"} />
      ))}
      {WINDOWS.map((w, i) => (
        <rect key={i} x={w.x} y={w.y} width="3" height="3" className="sky-win" fill="#E8D25A" style={{ animationDelay: `${w.d}s` }} />
      ))}
      {SIGNS.map((s) => {
        const [x, w, h] = BUILDINGS[s.b];
        return (
          <text key={s.name} x={x + w / 2} y={80 - h - 4} textAnchor="middle" fontSize="12" className="sky-sign"
            style={{ fontFamily: "var(--font-mono)", letterSpacing: "0.08em", textTransform: "uppercase" }} fill={s.color} opacity="0.6">
            {s.name}
          </text>
        );
      })}
    </svg>
  );
}

export default function Nav() {
  const path = usePathname();
  return (
    <header className="relative overflow-hidden border-b border-zinc-700 bg-zinc-950">
      <div aria-hidden className="scanlines pointer-events-none absolute inset-0 z-10" />
      <div className="relative mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-x-6 gap-y-3 px-6 pb-2 pt-5">
        <Link href="/" className="flex flex-col leading-none" aria-label="NightShift, home">
          <span className="neon-sign font-heading text-3xl font-bold tracking-wide">
            <span className="neon-night">Ni<span className="neon-flicker">g</span>ht</span>
            <span className="neon-shift">Shift</span>
          </span>
          <span className="mt-1.5 font-mono text-xs tracking-[0.3em] text-zinc-400">AVON NEVER SLEEPS</span>
        </Link>
        <nav className="flex flex-wrap gap-1">
          {LINKS.map((l) => {
            const active = l.href === "/" ? path === "/" : path.startsWith(l.href);
            return (
              <Link
                key={l.href}
                href={l.href}
                aria-current={active ? "page" : undefined}
                className={`border-b-2 bg-zinc-950/70 px-3 py-2 font-mono text-sm uppercase tracking-wider ${
                  active ? "border-[#19E6FF] text-zinc-100" : "border-transparent text-zinc-400 hover:text-zinc-100"
                }`}
              >
                [ {l.label} ]
              </Link>
            );
          })}
        </nav>
      </div>
      {/* the skyline strip along the bottom of the header, under the sign and the tabs */}
      <div className="relative h-20">
        <Skyline />
      </div>
    </header>
  );
}
