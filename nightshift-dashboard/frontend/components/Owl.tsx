"use client";

// The NightShift owl. It shows how the shift is going at a glance, on every page:
// calm and happy when all is normal, worried when something needs checking, freaked out when it is danger.
// It is grey on purpose: the expression carries the message, so it never relies on colour alone.

import { useId } from "react";
import type { RiskLevel } from "@/lib/types";

// Red alert, angry and "going crazy": a solid black wraparound visor (its V-shaped top reads as angry brows) with
// three pairs of glowing slit eyes, all the same size. Each pair flickers on its own loop, out of sync; when a pair
// is off it is simply gone (only black glass remains). Reduced motion: all pairs steady.
// The owl's right wing (on the viewer's right) is cybernetic: chrome plates, ball joints, red cable inlays and
// metal finger-feathers. Original drawing.
const EYE_ROWS = [16.6, 20.2, 23.8]; // one pair per row, same size
const EYE_X = 14.6; // centre of the left eyes; right eyes mirror it
const VISOR = "M7.6 12.2 L24 17 L40.4 12.2 L40.4 26.2 Q33 28.6 25.6 26.6 L24 25.6 L22.4 26.6 Q15 28.6 7.6 26.2 Z";

// A slanted slit, inner end lower (angry). side -1 = left eye, 1 = right eye.
function slit(cx: number, cy: number, side: number) {
  const w = 2.6, h = 0.95, tilt = 0.7 * side;
  return `${cx - w},${cy - h - tilt} ${cx + w},${cy - h + tilt} ${cx + w},${cy + h + tilt} ${cx - w},${cy + h - tilt}`;
}

// Cybernetic wing, down (calm) or raised (red).
function CyberWing({ raised, chrome, dark }: { raised: boolean; chrome: string; dark: string }) {
  const red = "#a3262b";
  const seam = "#3a3f46";
  if (raised)
    return (
      <g>
        <path d="M38.4 22.6 L46.2 11.4 L46.6 13.2 L40.6 34.2 Z" fill={`url(#${dark})`} stroke={seam} strokeWidth="0.35" />
        <path d="M39 22.8 L45.6 12.6 L44.6 19.2 L40.4 26.2 Z" fill={`url(#${chrome})`} />
        <path d="M40.5 19.8 L45 17.2 M40.6 25.6 L43.7 23.7 M40.4 30.1 L42.5 28.7" stroke={seam} strokeWidth="0.5" />
        <path d="M40 24.2 L45 14.6" stroke={red} strokeWidth="0.8" strokeLinecap="round" />
        <circle cx="39.4" cy="23.8" r="2.1" fill={`url(#${chrome})`} stroke={seam} strokeWidth="0.35" />
        <circle cx="39.4" cy="23.8" r="0.8" fill="#1c2026" />
        <circle cx="44" cy="19.6" r="1.05" fill={`url(#${chrome})`} stroke={seam} strokeWidth="0.3" />
        {/* metal finger-feathers, spread */}
        <path d="M45.7 12 l-1.7 -3 M46.2 11.7 l-0.2 -3.4 M46.7 12 l1 -2.8" stroke={`url(#${chrome})`} strokeWidth="1" strokeLinecap="round" />
      </g>
    );
  return (
    <g>
      <path d="M38.4 24.8 Q44.8 33 38.2 42.2 Q35.4 33.2 35.7 26.4 Z" fill={`url(#${dark})`} stroke={seam} strokeWidth="0.35" />
      <path d="M38.6 25.6 Q42.6 30.8 41.6 34.2 L37 33.8 Q36.5 29.2 37.3 26.3 Z" fill={`url(#${chrome})`} />
      <path d="M36.3 30 L42.2 30.6 M36.7 34.6 L42.3 35.1 M37.1 38.6 L40.8 38.9" stroke={seam} strokeWidth="0.5" />
      <path d="M37.7 27.6 Q38.8 33 38.3 39.4" stroke={red} strokeWidth="0.8" strokeLinecap="round" fill="none" />
      <circle cx="37.6" cy="26.6" r="2" fill={`url(#${chrome})`} stroke={seam} strokeWidth="0.35" />
      <circle cx="37.6" cy="26.6" r="0.8" fill="#1c2026" />
      <circle cx="41.7" cy="33.4" r="1.05" fill={`url(#${chrome})`} stroke={seam} strokeWidth="0.3" />
      {/* metal finger-feathers, folded */}
      <path d="M38.2 41.6 l-1.5 2.9 M38.8 41.8 l-0.2 3.2 M39.4 41.4 l1 2.7" stroke={`url(#${chrome})`} strokeWidth="1" strokeLinecap="round" />
    </g>
  );
}



