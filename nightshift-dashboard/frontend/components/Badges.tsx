import type { FlagStatus, FlagType, PriorityLevel } from "@/lib/types";

const STATUS: Record<FlagStatus, string> = {
  pending: "bg-amber-500/15 text-amber-300 ring-amber-500/40",
  confirmed: "bg-red-500/15 text-red-300 ring-red-500/40",
  dismissed: "bg-zinc-500/15 text-zinc-400 ring-zinc-500/40",
};

const TYPE: Record<FlagType, string> = {
  leak: "bg-sky-500/15 text-sky-300 ring-sky-500/40",
  smoke: "bg-zinc-300/15 text-zinc-200 ring-zinc-300/40",
  damage: "bg-orange-500/15 text-orange-300 ring-orange-500/40",
};

const LEVEL: Record<PriorityLevel, string> = {
  high: "bg-red-500/15 text-red-300 ring-red-500/40",
  medium: "bg-amber-500/15 text-amber-300 ring-amber-500/40",
  low: "bg-zinc-500/15 text-zinc-400 ring-zinc-500/40",
};

const base = "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium uppercase tracking-wide ring-1";

export function StatusBadge({ status }: { status: FlagStatus }) {
  return <span className={`${base} ${STATUS[status] ?? STATUS.pending}`}>{status}</span>;
}

export function TypeBadge({ type }: { type: FlagType }) {
  return <span className={`${base} ${TYPE[type] ?? TYPE.damage}`}>{type}</span>;
}

export function LevelBadge({ level }: { level: PriorityLevel }) {
  return <span className={`${base} ${LEVEL[level]}`}>{level}</span>;
}
