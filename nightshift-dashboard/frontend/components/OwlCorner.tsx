"use client";

// The owl, fixed in the bottom-right corner of every page so the mood is always in view.

import { useApp } from "./AppProvider";
import Owl from "./Owl";

const CAPTION = { green: "All normal", amber: "Check soon", red: "Danger" } as const;

export default function OwlCorner() {
  const { riskLevel } = useApp();
  const level = riskLevel ?? "green";
  return (
    <div className="no-print fixed bottom-4 right-4 z-40 flex flex-col items-center gap-1 border border-zinc-700 bg-zinc-900 px-3 pb-2 pt-3">
      <Owl level={level} size={104} />
      <span className="text-sm font-semibold text-zinc-200">{CAPTION[level]}</span>
    </div>
  );
}
