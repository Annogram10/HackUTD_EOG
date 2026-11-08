"use client";

// Entry transition: horizontal glitch bars -> RGB-split logo with typed lines from the loaded data -> bars slide
// off and the dashboard shows. Original drawing code, no external assets.
// Plays on the first load of a browser session and when the dataset changes. Click or any key skips it.
// prefers-reduced-motion: a plain 300 ms fade instead.
// Safety: the backdrop stays dark the whole time (no full-screen bright flash); bright colours only on thin bars
// (~30% of them), so overall brightness stays roughly level from one redraw to the next.
// It draws straight to a canvas and never sets React state, so it cannot change data or re-render the dashboard.

import { useEffect, useRef } from "react";
import { useApp } from "./AppProvider";

const SESSION_KEY = "nightshift.intro.played";
const P1 = 600; // bars
const P2 = 1100; // logo + typed lines, bars thin out
const END = 1500; // bars slide off, overlay removed
const STEP = 70; // bars are re-drawn every ~70 ms
const BACKDROP = "#05061a";
const DARK = ["#0A0F3C", "#000000", "#0A0F3C", "#1B2BFF"];
const BRIGHT = ["#FF2BD6", "#19E6FF", "#FFD319", "#4BFF6B"];

interface Bar {
  y: number;
  h: number;
  x: number;
  w: number;
  color: string;
  stripe: string | null; // thin inner lines, like a corrupted video row
  alpha: number;
  dir: number; // which way it slides off in phase 3
}

const rand = (a: number, b: number) => a + Math.random() * (b - a);
const pick = <T,>(xs: T[]) => xs[Math.floor(Math.random() * xs.length)];

function makeBars(n: number, W: number, H: number): Bar[] {
  return Array.from({ length: n }, () => {
    const bright = Math.random() < 0.3;
    const w = W * rand(0.3, 1);
    return {
      y: rand(0, H),
      h: bright ? rand(2, 14) : rand(2, 40), // bright bars stay thin
      x: rand(-0.2 * W, W - w * 0.5),
      w,
      color: bright ? pick(BRIGHT) : pick(DARK),
      stripe: Math.random() < 0.35 ? pick(bright ? DARK : BRIGHT) : null,
      alpha: bright ? 0.8 : rand(0.7, 1),
      dir: Math.random() < 0.5 ? -1 : 1,
    };
  });
}

