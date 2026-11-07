// All backend calls live here. If the backend is down, each helper falls back
// to the fake JSON so the dashboard always shows something.

import fakeFlags from "@/data/flags.json";
import fakeHistory from "@/data/history.json";
import { buildPriorities, buildReport } from "./fallback";
import type { Flag, Priority, Report, Result } from "./types";

export const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

const tonight = fakeFlags as Flag[];
const history = fakeHistory as Flag[];

async function get<T>(path: string, fallback: () => T): Promise<Result<T>> {
  try {
    const res = await fetch(`${API_URL}${path}`, { cache: "no-store" });
    if (!res.ok) throw new Error(`${res.status}`);
    return { data: (await res.json()) as T, live: true };
  } catch {
    return { data: fallback(), live: false };
  }
}

export const getFlags = () => get<Flag[]>("/flags", () => tonight);
export const getReport = () => get<Report>("/report", () => buildReport(tonight));
export const getNextShift = () =>
  get<Priority[]>("/next-shift", () => buildPriorities(tonight, history));

// Photos are served by the backend at /photos/...; full URLs pass through.
export function photoSrc(url: string): string {
  if (!url) return "";
  return url.startsWith("http") ? url : `${API_URL}${url}`;
}

export function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

export function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString([], { month: "short", day: "numeric" });
}
