"use client";

// The NightShift owl. It shows how the shift is going at a glance, on every page:
// calm and happy when all is normal, worried when something needs checking, freaked out when it is danger.
// It is grey on purpose: the expression carries the message, so it never relies on colour alone.

import { useId } from "react";
import type { RiskLevel } from "@/lib/types";

// Red alert: small extra eyes open around the face (forehead, above the brows, both cheeks). Sizes are 30-60% of
// the main eye (r 8). They mount when the level turns red, so the CSS sequence in globals.css plays once per entry:
// out-of-sync flickers with small sideways glitches, all open together ~300 ms, then fade out. Reduced motion: hidden.
const EXTRA_EYES = [
  { cx: 24, cy: 6.5, r: 3.6, v: "a" }, // forehead
  { cx: 9.5, cy: 9, r: 2.4, v: "b" }, // above the left brow
  { cx: 38.5, cy: 9, r: 2.6, v: "c" }, // above the right brow
  { cx: 8.5, cy: 30, r: 3.2, v: "c" }, // left cheek
  { cx: 39.5, cy: 30, r: 2.8, v: "a" }, // right cheek
  { cx: 24, cy: 41.5, r: 2.4, v: "b" }, // low on the belly
];

const LABEL: Record<RiskLevel, string> = {
  green: "Owl is happy: all normal",
  amber: "Owl is worried: check soon",
  red: "Owl is freaked out: danger",
};

export default function Owl({ level, size = 40 }: { level: RiskLevel; size?: number }) {
  const glow = `owl-glow-${useId().replace(/:/g, "")}`;
  const red = level === "red";
  const amber = level === "amber";
  return (
    <svg
      viewBox="0 0 48 48"
      width={size}
      height={size}
      role="img"
      aria-label={LABEL[level]}
      className={red ? "owl-shake" : ""}
    >
      <title>{LABEL[level]}</title>
      <defs>
        <filter id={glow} x="-100%" y="-100%" width="300%" height="300%">
          <feGaussianBlur stdDeviation="1.1" result="b" />
          <feMerge>
            <feMergeNode in="b" />
            <feMergeNode in="SourceGraphic" />
          </feMerge>
        </filter>
      </defs>

      {/* ear tufts: flat when calm, standing straight up when freaked out */}
      <path d={red ? "M10 14 L8 2 L19 10 Z" : "M10 14 L8 6 L18 10 Z"} fill="#4d535c" />
      <path d={red ? "M38 14 L40 2 L29 10 Z" : "M38 14 L40 6 L30 10 Z"} fill="#4d535c" />

      {/* body and belly */}
      <ellipse cx="24" cy="28" rx="16" ry="17" fill="#32363d" />
      <ellipse cx="24" cy="34" rx="9" ry="10" fill="#4d535c" />
      <path d="M18 31 q2 2 4 0 M26 31 q2 2 4 0 M20 37 q2 2 4 0 M24 33 q2 2 4 0" stroke="#8b929c" strokeWidth="1" fill="none" strokeLinecap="round" />

      {/* wings: down when calm, up in panic */}
      {red ? (
        <>
          <path d="M9 22 L2 12 L8 34 Z" fill="#4d535c" />
          <path d="M39 22 L46 12 L40 34 Z" fill="#4d535c" />
        </>
      ) : (
        <>
          <path d="M9 26 Q5 34 11 41 Q12 33 12 27 Z" fill="#4d535c" />
          <path d="M39 26 Q43 34 37 41 Q36 33 36 27 Z" fill="#4d535c" />
        </>
      )}

      {/* eyes */}
      {level === "green" && (
        <>
          <circle cx="17" cy="20" r="6" fill="#dfe2e6" />
          <circle cx="31" cy="20" r="6" fill="#dfe2e6" />
          {/* happy closed eyes */}
          <path d="M13.5 21 q3.5 -5 7 0" stroke="#0e0f11" strokeWidth="2" fill="none" strokeLinecap="round" />
          <path d="M27.5 21 q3.5 -5 7 0" stroke="#0e0f11" strokeWidth="2" fill="none" strokeLinecap="round" />
          <ellipse cx="12" cy="26" rx="2.6" ry="1.5" fill="#8b929c" opacity="0.7" />
          <ellipse cx="36" cy="26" rx="2.6" ry="1.5" fill="#8b929c" opacity="0.7" />
        </>
      )}
      {amber && (
        <>
          <circle cx="17" cy="20" r="6.2" fill="#dfe2e6" />
          <circle cx="31" cy="20" r="6.2" fill="#dfe2e6" />
          <circle cx="18.5" cy="21" r="2.4" fill="#0e0f11" />
          <circle cx="32.5" cy="21" r="2.4" fill="#0e0f11" />
          {/* worried brows and a sweat drop */}
          <path d="M11 15 L20 11.5" stroke="#dfe2e6" strokeWidth="1.8" strokeLinecap="round" />
          <path d="M37 15 L28 11.5" stroke="#dfe2e6" strokeWidth="1.8" strokeLinecap="round" />
          <path d="M42 14 q2.5 3.6 0 5.2 q-2.5 -1.6 0 -5.2 Z" fill="#a9afb8" />
        </>
      )}
      {red && (
        <>
          {/* huge glowing red eyes with pinpoint pupils: the steady glare */}
          <circle cx="16.5" cy="20" r="8" fill="#e5484d" filter={`url(#${glow})`} />
          <circle cx="31.5" cy="20" r="8" fill="#e5484d" filter={`url(#${glow})`} />
          <circle cx="16.5" cy="20" r="1.1" fill="#0e0f11" />
          <circle cx="31.5" cy="20" r="1.1" fill="#0e0f11" />
          <path d="M9 14.5 L21 9.5" stroke="#dfe2e6" strokeWidth="2" strokeLinecap="round" />
          <path d="M39 14.5 L27 9.5" stroke="#dfe2e6" strokeWidth="2" strokeLinecap="round" />
        </>
      )}

      {/* beak: small and closed, or wide open */}
      {red ? (
        <>
          <path d="M20.5 27 L27.5 27 L24 37 Z" fill="#0e0f11" />
          <path d="M21.5 27 L26.5 27 L24 31 Z" fill="#a9afb8" />
        </>
      ) : (
        <path d={amber ? "M21.5 26.5 L26.5 26.5 L24 31 Z" : "M21.5 26 L26.5 26 L24 31 Z"} fill="#a9afb8" />
      )}

      {red && (
        <g className="owl-extra-eyes" aria-hidden>
          {EXTRA_EYES.map((e, i) => (
            <g key={i} className={`owl-eye owl-eye-${e.v}`} style={{ animationDelay: `${(i % 3) * 25}ms` }}>
              <circle cx={e.cx} cy={e.cy} r={e.r} fill="#0e0f11" />
              <circle cx={e.cx} cy={e.cy} r={e.r * 0.8} fill="#e5484d" filter={`url(#${glow})`} />
              <circle cx={e.cx} cy={e.cy} r={Math.max(0.5, e.r * 0.22)} fill="#0e0f11" />
            </g>
          ))}
        </g>
      )}

      {/* feet */}
      <path d="M17 44 l-2 3 M17 44 l1 3 M17 44 l3 2.5 M31 44 l2 3 M31 44 l-1 3 M31 44 l-3 2.5" stroke="#a9afb8" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}
