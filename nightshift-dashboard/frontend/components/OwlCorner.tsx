"use client";

// The owl, small, in the header on every page so the mood is always in view. It sits in the header's own row,
// so it never covers the danger card or any numbers.

import { useApp } from "./AppProvider";
import Owl from "./Owl";

const CAPTION = { green: "All normal", amber: "Check soon", red: "Danger" } as const;

export default function OwlCorner() {
  const { riskLevel } = useApp();
  const level = riskLevel ?? "green";
  return (
    <div className="no-print flex items-center gap-2" aria-live="polite">
      <Owl level={level} size={44} />
      <span className={`text-sm font-semibold ${level === "red" ? "text-red-300" : level === "amber" ? "text-amber-300" : "text-zinc-300"}`}>
        {CAPTION[level]}
      </span>
    </div>
  );
}
