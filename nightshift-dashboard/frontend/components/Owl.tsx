"use client";

// The NightShift owl. It shows how the shift is going at a glance, on every page:
// calm and happy when all is normal, worried when something needs checking, angry with red eyes in danger.
// It is grey on purpose: the expression carries the message, so it never relies on colour alone.

import { useEffect, useId, useRef } from "react";
import type { RiskLevel } from "@/lib/types";

// Aviator sunglasses, worn in every state: two black teardrop lenses with a thin light metal frame, a double
// bridge, short temple arms and a white glint. In danger the glasses hop (drop in, jump off to show the red eyes
// underneath, slam back, once more, then stay) and a red reflection streak appears on each lens; the hop restarts
// each time danger starts. Calm and check-soon: glasses sit still. Reduced motion: no hop. Original drawing.
// The owl's right wing (on the viewer's right) is cybernetic: chrome plates, ball joints, red cable inlays and
// metal finger-feathers.
const LENS_L = "M10 15.4 Q16.4 14.3 22.6 15.7 Q23.1 21 20.1 24.6 Q16.2 27.6 12.1 24.7 Q8.9 21.6 10 15.4 Z";
const LENS_R = "M38 15.4 Q31.6 14.3 25.4 15.7 Q24.9 21 27.9 24.6 Q31.8 27.6 35.9 24.7 Q39.1 21.6 38 15.4 Z";

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
  const glasses = useRef<SVGGElement>(null);
  const glow = `owl-glow-${uid}`;
  const chrome = `owl-chrome-${uid}`;
  const dark = `owl-chrome-dark-${uid}`;
  const red = level === "red";
  const amber = level === "amber";
  // Each time the level enters danger, restart the hop: remove the class, force a reflow, add it back.
  useEffect(() => {
    const g = glasses.current;
    if (!red || !g) return;
    g.classList.remove("owl-hop");
    void g.getBoundingClientRect();
    g.classList.add("owl-hop");
    return () => g.classList.remove("owl-hop");
  }, [red]);

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

      {/* eyes (under the glasses; they show when the glasses lift in danger) */}
      {level === "green" && (
        <>
          <circle cx="16.4" cy="20.4" r="5.4" fill="#dfe2e6" />
          <circle cx="31.6" cy="20.4" r="5.4" fill="#dfe2e6" />
          <path d="M13.2 21.4 q3.2 -4.5 6.4 0" stroke="#0e0f11" strokeWidth="1.8" fill="none" strokeLinecap="round" />
          <path d="M28.4 21.4 q3.2 -4.5 6.4 0" stroke="#0e0f11" strokeWidth="1.8" fill="none" strokeLinecap="round" />
          <ellipse cx="11.6" cy="28.6" rx="2.4" ry="1.3" fill="#8b929c" opacity="0.7" />
          <ellipse cx="36.4" cy="28.6" rx="2.4" ry="1.3" fill="#8b929c" opacity="0.7" />
        </>
      )}
      {amber && (
        <>
          <circle cx="16.4" cy="20.4" r="5.4" fill="#dfe2e6" />
          <circle cx="31.6" cy="20.4" r="5.4" fill="#dfe2e6" />
          <circle cx="17.6" cy="21.2" r="2.2" fill="#0e0f11" />
          <circle cx="32.8" cy="21.2" r="2.2" fill="#0e0f11" />
          {/* worried brows and a sweat drop */}
          <path d="M11 13.2 L20 10.6" stroke="#dfe2e6" strokeWidth="1.6" strokeLinecap="round" />
          <path d="M37 13.2 L28 10.6" stroke="#dfe2e6" strokeWidth="1.6" strokeLinecap="round" />
          <path d="M42 13 q2.5 3.6 0 5.2 q-2.5 -1.6 0 -5.2 Z" fill="#a9afb8" />
        </>
      )}
      {red && (
        <>
          {/* red irises, pinpoint pupils */}
          <circle cx="16.4" cy="20.4" r="5.4" fill="#dfe2e6" />
          <circle cx="31.6" cy="20.4" r="5.4" fill="#dfe2e6" />
          <circle cx="16.4" cy="20.6" r="3.4" fill="#e5484d" />
          <circle cx="31.6" cy="20.6" r="3.4" fill="#e5484d" />
          <circle cx="16.4" cy="20.6" r="0.8" fill="#0e0f11" />
          <circle cx="31.6" cy="20.6" r="0.8" fill="#0e0f11" />
          {/* angry brows */}
          <path d="M10.5 10.2 L20.6 14.2" stroke="#dfe2e6" strokeWidth="1.8" strokeLinecap="round" />
          <path d="M37.5 10.2 L27.4 14.2" stroke="#dfe2e6" strokeWidth="1.8" strokeLinecap="round" />
        </>
      )}

      {/* aviator sunglasses, every state */}
      <g ref={glasses} className="owl-glasses">
        <path d="M10.2 16.3 L6.4 15.1 M37.8 16.3 L41.6 15.1" stroke="#C9C2D0" strokeWidth="0.8" strokeLinecap="round" />
        <path d="M22.4 16.1 Q24 14.7 25.6 16.1" stroke="#C9C2D0" strokeWidth="0.7" fill="none" strokeLinecap="round" />
        <path d="M22.8 18.2 L25.2 18.2" stroke="#C9C2D0" strokeWidth="0.6" strokeLinecap="round" />
        <path d={LENS_L} fill="#0B0A0D" stroke="#C9C2D0" strokeWidth="0.75" strokeLinejoin="round" />
        <path d={LENS_R} fill="#0B0A0D" stroke="#C9C2D0" strokeWidth="0.75" strokeLinejoin="round" />
        {/* glints */}
        <path d="M12.3 19 L15 16.7" stroke="#ffffff" strokeWidth="0.65" strokeLinecap="round" opacity="0.85" />
        <path d="M27.7 19 L30.4 16.7" stroke="#ffffff" strokeWidth="0.65" strokeLinecap="round" opacity="0.85" />
        {/* red reflection streak: danger only, after the glasses settle; fades out when danger ends */}
        <g className={`owl-streak${red ? " on" : ""}`}>
          <path d="M14 24.4 L20.6 18.6" stroke="#e5484d" strokeWidth="0.5" strokeLinecap="round" />
          <path d="M29.6 24.4 L36.2 18.6" stroke="#e5484d" strokeWidth="0.5" strokeLinecap="round" />
        </g>
      </g>

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
