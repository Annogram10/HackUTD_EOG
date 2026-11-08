"use client";

// The owl, fixed in the bottom-right corner of every page so the mood is always in view.
// Pages leave room at the bottom (pb-48 in the layout) so it never sits on top of the last content.

import { useApp } from "./AppProvider";
import Owl from "./Owl";

const CAPTION = { green: "All normal", amber: "Check soon", red: "Danger" } as const;

export default function OwlCorner() {
  const { riskLevel } = useApp();
  const level = riskLevel ?? "green";
  return (
    <div className="no-print fixed bottom-4 right-4 z-40 flex flex-col items-center gap-1 border border-zinc-700 bg-zinc-900 px-3 pb-2 pt-3" aria-live="polite">
      <Owl level={level} size={128} />
      <span className={`text-sm font-semibold ${level === "red" ? "text-red-300" : level === "amber" ? "text-amber-300" : "text-zinc-200"}`}>
        {CAPTION[level]}
      </span>
    </div>
  );
}
