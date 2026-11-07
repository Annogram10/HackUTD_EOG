// Builds the report and next-shift priorities from the fake JSON, so the
// dashboard works before the backend exists. Same rules as backend/main.py.

import type { Flag, Priority, PriorityLevel, Report } from "./types";

export const TYPE_WEIGHT: Record<string, number> = { smoke: 30, leak: 20, damage: 10 };

export function buildReport(tonight: Flag[]): Report {
  const by_type: Record<string, number> = {};
  for (const f of tonight) by_type[f.type] = (by_type[f.type] ?? 0) + 1;

  const sorted = [...tonight].sort((a, b) => b.timestamp.localeCompare(a.timestamp));
  const count = (s: Flag["status"]) => tonight.filter((f) => f.status === s).length;

  return {
    shift_start: sorted.at(-1)?.timestamp ?? new Date().toISOString(),
    generated_at: new Date().toISOString(),
    totals: {
      total: tonight.length,
      confirmed: count("confirmed"),
      pending: count("pending"),
      dismissed: count("dismissed"),
    },
    by_type,
    confirmed: sorted.filter((f) => f.status === "confirmed"),
    pending: sorted.filter((f) => f.status === "pending"),
    notes: sorted
      .filter((f) => f.note)
      .map((f) => ({ location: f.location, note: f.note as string, timestamp: f.timestamp })),
  };
}

export function levelFor(score: number): PriorityLevel {
  if (score >= 60) return "high";
  if (score >= 30) return "medium";
  return "low";
}

export function buildPriorities(tonight: Flag[], history: Flag[]): Priority[] {
  const locations = new Set([...tonight, ...history].map((f) => f.location));
  const out: Priority[] = [];

  for (const loc of locations) {
    const now = tonight.filter((f) => f.location === loc && f.status !== "dismissed");
    const past = history.filter((f) => f.location === loc && f.status !== "dismissed");
    if (now.length === 0 && past.length === 0) continue;

    let score = 0;
    const reasons: string[] = [];

    const confirmed = now.filter((f) => f.status === "confirmed");
    const pending = now.filter((f) => f.status === "pending");
    if (confirmed.length) {
      score += 50;
      reasons.push(`Confirmed ${confirmed[0].type} tonight`);
    }
    if (pending.length) {
      score += 25;
      reasons.push(`Unreviewed ${pending[0].type} flag from tonight`);
    }

    const all = [...now, ...past];
    const worst = Math.max(...all.map((f) => TYPE_WEIGHT[f.type] ?? 0));
    score += worst;
    if (worst === TYPE_WEIGHT.smoke) reasons.push("Smoke is the highest-severity flag type");

    const pastNights = new Set(past.map((f) => f.timestamp.slice(0, 10))).size;
    if (pastNights > 0) {
      score += 10 * pastNights;
      reasons.push(`Flagged ${pastNights} previous night${pastNights > 1 ? "s" : ""}, repeat issue`);
    }

    const latest = [...all].sort((a, b) => b.timestamp.localeCompare(a.timestamp))[0] ?? null;
    out.push({ location: loc, score, level: levelFor(score), reasons, latest_flag: latest });
  }

  return out.sort((a, b) => b.score - a.score);
}
