"use client";

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
    <header className="border-b border-zinc-800 bg-zinc-950">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-2 px-6 py-4">
        <Link href="/" className="flex items-center gap-3 text-2xl font-bold tracking-tight text-zinc-100">
          NightShift
        </Link>
        <nav className="flex flex-wrap gap-1">
          {LINKS.map((l) => {
            const active = l.href === "/" ? path === "/" : path.startsWith(l.href);
            return (
              <Link
                key={l.href}
                href={l.href}
                className={`px-4 py-2 text-base font-medium ${
                  active ? "border-b-2 border-sky-400 text-zinc-100" : "border-b-2 border-transparent text-zinc-400 hover:text-zinc-100"
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
