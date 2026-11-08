// All backend calls live here. The backend loads EOG's files; there is no demo fallback.

import type {
  AgentRun, DatasetInfo, Evidence, FacilityDetail, Flag, Handoff, Overview, Priority, Report, Risk, Shift, Timeline,
} from "./types";

export const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${API_URL}${path}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`${path}: ${res.status}`);
  return (await res.json()) as T;
}

const q = (params: Record<string, string | undefined>) => {
  const p = Object.entries(params).filter(([, v]) => v !== undefined) as [string, string][];
  return p.length ? `?${new URLSearchParams(p)}` : "";
};

export const getDatasets = () => get<DatasetInfo[]>("/datasets");
export const getOverview = (dataset: string, now?: number) => get<Overview>(`/overview${q({ dataset, now: now?.toString() })}`);
export const getFacility = (dataset: string, id: string, now?: number) =>
  get<FacilityDetail>(`/facilities/${id}${q({ dataset, now: now?.toString() })}`);
export const getTimeline = (dataset: string) => get<Timeline>(`/timeline${q({ dataset })}`);
export const getRisk = (dataset: string, now?: number, ai = true) =>
  get<Risk>(`/risk${q({ dataset, now: now?.toString(), ai: ai ? undefined : "false" })}`);

export const getEvidence = (dataset: string, now?: number, ai = true) =>
  get<Evidence>(`/evidence${q({ dataset, now: now?.toString(), ai: ai ? undefined : "false" })}`);

// Time travel for the phone and glasses too: they see this moment until it is cleared (null = latest data).
export async function setClock(dataset: string, now: number | null): Promise<void> {
  try {
    await fetch(`${API_URL}/clock`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ dataset, now }) });
  } catch {}
}
export const getShifts = (dataset: string) => get<Shift[]>(`/shifts${q({ dataset })}`);
export const getReport = (shiftId: string, now?: number) => get<Report>(`/report${q({ shift_id: shiftId, now: now?.toString() })}`);
export const getNextShift = (shiftId?: string, dataset?: string, now?: number) =>
  get<Priority[]>(`/next-shift${q({ shift_id: shiftId, dataset, now: now?.toString() })}`);
export const getAgentTrace = (dataset: string) => get<AgentRun>(`/agent/trace${q({ dataset })}`);
export const getHandoff = (dataset: string, now?: number) => get<Handoff>(`/handoff${q({ dataset, now: now?.toString() })}`);
export const getSeries = (dataset: string, asset: string, metric: string, hours: number) =>
  get<{ points: [number, number][] }>(`/series${q({ dataset, asset, metric, hours: String(hours) })}`);
export const eventsUrl = (dataset: string) => `${API_URL}/events.json${q({ dataset })}`;

export async function rerunAgent(dataset: string): Promise<AgentRun> {
  const res = await fetch(`${API_URL}/agent/run${q({ dataset })}`, { method: "POST" });
  return (await res.json()) as AgentRun;
}

// Confirm, dismiss or reopen a flag. Returns the updated flag, or null if it failed.
export async function setFlagStatus(flagId: string, action: "confirm" | "dismiss" | "reopen"): Promise<Flag | null> {
  try {
    const res = await fetch(`${API_URL}/flag/${flagId}/${action}`, { method: "POST" });
    if (!res.ok) throw new Error(`${res.status}`);
    return (await res.json()) as Flag;
  } catch {
    return null;
  }
}

// Replace a flag's photo with a new JPEG, or clear it. Return the updated flag, or null if it failed.
export async function replaceFlagPhoto(flagId: string, file: Blob): Promise<Flag | null> {
  try {
    const res = await fetch(`${API_URL}/flag/${flagId}/photo`, { method: "POST", headers: { "Content-Type": "image/jpeg" }, body: file });
    if (!res.ok) throw new Error(`${res.status}`);
    return (await res.json()) as Flag;
  } catch {
    return null;
  }
}

export async function clearFlagPhoto(flagId: string): Promise<Flag | null> {
  try {
    const res = await fetch(`${API_URL}/flag/${flagId}/photo`, { method: "DELETE" });
    if (!res.ok) throw new Error(`${res.status}`);
    return (await res.json()) as Flag;
  } catch {
    return null;
  }
}

// Control room adds a note to a flag. Returns the updated flag, or null if it failed.
export async function addControlNote(flagId: string, note: string): Promise<Flag | null> {
  try {
    const res = await fetch(`${API_URL}/flag/${flagId}/note`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ note, author: "control" }),
    });
    if (!res.ok) throw new Error(`${res.status}`);
    return (await res.json()) as Flag;
  } catch {
    return null;
  }
}

export function photoSrc(url: string): string {
  if (!url) return "";
  return url.startsWith("http") ? url : `${API_URL}${url}`;
}

// All times in the data are UTC. Timestamps without a suffix are UTC too.
const asDate = (iso: string) => new Date(/[zZ]|[+-]\d\d:?\d\d$/.test(iso) || iso.length === 10 ? (iso.length === 10 ? `${iso}T12:00:00Z` : iso) : `${iso}Z`);
export const formatTime = (iso: string) =>
  asDate(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: "UTC" });
export const formatDate = (iso: string) =>
  asDate(iso).toLocaleDateString([], { month: "short", day: "numeric", timeZone: "UTC" });
export const formatDateTime = (iso: string) => `${formatDate(iso)}, ${formatTime(iso)} UTC`;
export const unixToIso = (ts: number) => new Date(ts * 1000).toISOString();

export const money = (n: number) => `$${Math.round(n).toLocaleString()}`;
export const facName = (id: string) => id.replace("_FACILITY_", " Facility ").replace(/_/g, " ");
export const fmtHours = (h: number) => (h < 1 ? `${Math.round(h * 60)} min` : `${h.toFixed(1)} h`);