const LABEL: Record<RiskLevel, string> = {
  green: "Owl is happy: all normal",
  amber: "Owl is worried: check soon",
  red: "Owl is freaked out: danger",
};

export default function Owl({ level, size = 40 }: { level: RiskLevel; size?: number }) {
  const uid = useId().replace(/:/g, "");
  const glow = `owl-glow-${uid}`;
  const chrome = `owl-chrome-${uid}`;
  const dark = `owl-chrome-dark-${uid}`;
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
        <linearGradient id={chrome} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#f4f6f8" />
          <stop offset="0.45" stopColor="#aab1ba" />
          <stop offset="0.6" stopColor="#e3e7eb" />
          <stop offset="1" stopColor="#6b727c" />
        </linearGradient>
        <linearGradient id={dark} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#c8ccd2" />
          <stop offset="1" stopColor="#4d535c" />
        </linearGradient>
      </defs>

      {/* ear tufts: flat when calm, standing straight up when freaked out */}
      <path d={red ? "M10 14 L8 2 L19 10 Z" : "M10 14 L8 6 L18 10 Z"} fill="#4d535c" />
      <path d={red ? "M38 14 L40 2 L29 10 Z" : "M38 14 L40 6 L30 10 Z"} fill="#4d535c" />

      {/* body and belly */}
      <ellipse cx="24" cy="28" rx="16" ry="17" fill="#32363d" />
      <ellipse cx="24" cy="34" rx="9" ry="10" fill="#4d535c" />
      <path d="M18 31 q2 2 4 0 M26 31 q2 2 4 0 M20 37 q2 2 4 0 M24 33 q2 2 4 0" stroke="#8b929c" strokeWidth="1" fill="none" strokeLinecap="round" />

      {/* wings: down when calm, up in panic. The right one (viewer's right) is cybernetic. */}
      {red ? <path d="M9 22 L2 12 L8 34 Z" fill="#4d535c" /> : <path d="M9 26 Q5 34 11 41 Q12 33 12 27 Z" fill="#4d535c" />}
      <CyberWing raised={red} chrome={chrome} dark={dark} />

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
          {/* the visor: fully tinted black, always visible */}
          <path d={VISOR} fill="#050608" stroke="#2a2f36" strokeWidth="0.6" strokeLinejoin="round" />
          <path d="M9.5 14.2 L21 17.6" stroke="#3a3f46" strokeWidth="0.5" strokeLinecap="round" opacity="0.8" />
          <path d="M7.6 18.5 L5.6 17.4 M40.4 18.5 L42.4 17.4" stroke="#2a2f36" strokeWidth="1" strokeLinecap="round" />

          {/* three pairs of glowing slit eyes; a pair that flickers out leaves nothing behind */}
          {EYE_ROWS.map((y, i) => (
            <g key={y} className={`owl-pair owl-pair-${i}`}>
              {[-1, 1].map((side) => {
                const cx = 24 + side * (24 - EYE_X);
                return (
                  <g key={side}>
                    <polygon points={slit(cx + 0.7, y, side)} fill="#FF7A2B" opacity="0.55" className="owl-ghost" />
                    <polygon points={slit(cx, y, side)} fill="#19E6FF" filter={`url(#${glow})`} />
                    <polygon points={slit(cx, y, side)} fill="#E6FDFF" transform={`translate(${cx} ${y}) scale(0.45 0.35) translate(${-cx} ${-y})`} />
                  </g>
                );
              })}
            </g>
          ))}
        </>
      )}

      {/* beak: closed; a scowl when angry */}
      {red ? (
        <>
          <path d="M21.5 27.4 L26.5 27.4 L24 31.6 Z" fill="#a9afb8" />
          <path d="M21 33 Q24 31.6 27 33" stroke="#0e0f11" strokeWidth="0.9" fill="none" strokeLinecap="round" />
        </>
      ) : (
        <path d={amber ? "M21.5 26.5 L26.5 26.5 L24 31 Z" : "M21.5 26 L26.5 26 L24 31 Z"} fill="#a9afb8" />
      )}

      {/* feet */}
      <path d="M17 44 l-2 3 M17 44 l1 3 M17 44 l3 2.5 M31 44 l2 3 M31 44 l-1 3 M31 44 l-3 2.5" stroke="#a9afb8" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}
