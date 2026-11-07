"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const LINKS = [
  { href: "/", label: "Overview" },
  { href: "/alerts", label: "Alerts" },
  { href: "/flags", label: "Flags" },
  { href: "/report", label: "Handover" },
  { href: "/next-shift", label: "Next shift" },
  { href: "/agent", label: "Agent trace" },
];

export default function Nav() {
  const path = usePathname();
  return (
    <header className="border-b border-zinc-800 bg-zinc-950/80 backdrop-blur">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2 px-6 py-4">
        <Link href="/" className="text-2xl font-bold tracking-tight text-zinc-100">
          Night<span className="text-amber-400">Shift</span>
        </Link>
        <nav className="flex flex-wrap gap-1">
          {LINKS.map((l) => {
            const active = l.href === "/" ? path === "/" : path.startsWith(l.href);
            return (
              <Link
                key={l.href}
                href={l.href}
                className={`rounded-lg px-4 py-2 text-base font-medium transition-colors ${
                  active ? "bg-zinc-800 text-zinc-100" : "text-zinc-400 hover:text-zinc-100"
                }`}
              >
                {l.label}
              </Link>
            );
          })}
        </nav>
      </div>
    </header>
  );
}
