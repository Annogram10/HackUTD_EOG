"use client";

// The NightShift owl. It shows how the shift is going at a glance, on every page:
// calm and happy when all is normal, worried when something needs checking, angry with red eyes in danger.
// It is grey on purpose: the expression carries the message, so it never relies on colour alone.

import { useEffect, useId, useRef } from "react";
import type { RiskLevel } from "@/lib/types";

// Aviator sunglasses, worn in every state: two red-tinted teardrop lenses with a thin light metal frame, a double
// bridge, short temple arms and a white glint. In danger the glasses hop (drop in, jump off to show the red eyes
// underneath, slam back, once more, then stay) and a red reflection streak appears on each lens; the hop restarts
// each time danger starts. Calm and check-soon: glasses sit still. Reduced motion: no hop. Original drawing.
// The owl's right wing (on the viewer's right) is cybernetic: chrome plates, ball joints, red cable inlays and
// metal finger-feathers.
// A more natural owl: teardrop body, feathered ear tufts, heart-shaped facial disc with ring feathering,
// hooked beak, barred chest, layered wing, talons on a branch. Greys only, so colour still means status.
const BODY = "M24 7 C32.5 7 38.6 12.6 38.6 21.5 C38.6 32 34.5 42 24 44 C13.5 42 9.4 32 9.4 21.5 C9.4 12.6 15.5 7 24 7 Z";
const DISC = "M24 13.2 C20.6 9.8 10.4 10.3 10.2 19.6 C10.1 25.6 15.4 28.6 24 29.2 C32.6 28.6 37.9 25.6 37.8 19.6 C37.6 10.3 27.4 9.8 24 13.2 Z";
// Rocker look: long dark swept-back head feathers, red-tinted aviators, scruffy chin feathers, a black tactical
// vest with a dog-tag chain, and the chrome cyber wing.
const HAIR_BACK = "M24 5.6 C13 5.4 6.6 12 6.4 20.5 C6.2 27.5 7.6 33 10 37 L12.6 31 L12.4 22 C13.4 15.5 18 11.6 24 11.4 C30 11.6 34.6 15.5 35.6 22 L35.4 31 L38 37 C40.4 33 41.8 27.5 41.6 20.5 C41.4 12 35 5.4 24 5.6 Z";
const LOCK_A = "M15.5 8.4 C11.4 11 9.4 16.5 10 24 C10.4 29 11.4 32.4 13 35 C12.6 29 12.6 22 14.2 17.4 C15.2 14.6 17.2 12 19.8 10.2 Z";
const LOCK_B = "M18.6 7.6 C15.6 9.8 13.8 13.4 13.2 18 C14.6 14.6 17 12 20.6 10.8 Z";
const BARS: string[] = [];
for (let r = 0; r < 6; r++) {
  const y = 30.6 + r * 2.1;
  const half = 7.6 - Math.abs(r - 2.2) * 1.2; // the chest narrows toward the bottom
  for (let x = 24 - half + (r % 2) * 1.4; x < 24 + half - 1.2; x += 2.8) BARS.push(`M${x.toFixed(2)} ${y.toFixed(2)} q0.7 0.8 1.4 0`);
}
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
      style={{ overflow: "visible" }}
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
        <radialGradient id={`${uid}-body`} cx="0.45" cy="0.3" r="0.8">
          <stop offset="0" stopColor="#6c717a" />
          <stop offset="0.55" stopColor="#454951" />
          <stop offset="1" stopColor="#2a2d33" />
        </radialGradient>
        <radialGradient id={`${uid}-disc`} cx="0.5" cy="0.55" r="0.7">
          <stop offset="0" stopColor="#a7acb3" />
          <stop offset="1" stopColor="#767c84" />
        </radialGradient>
        <linearGradient id={`${uid}-belly`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#8e939a" />
          <stop offset="1" stopColor="#5f646c" />
        </linearGradient>
        <linearGradient id={`${uid}-wing`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#50555d" />
          <stop offset="1" stopColor="#2c2f35" />
        </linearGradient>
        <linearGradient id={`${uid}-lens`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#120708" />
          <stop offset="0.5" stopColor="#4a0f13" />
          <stop offset="1" stopColor="#8f1d22" />
        </linearGradient>
        <clipPath id={`${uid}-discclip`}><path d={DISC} /></clipPath>
        <linearGradient id={dark} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#c8ccd2" />
          <stop offset="1" stopColor="#4d535c" />
        </linearGradient>
      </defs>

      {/* branch it perches on */}
      <path d="M3.5 45.6 Q24 44 44.5 45.9" stroke="#4a4038" strokeWidth="2.2" strokeLinecap="round" fill="none" />
      <path d="M9 45.2 l-2.4 -1.6 M37 45.5 l2.2 -1.8" stroke="#4a4038" strokeWidth="0.9" strokeLinecap="round" />

      {/* long dark head feathers, behind the face */}
      <path d={HAIR_BACK} fill="#1c1d22" />
      <path d="M10 14 Q7.8 22 9.6 32 M12.2 11.4 Q9.6 19 10.8 28 M38 14 Q40.2 22 38.4 32 M35.8 11.4 Q38.4 19 37.2 28 M19 6.8 Q14 8.6 11.2 13 M29 6.8 Q34 8.6 36.8 13"
        stroke="#4a4d56" strokeWidth="0.35" fill="none" strokeLinecap="round" />

      {/* body, chest and barring */}
      <path d={BODY} fill={`url(#${uid}-body)`} />
      <ellipse cx="24" cy="35.2" rx="9.4" ry="8.4" fill={`url(#${uid}-belly)`} opacity="0.9" />
      <path d={BARS.join(" ")} stroke="#3a3e45" strokeWidth="0.45" fill="none" strokeLinecap="round" opacity="0.8" />
      <path d="M18.4 9.6 q1 -0.8 2 0 M22 8.5 q1 -0.8 2 0 M26 8.5 q1 -0.8 2 0 M29.6 9.6 q-1 -0.8 -2 0" stroke="#2c3036" strokeWidth="0.4" fill="none" strokeLinecap="round" />

      {/* black tactical vest with shoulder straps, seams and pockets, and a dog-tag chain */}
      <path d="M15.2 29.6 L13.6 23.8 M32.8 29.6 L34.4 23.8" stroke="#1d1f24" strokeWidth="1.8" strokeLinecap="round" />
      <path d="M13.4 29.4 Q16 30.4 19.4 33.6 L24 35.4 L28.6 33.6 Q32 30.4 34.6 29.4 L35.6 39.4 Q24 44.2 12.4 39.4 Z" fill="#1d1f24" />
      <path d="M24 35.4 L24 43 M13.6 36.4 L34.4 36.4" stroke="#33363c" strokeWidth="0.4" />
      <rect x="16.2" y="37.2" width="4" height="3" fill="none" stroke="#33363c" strokeWidth="0.35" />
      <rect x="27.8" y="37.2" width="4" height="3" fill="none" stroke="#33363c" strokeWidth="0.35" />
      <path d="M18.4 28.9 Q24 33.4 29.6 28.9" stroke="#b9bec6" strokeWidth="0.3" strokeDasharray="0.5 0.35" fill="none" />
      <rect x="23.1" y="31.6" width="1.8" height="2.4" rx="0.4" fill="#c9ccd2" transform="rotate(8 24 32.8)" />

      {/* wings: folded when calm, raised in danger. The right one (viewer's right) is cybernetic. */}
      {red ? (
        <>
          <path d="M11.6 21.6 C7.2 18 3.6 13.4 2.2 9.2 C2.6 15.5 5.2 25.6 10.4 32.2 Z" fill={`url(#${uid}-wing)`} />
          <path d="M4.2 13.4 L9.4 24.4 M3.4 17.4 L8.4 27.4 M5.8 12.2 L10.6 21.4" stroke="#1f2226" strokeWidth="0.4" strokeLinecap="round" />
        </>
      ) : (
        <>
          <path d="M11.2 22.5 C7.8 27 7.6 35.5 11.6 41.5 C12.6 36 13.4 29 13 23.2 Z" fill={`url(#${uid}-wing)`} />
          <path d="M9.4 30 L11.8 38.6 M8.8 34 L11.2 40.6 M10.4 26.4 L12.4 34" stroke="#1f2226" strokeWidth="0.4" strokeLinecap="round" />
        </>
      )}
      <CyberWing raised={red} chrome={chrome} dark={dark} />

      {/* facial disc: heart-shaped, with ring feathering around each eye and a dark ruff at the rim */}
      <path d={DISC} fill={`url(#${uid}-disc)`} stroke="#25282d" strokeWidth="0.8" />
      <g clipPath={`url(#${uid}-discclip)`} fill="none" stroke="#5d636b" strokeWidth="0.35" strokeDasharray="0.9 0.7" opacity="0.8">
        {[16.4, 31.6].map((cx) => [6.6, 8, 9.4].map((r) => <circle key={`${cx}-${r}`} cx={cx} cy="20.4" r={r} />))}
      </g>
      <path d="M24 13.6 L21.7 21 L24 24.2 L26.3 21 Z" fill="#c3c7cc" opacity="0.5" />

      {/* front locks of the long head feathers, framing the face */}
      {[undefined, "translate(48 0) scale(-1 1)"].map((t) => (
        <g key={t ?? "l"} transform={t}>
          <path d={`${LOCK_A} ${LOCK_B}`} fill="#26282e" />
          <path d="M14.6 10.6 Q11.4 16 11.4 24 Q11.6 29 12.6 33 M17.4 9.6 Q14.4 13 13.6 17" stroke="#555963" strokeWidth="0.3" fill="none" strokeLinecap="round" />
        </g>
      ))}
      <path d="M18 8 C21 6.2 27 6.2 30 8 C27.4 7.6 23.6 7.8 21.2 9.6 Z" fill="#26272c" />
      <path d="M22.6 7 Q19 9 16.8 13.2 M25.4 7 Q29 9 31.2 13.2 M14.6 12 Q12 17 12 24" stroke="#3a3b42" strokeWidth="0.3" fill="none" strokeLinecap="round" />

      {/* eyes (under the glasses; they show when the glasses lift in danger) */}
      {[16.4, 31.6].map((cx) => (
        <g key={cx}>
          <circle cx={cx} cy="20.4" r="4.9" fill="#16181b" />
          <circle cx={cx} cy="20.4" r="4.1" fill={red ? "#e5484d" : "#b9bdc3"} />
          <circle cx={cx} cy="20.4" r={red ? 0.8 : amber ? 2.6 : 2} fill="#0b0c0e" />
          <circle cx={cx - 1.3} cy="19" r="0.6" fill="#ffffff" opacity="0.8" />
          {level === "green" && <path d={`M${cx - 4.9} 20.2 A4.9 4.9 0 0 1 ${cx + 4.9} 20.2 Z`} fill="#6f757d" />}
        </g>
      ))}

      {/* feather "brows": worried in check soon, angry in danger */}
      {amber && (
        <path d="M10.8 13.4 L20.6 10.8 L20.9 12.4 L11.3 14.8 Z M37.2 13.4 L27.4 10.8 L27.1 12.4 L36.7 14.8 Z" fill="#1f2226" />
      )}
      {red && (
        <path d="M10.4 10.4 L21 13.8 L20.6 15.3 L10.2 11.9 Z M37.6 10.4 L27 13.8 L27.4 15.3 L37.8 11.9 Z" fill="#1f2226" />
      )}

      {/* aviator sunglasses, every state */}
      <g ref={glasses} className="owl-glasses">
        <path d="M10.2 16.3 L6.4 15.1 M37.8 16.3 L41.6 15.1" stroke="#CFC6B0" strokeWidth="0.8" strokeLinecap="round" />
        <path d="M22.4 16.1 Q24 14.7 25.6 16.1" stroke="#CFC6B0" strokeWidth="0.7" fill="none" strokeLinecap="round" />
        <path d="M22.8 18.2 L25.2 18.2" stroke="#CFC6B0" strokeWidth="0.6" strokeLinecap="round" />
        <path d={LENS_L} fill={`url(#${uid}-lens)`} stroke="#CFC6B0" strokeWidth="0.6" strokeLinejoin="round" />
        <path d={LENS_R} fill={`url(#${uid}-lens)`} stroke="#CFC6B0" strokeWidth="0.6" strokeLinejoin="round" />
        {/* glints */}
        <path d="M12.3 19 L15 16.7" stroke="#ffffff" strokeWidth="0.65" strokeLinecap="round" opacity="0.85" />
        <path d="M27.7 19 L30.4 16.7" stroke="#ffffff" strokeWidth="0.65" strokeLinecap="round" opacity="0.85" />
        {/* red reflection streak: danger only, after the glasses settle; fades out when danger ends */}
        <g className={`owl-streak${red ? " on" : ""}`}>
          <path d="M14 24.4 L20.6 18.6" stroke="#e5484d" strokeWidth="0.5" strokeLinecap="round" />
          <path d="M29.6 24.4 L36.2 18.6" stroke="#e5484d" strokeWidth="0.5" strokeLinecap="round" />
        </g>
      </g>

      {/* scruffy chin feathers (goatee) and stubble */}
      <path d="M21.4 27 Q22 32 24 34 Q26 32 26.6 27 Q24 29.8 21.4 27 Z" fill="#26272c" />
      <path d="M22.6 29.6 L23.2 32.6 M24 30.2 L24 33.4 M25.4 29.6 L24.8 32.6" stroke="#44464d" strokeWidth="0.25" strokeLinecap="round" />
      {[[20.6, 26.4], [21.2, 27.8], [27.4, 26.4], [26.8, 27.8], [22.2, 29.6], [25.8, 29.6], [20.2, 25.2], [27.8, 25.2]].map(([x, y]) => (
        <circle key={`${x}-${y}`} cx={x} cy={y} r="0.2" fill="#34353b" />
      ))}

      {/* hooked beak */}
      <path d="M22.7 24.2 Q24 22.8 25.3 24.2 Q25.3 27 24 29.2 Q22.7 27 22.7 24.2 Z" fill="#b9b2a2" />
      <path d="M24 29.2 Q23.6 28.4 23.9 27.6" stroke="#4a4540" strokeWidth="0.35" fill="none" />

      {/* feathered feet with dark talons gripping the branch */}
      {[19.6, 28.4].map((x) => (
        <g key={x}>
          <ellipse cx={x} cy="43.4" rx="2.2" ry="1.1" fill="#7a7f87" />
          <path d={`M${x - 1.6} 43.8 q-0.6 1.2 -1.4 1.9 M${x - 0.4} 44 q-0.1 1.2 -0.5 2 M${x + 0.8} 43.9 q0.4 1.1 1.2 1.8`} stroke="#a8a092" strokeWidth="0.75" fill="none" strokeLinecap="round" />
          <path d={`M${x - 3} 45.7 l-0.4 0.5 M${x - 0.9} 46 l-0.2 0.6 M${x + 2} 45.7 l0.3 0.5`} stroke="#141517" strokeWidth="0.6" strokeLinecap="round" />
        </g>
      ))}
    </svg>
  );
}
