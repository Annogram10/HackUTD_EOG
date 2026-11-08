"use client";

// One polling loop for every live view: runs at once, then every `intervalMs` AFTER the previous request finished
// (never two at a time), aborts on unmount or when `key` changes, and pauses while the tab is hidden.

import { useEffect, useRef } from "react";

export function usePoll(
  key: string | null,
  fn: (signal: AbortSignal) => Promise<unknown>,
  intervalMs: number,
  onResult?: (ok: boolean) => void,
) {
  const fnRef = useRef(fn);
  const onRef = useRef(onResult);
  useEffect(() => {
    fnRef.current = fn;
    onRef.current = onResult;
  });

  useEffect(() => {
    if (key === null) return;
    let stopped = false;
    let running = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let ctrl: AbortController | undefined;

    const schedule = () => {
      if (stopped) return;
      clearTimeout(timer);
      timer = setTimeout(tick, intervalMs);
    };
    async function tick() {
      if (stopped || running) return;
      if (document.visibilityState === "hidden") return schedule();
      running = true;
      ctrl = new AbortController();
      try {
        await fnRef.current(ctrl.signal);
        if (!stopped) onRef.current?.(true);
      } catch {
        if (!stopped && !ctrl.signal.aborted) onRef.current?.(false);
      } finally {
        running = false;
        schedule();
      }
    }
    const onVisible = () => {
      if (document.visibilityState === "visible" && !running) {
        clearTimeout(timer);
        tick();
      }
    };
    tick();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      stopped = true;
      clearTimeout(timer);
      ctrl?.abort();
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [key, intervalMs]);
}
