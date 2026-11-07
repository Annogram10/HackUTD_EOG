// Shared data shapes. Must match the backend exactly.

export type FlagType = "leak" | "smoke" | "damage";
export type FlagStatus = "pending" | "confirmed" | "dismissed";

export interface Flag {
  id: string;
  type: FlagType;
  location: string;
  photo_url: string;
  timestamp: string; // ISO, e.g. "2026-11-08T02:14:00"
  status: FlagStatus;
  note?: string | null;
}

export interface Report {
  shift_start: string;
  generated_at: string;
  totals: { total: number; confirmed: number; pending: number; dismissed: number };
  by_type: Record<string, number>;
  confirmed: Flag[];
  pending: Flag[]; // unreviewed, carried to next shift
  notes: { location: string; note: string; timestamp: string }[];
}

export type PriorityLevel = "high" | "medium" | "low";

export interface Priority {
  location: string;
  score: number;
  level: PriorityLevel;
  reasons: string[];
  latest_flag: Flag | null;
}

// Shape returned by every api helper: the data, plus whether it came from the
// real backend (live) or the fake JSON fallback.
export interface Result<T> {
  data: T;
  live: boolean;
}
