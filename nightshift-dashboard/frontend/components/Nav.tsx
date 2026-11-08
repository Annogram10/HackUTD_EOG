"use client";

// Header: the NightShift neon-tube sign, the tagline, HUD-style tabs and faint scanlines.
// Reduced motion: no flicker (globals.css).

import Link from "next/link";
import { usePathname } from "next/navigation";

const LINKS = [
  { href: "/", label: "Now" },
  { href: "/flags", label: "Flags" },
  { href: "/report", label: "Handover" },
  { href: "/agent", label: "How it decided" },
];

export default function Nav() {
  const path = usePathname();
  return (
    <header className="relative overflow-hidden border-b border-zinc-700 bg-zinc-950">
      <div aria-hidden className="scanlines pointer-events-none absolute inset-0 z-10" />
      <div className="relative mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-x-6 gap-y-3 px-6 py-5">
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
                  active ? "border-sky-400 text-zinc-100" : "border-transparent text-zinc-400 hover:text-zinc-100"
                }`}
              >
                [ {l.label} ]
              </Link>
            );
          })}
        </nav>
      </div>
    </header>
  );
}
