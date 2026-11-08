"use client";

// The owl as a working part of the screen, not decoration. One bubble at a time, always with an action, always
// dismissable. It never covers numbers, buttons or card text: at home it sits in the bottom-right corner (pages
// leave room for it), and in danger it perches on the danger card's top-right corner, over a gutter the card keeps
// free, with its bubble rendered inside the card's own layout.
//   * Danger: wings out + the shades hop, then it flies to the danger card and says what is wrong (from the data)
//     with [Show plan]. Acknowledge or x: it nods and flies home.
//   * It turns its head toward the most urgent thing (countdown, map facility with the least time, or the system tab).
//   * Click it or press "O": it reads the summary aloud (same wording as the glasses).
//   * While the triage agent runs it holds a clipboard with the step; when done, thumbs up and a link to the trace.
// Reduced motion: no flying or hopping, it simply appears next to its target.

import { usePathname, useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { getAgentTrace } from "@/lib/api";
import { dangerLine, spokenSummary } from "@/lib/speak";
import type { AgentRun } from "@/lib/types";
import { useApp } from "./AppProvider";
import Owl from "./Owl";

const HIDE_KEY = "nightshift.owl.hidden";
const HOP_MS = 1900; // the shades hop before it flies
const FLY_MS = 900;
const HOME = 60; // owl size at home (in the top bar)
const PERCH = 72; // owl size on the danger card
const WORKFLOW = ["load_dataset", "detect_events", "forecast_shutdown", "optimize_plan", "get_fleet_status", "get_weather", "save_alerts", "export_events"];

// "Hide owl" lives in localStorage; read it without a hydration mismatch.
const listeners = new Set<() => void>();
const hiddenStore = {
  subscribe: (cb: () => void) => { listeners.add(cb); return () => listeners.delete(cb); },
  get: () => { try { return localStorage.getItem(HIDE_KEY) === "1"; } catch { return false; } },
  set: (v: boolean) => { try { localStorage.setItem(HIDE_KEY, v ? "1" : "0"); } catch {} listeners.forEach((l) => l()); },
};

const reduceMotion = () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

type Bubble = { kind: string; text: string; action?: { label: string; run: () => void } };

export default function OwlBuddy() {
  const { riskLevel, overview, dataset, alarmId, acked } = useApp();
  const path = usePathname();
  const router = useRouter();
  const hidden = useSyncExternalStore(hiddenStore.subscribe, hiddenStore.get, () => false);
  const level = riskLevel ?? "green";

  const [speaking, setSpeaking] = useState(false);
  const [speechNote, setSpeechNote] = useState<string | null>(null);
  const [dismissedAlarm, setDismissedAlarm] = useState<string | null>(null);
  const [flyFor, setFlyFor] = useState<string | null>(null); // the alarm the owl has flown out for
  const [nod, setNod] = useState(false);
  const [look, setLook] = useState(0);
  const [geo, setGeo] = useState<{ home: DOMRect | null; card: DOMRect | null; slot: HTMLElement | null; homeSlot: HTMLElement | null; bar: number }>({ home: null, card: null, slot: null, homeSlot: null, bar: 0 });
  const [flying, setFlying] = useState(false);
  const [agent, setAgent] = useState<{ dataset: string; run: AgentRun } | null>(null);
  const [agentSeen, setAgentSeen] = useState<string | null>(null); // run already acknowledged ("done" bubble dismissed)
  const box = useRef<HTMLDivElement>(null);

  // ---------- danger: hop, then fly to the card ----------
  const dangerActive = !!alarmId && !acked && dismissedAlarm !== alarmId;
  useEffect(() => {
    if (!dangerActive || !alarmId) return;
    const t = setTimeout(() => {
      setFlying(!reduceMotion());
      setFlyFor(alarmId);
      setTimeout(() => setFlying(false), FLY_MS + 50);
    }, reduceMotion() ? 0 : HOP_MS);
    return () => clearTimeout(t);
  }, [dangerActive, alarmId]);
  // leaving danger (acknowledged, dismissed, or over): nod, then fly home
  const wasDanger = useRef(false);
  useEffect(() => {
    if (wasDanger.current && !dangerActive) {
      const a = setTimeout(() => { setNod(true); setFlying(!reduceMotion()); }, 0);
      const b = setTimeout(() => { setNod(false); setFlying(false); }, 900);
      wasDanger.current = false;
      return () => { clearTimeout(a); clearTimeout(b); };
    }
    wasDanger.current = dangerActive;
  }, [dangerActive]);

  // ---------- where things are (card, bubble slot, window) and where to look ----------
  useEffect(() => {
    let raf = 0;
    const measure = () => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const card = document.getElementById("danger-card");
        const slot = document.getElementById("owl-slot");
        const homeSlot = document.getElementById("owl-home-bubble");
        const near = (a: DOMRect | null, b: DOMRect | null) => (a && b ? Math.abs(a.top - b.top) < 0.5 && Math.abs(a.left - b.left) < 0.5 && Math.abs(a.right - b.right) < 0.5 : a === b);
        setGeo((g) => {
          const r = card?.getBoundingClientRect() ?? null;
          const homeEl = document.getElementById("owl-home");
          const h = homeEl?.getBoundingClientRect() ?? null;
          const bar = Math.round(homeEl?.closest(".sticky")?.getBoundingClientRect().bottom ?? 0);
          return near(r, g.card) && near(h, g.home) && g.slot === slot && g.homeSlot === homeSlot && g.bar === bar ? g : { home: h, card: r, slot, homeSlot, bar };
        });
        // gaze: the countdown when perched, else the most urgent map facility, else the system tab with a problem
        const me = box.current?.getBoundingClientRect();
        let target: Element | null = document.querySelector("[data-countdown]");
        if (!document.querySelector("[data-owl-perched]")) {
          const chips = [...document.querySelectorAll<HTMLElement>("[data-fac-hours]")].filter((e) => e.dataset.facHours);
          chips.sort((a, b) => Number(a.dataset.facHours) - Number(b.dataset.facHours));
          target = chips[0] ?? document.querySelector("[data-system-bad]");
        }
        if (me && target) {
          const t = target.getBoundingClientRect();
          const dx = t.left + t.width / 2 - (me.left + me.width / 2);
          const dy = t.top + t.height / 2 - (me.top + me.height * 0.35);
          const deg = Math.max(-35, Math.min(35, (Math.atan2(dx, Math.max(120, Math.abs(dy))) * 180) / Math.PI));
          setLook((l) => (Math.abs(l - deg) > 2 ? deg : l));
        } else setLook((l) => (l === 0 ? l : 0));
      });
    };
    measure();
    window.addEventListener("scroll", measure, { passive: true });
    window.addEventListener("resize", measure);
    const id = setInterval(measure, 600);
    return () => { window.removeEventListener("scroll", measure); window.removeEventListener("resize", measure); clearInterval(id); cancelAnimationFrame(raf); };
  }, [path]);

  // perch only while the card's top edge is in view below the sticky bar; otherwise wait at home
  const perched = dangerActive && flyFor === alarmId && !!geo.card && path === "/" && geo.card.top > geo.bar + 24;

  // ---------- speak the summary ----------
  const alerts = useMemo(() => (overview && overview.dataset === dataset ? overview.alerts : []), [overview, dataset]);
  const toggleSpeak = useCallback(() => {
    const synth = typeof window !== "undefined" ? window.speechSynthesis : undefined;
    if (!synth) { setSpeechNote("Reading aloud is not available in this browser."); return; }
    if (synth.speaking) { synth.cancel(); setSpeaking(false); return; }
    const u = new SpeechSynthesisUtterance(spokenSummary(alerts));
    u.rate = 1;
    u.onend = () => setSpeaking(false);
    u.onerror = () => setSpeaking(false);
    setSpeechNote(null);
    setSpeaking(true);
    synth.speak(u);
  }, [alerts]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "o" && e.key !== "O") return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target as HTMLElement | null;
      if (t && (t.isContentEditable || ["INPUT", "SELECT", "TEXTAREA"].includes(t.tagName))) return;
      if (hiddenStore.get()) return;
      toggleSpeak();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleSpeak]);
  useEffect(() => () => { try { window.speechSynthesis?.cancel(); } catch {} }, []);

  // ---------- triage agent progress ----------
  useEffect(() => {
    if (!dataset) return;
    let alive = true;
    let timer: ReturnType<typeof setTimeout>;
    const check = () => {
      getAgentTrace(dataset)
        .then((run) => {
          if (!alive) return;
          setAgent({ dataset, run });
          if (run.status === "running") timer = setTimeout(check, 1500);
        })
        .catch(() => {});
    };
    check();
    return () => { alive = false; clearTimeout(timer); };
  }, [dataset]);
  const run = agent && agent.dataset === dataset ? agent.run : null;
  const runKey = run ? `${run.dataset}:${run.steps.length}:${run.status}` : null;
  const tools = run ? run.steps.filter((s) => s.kind === "tool") : [];
  const doneTools = new Set(tools.map((s) => s.tool));
  const savedAlerts = (() => {
    const saved = tools.find((s) => s.tool === "save_alerts");
    const m = saved?.result?.match(/"alerts":\s*(\d+)/);
    return m ? Number(m[1]) : alerts.length;
  })();

  // ---------- the one bubble ----------
  const showPlan = () => {
    const go = () => {
      document.documentElement.dataset.focus = "1";
      const el = document.querySelector(".first-plan") ?? document.getElementById("plan");
      el?.scrollIntoView({ behavior: reduceMotion() ? "auto" : "smooth", block: "center" });
    };
    if (path === "/") go();
    else { router.push("/#plan"); setTimeout(go, 600); }
  };
  const top = alerts.filter((a) => a.severity === "high").sort((a, b) => a.order - b.order)[0];
  let bubble: Bubble | null = null;
  if (dangerActive && (flyFor === alarmId || reduceMotion()) && top) {
    bubble = { kind: "danger", text: dangerLine(top), action: { label: "Show plan", run: showPlan } };
  } else if (speaking) {
    bubble = { kind: "speak", text: "Reading the summary aloud.", action: { label: "Stop", run: toggleSpeak } };
  } else if (speechNote) {
    bubble = { kind: "note", text: speechNote, action: { label: "OK", run: () => setSpeechNote(null) } };
  } else if (run?.status === "running" && agentSeen !== runKey) {
    const last = tools.at(-1)?.tool;
    bubble = { kind: "agent", text: `Agent working: step ${Math.min(doneTools.size, WORKFLOW.length) || 1} of ${WORKFLOW.length}, ${last ? last.replace(/_/g, " ") : "starting"}...`,
      action: { label: "Open How it decided", run: () => router.push("/agent") } };
  } else if (run?.status === "done" && agentSeen !== `${run.dataset}:done` && path !== "/agent") {
    bubble = { kind: "done", text: `Triage done. ${savedAlerts} alert${savedAlerts === 1 ? "" : "s"} saved.`, action: { label: "Open How it decided", run: () => router.push("/agent") } };
  }
  const dismiss = () => {
    if (!bubble) return;
    if (bubble.kind === "danger") setDismissedAlarm(alarmId);
    else if (bubble.kind === "speak") toggleSpeak();
    else if (bubble.kind === "note") setSpeechNote(null);
    else if (bubble.kind === "agent") setAgentSeen(runKey);
    else if (bubble.kind === "done" && run) setAgentSeen(`${run.dataset}:done`);
  };

  if (hidden)
    return geo.home ? (
      <button type="button" onClick={() => hiddenStore.set(false)} style={{ left: geo.home.right - 96, top: geo.home.top + 16 }}
        className="no-print fixed z-40 border border-zinc-700 bg-zinc-900 px-3 py-1 text-sm text-zinc-300 hover:text-zinc-100">
        Show owl
      </button>
    ) : null;

  // ---------- position: home corner, or perched on the danger card ----------
  const size = perched ? PERCH : HOME;
  const pos = perched && geo.card
    ? { left: geo.card.right - size - 14, top: geo.card.top - size * 0.62 }
    : geo.home ? { left: geo.home.left, top: geo.home.top + 2 } : { left: 0, top: 0 };
  const bubbleEl = bubble && (
    <div role="status" className={`owl-bubble ${bubble.kind === "danger" && geo.slot ? "" : "owl-bubble-home"}`} data-kind={bubble.kind}>
      <span aria-hidden className="owl-quote owl-quote-open">&ldquo;</span>
      <p className="pr-6 text-base text-zinc-100">{bubble.text}</p>
      <div className="mt-2 flex flex-wrap items-center gap-2">
        {bubble.action && (
          <button type="button" onClick={bubble.action.run} className="btn-primary px-3 py-1 text-sm font-semibold">{bubble.action.label}</button>
        )}
      </div>
      <button type="button" onClick={dismiss} aria-label="Dismiss" className="absolute right-1.5 top-1 px-1.5 text-lg leading-none text-zinc-400 hover:text-zinc-100">×</button>
      <span aria-hidden className="owl-quote owl-quote-close">&rdquo;</span>
    </div>
  );

  return (
    <>
      <div ref={box} data-owl-perched={perched ? "" : undefined}
        className={`no-print fixed z-40 flex items-center gap-2 ${flying ? "owl-flying" : ""} ${geo.home ? "" : "invisible"}`}
        style={{ left: pos.left, top: pos.top }}>
        {/* the agent's clipboard, or a thumbs up when it is done */}
        {run?.status === "running" && (
          <svg aria-hidden viewBox="0 0 24 30" className="owl-prop">
            <rect x="2" y="4" width="20" height="25" fill="#c9b8b0" stroke="#5a3a42" />
            <rect x="8" y="1.5" width="8" height="5" fill="#8e95b5" />
            <path d="M6 12h12M6 16h12M6 20h8" stroke="#5a3a42" strokeWidth="1.5" />
          </svg>
        )}
        {bubble?.kind === "done" && (
          <svg aria-hidden viewBox="0 0 24 24" className="owl-prop">
            <path d="M3 11h4v10H3z" fill="#c9b8b0" />
            <path d="M8 11l4-8c1.6 0 2.6 1.2 2.2 2.8L13.4 9H20c1.2 0 2 1 1.8 2.2l-1.4 7.6c-.2 1.2-1.1 2.2-2.4 2.2H8z" fill="#5dd39e" />
          </svg>
        )}
        <button type="button" onClick={toggleSpeak}
          aria-label={speaking ? "Stop reading the summary" : "Read the summary aloud (shortcut: O)"}
          className={`relative block shrink-0 ${speaking ? "owl-speaking" : ""}`} style={{ width: size }}>
          <Owl level={level} size={size} look={look} speaking={speaking} nod={nod} />
        </button>
        {!perched && (
          <div className="flex flex-col items-start leading-tight">
            <span className={`text-sm font-semibold ${level === "red" ? "text-red-300" : level === "amber" ? "text-amber-300" : "text-zinc-200"}`}>
              {{ green: "All normal", amber: "Check soon", red: "Danger" }[level]}
            </span>
            <button type="button" onClick={() => { try { window.speechSynthesis?.cancel(); } catch {} hiddenStore.set(true); }}
              className="text-sm text-zinc-400 underline-offset-2 hover:text-zinc-100 hover:underline">Hide owl</button>
          </div>
        )}
      </div>
      {/* the danger bubble always lives inside the danger card when it is on screen; other bubbles at home */}
      {(() => {
        const target = bubble?.kind === "danger" && geo.slot ? geo.slot : geo.homeSlot;
        return bubbleEl && target ? createPortal(bubbleEl, target) : null;
      })()}
    </>
  );
}