export default function GlitchIntro() {
  const { dataset, datasets, overview, risk } = useApp();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const data = useRef({ dataset, datasets, overview, risk });
  const prev = useRef<string | null>(null);

  // the typed lines read the latest loaded data on every frame
  useEffect(() => {
    data.current = { dataset, datasets, overview, risk };
  });

  useEffect(() => {
    if (!dataset || prev.current === dataset) return;
    const before = prev.current;
    prev.current = dataset;
    let played = false;
    try {
      played = sessionStorage.getItem(SESSION_KEY) === "1";
    } catch {}
    if (before === null && played) return; // already seen in this browser session

    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = window.innerWidth;
    const H = window.innerHeight;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    canvas.style.display = "block";
    canvas.style.opacity = "1";
    canvas.style.transition = "";

    let raf = 0;
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      try {
        sessionStorage.setItem(SESSION_KEY, "1");
      } catch {}
      cancelAnimationFrame(raf);
      window.removeEventListener("keydown", finish);
      canvas.removeEventListener("pointerdown", finish);
      canvas.style.display = "none";
    };
    window.addEventListener("keydown", finish);
    canvas.addEventListener("pointerdown", finish);

    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      ctx.fillStyle = BACKDROP;
      ctx.fillRect(0, 0, W, H);
      requestAnimationFrame(() => {
        canvas.style.transition = "opacity 300ms linear";
        canvas.style.opacity = "0";
      });
      const t = setTimeout(finish, 320);
      return () => {
        clearTimeout(t);
        if (!done) prev.current = before; // interrupted (dev double-run): let the next run play it
        finish();
      };
    }

    const font = getComputedStyle(document.body).fontFamily;
    const mono = getComputedStyle(document.documentElement).getPropertyValue("--font-plex-mono") || "monospace";
    const N = Math.round(Math.max(60, H / 9));
    let bars = makeBars(N, W, H);
    let lastStep = 0;
    let slide: Bar[] | null = null;
    let jitter = { r: 3, c: 3, y: 0 };
    const start = performance.now();

    const lines = () => {
      const d = data.current;
      const info = d.datasets.find((x) => x.name === d.dataset);
      const ov = d.overview && d.overview.dataset === d.dataset ? d.overview : null;
      const ai = d.risk?.ai;
      const engine = ai?.available ? "NEMOTRON: ONLINE" : ai && !ai.pending ? "NEMOTRON: OFFLINE · RULES ONLINE" : "RULES: ONLINE · NEMOTRON: STANDBY";
      return [
        "AVON GRID // LINK ESTABLISHED",
        `SYSTEMS: ${info?.systems ?? "…"} · FACILITIES: ${info?.facilities ?? "…"} · ALERTS: ${ov ? ov.alerts.length : "…"}`,
        engine,
      ];
    };

    const drawBars = (list: Bar[], dx = 0) => {
      for (const b of list) {
        ctx.globalAlpha = b.alpha;
        ctx.fillStyle = b.color;
        const x = b.x + dx * b.dir;
        ctx.fillRect(x, b.y, b.w, b.h);
        if (b.stripe && b.h > 6) {
          ctx.fillStyle = b.stripe;
          for (let y = b.y + 2; y < b.y + b.h - 1; y += 5) ctx.fillRect(x + b.w * 0.1, y, b.w * 0.6, 1);
        }
      }
      ctx.globalAlpha = 1;
    };

    const drawLogo = (t: number, fade: number) => {
      const size = Math.min(96, W / 7);
      ctx.font = `700 ${size}px ${font}`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      const cx = W / 2;
      const cy = H / 2 - 30;
      ctx.globalAlpha = 0.85 * fade;
      ctx.fillStyle = "#FF2B4B";
      ctx.fillText("NightShift", cx - jitter.r, cy + jitter.y);
      ctx.fillStyle = "#19E6FF";
      ctx.fillText("NightShift", cx + jitter.c, cy - jitter.y);
      ctx.globalAlpha = fade;
      ctx.fillStyle = "#ECEEF1";
      ctx.fillText("NightShift", cx, cy);

      // typed lines: characters appear across phase 2
      const typed = Math.max(0, (t - P1) / (P2 - P1 - 100));
      ctx.font = `500 ${Math.min(18, W / 34)}px ${mono}, monospace`;
      lines().forEach((line, i) => {
        const shown = Math.floor(Math.min(1, typed * 1.4 - i * 0.25) * line.length);
        if (shown <= 0) return;
        ctx.fillStyle = i === 0 ? "#19E6FF" : i === 2 ? "#4BFF6B" : "#C8CCD2";
        ctx.fillText(line.slice(0, shown) + (shown < line.length ? "▌" : ""), cx, cy + size * 0.75 + i * 28);
      });
      ctx.globalAlpha = 1;
    };

    const frame = (now: number) => {
      if (done) return;
      const t = now - start;
      if (t >= END) return finish();
      ctx.clearRect(0, 0, W, H);

      if (t < P2) {
        if (now - lastStep >= STEP) {
          lastStep = now;
          // phase 2: fewer bars every redraw
          const n = t < P1 ? N : Math.round(N * (1 - (t - P1) / (P2 - P1)) * 0.85 + 8);
          bars = makeBars(n, W, H);
          jitter = { r: rand(2, 4), c: rand(2, 4), y: rand(-1.5, 1.5) };
        }
        ctx.fillStyle = BACKDROP; // dark backdrop throughout: no bright full-screen flash
        ctx.fillRect(0, 0, W, H);
        drawBars(bars);
        if (t >= P1) drawLogo(t, 1);
      } else {
        // phase 3: the dashboard is visible; the last bars slide off sideways
        if (!slide) slide = bars;
        const p = (t - P2) / (END - P2);
        const eased = p * p;
        ctx.globalAlpha = 1 - p;
        ctx.fillStyle = BACKDROP;
        ctx.fillRect(0, 0, W, H);
        ctx.globalAlpha = 1;
        drawBars(slide, eased * W * 1.3);
        if (p < 0.4) drawLogo(t, 1 - p / 0.4);
      }
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
    return () => {
      if (!done) prev.current = before; // interrupted (dev double-run): let the next run play it
      finish();
    };
  }, [dataset]);

  return (
    <canvas
      ref={canvasRef}
      aria-hidden
      title="Click or press any key to skip"
      className="fixed inset-0 z-[60] h-full w-full cursor-pointer"
      style={{ display: "none" }}
    />
  );
}
