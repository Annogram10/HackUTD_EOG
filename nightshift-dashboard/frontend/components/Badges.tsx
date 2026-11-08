import { WarningIcon } from "./Icons";
import type { Category, FacilityStatus, FlagStatus, FlagType, PriorityLevel, Severity, Trigger } from "@/lib/types";

const STATUS: Record<FlagStatus, string> = {
  pending: "bg-amber-500/15 text-amber-300 ring-amber-500/40",
  confirmed: "bg-red-500/15 text-red-300 ring-red-500/40",
  dismissed: "bg-zinc-500/15 text-zinc-400 ring-zinc-500/40",
};
const STATUS_LABEL: Record<FlagStatus, string> = { pending: "Needs review", confirmed: "Confirmed", dismissed: "Dismissed" };
const TYPE: Record<FlagType, string> = {
  leak: "bg-zinc-800 text-zinc-200 ring-zinc-600",
  smoke: "bg-zinc-800 text-zinc-200 ring-zinc-600",
  damage: "bg-zinc-800 text-zinc-200 ring-zinc-600",
  alarm: "bg-red-500/15 text-red-300 ring-red-500/50",
};
const LEVEL: Record<PriorityLevel, string> = {
  high: "bg-red-500/15 text-red-300 ring-red-500/40",
  medium: "bg-amber-500/15 text-amber-300 ring-amber-500/40",
  low: "bg-zinc-500/15 text-zinc-400 ring-zinc-500/40",
};
const CATEGORY: Record<Category, { label: string; cls: string }> = {
  pump_failure: { label: "Pump failure", cls: "bg-red-500/15 text-red-300 ring-red-500/40" },
  pipeline_leak: { label: "Possible pipeline leak", cls: "bg-amber-500/15 text-amber-300 ring-amber-500/40" },
  pump_degradation: { label: "Pump wearing out", cls: "bg-amber-500/15 text-amber-300 ring-amber-500/40" },
};
export const FAC_STATUS: Record<FacilityStatus, { label: string; cls: string }> = {
  ok: { label: "Normal", cls: "bg-emerald-500/15 text-emerald-300 ring-emerald-500/40" },
  worn: { label: "Pump wearing out", cls: CATEGORY.pump_degradation.cls },
  leak: { label: "Possible leak", cls: CATEGORY.pipeline_leak.cls },
  failure: { label: "Pump failure", cls: CATEGORY.pump_failure.cls },
  tripped: { label: "Tank tripped, wells shut in", cls: "bg-red-600/25 text-red-200 ring-red-500/60" },
};

const base = "inline-flex items-center px-2.5 py-0.5 text-sm font-medium ring-1";

// Severity: colour + an icon + a word, so it never depends on colour alone.
export const SEVERITY: Record<Severity | "none", { label: string; cls: string; tone: "red" | "amber" | "ok" }> = {
  high: { label: "Danger", cls: "bg-red-500 text-zinc-950 ring-red-500 danger-pulse", tone: "red" },
  medium: { label: "Check soon", cls: "bg-amber-500/15 text-amber-300 ring-amber-500/40", tone: "amber" },
  low: { label: "Minor", cls: "bg-zinc-800 text-zinc-300 ring-zinc-600", tone: "ok" },
  none: { label: "Normal", cls: "bg-emerald-500/15 text-emerald-300 ring-emerald-500/40", tone: "ok" },
};
// Look up a severity safely: an older backend (or a missing field) shows as "Normal" instead of crashing the page.
export const sevInfo = (s: string | null | undefined) => SEVERITY[(s ?? "none") as Severity | "none"] ?? SEVERITY.none;
export const SeverityBadge = ({ severity }: { severity?: Severity | "none" | null }) => (
  <span className={`${base} gap-1.5 font-semibold uppercase ${sevInfo(severity).cls}`}>
    {(severity === "high" || severity === "medium") && <WarningIcon />}
    {sevInfo(severity).label}
  </span>
);

export const StatusBadge = ({ status }: { status: FlagStatus }) => (
  <span className={`${base} ${STATUS[status] ?? STATUS.pending}`}>{STATUS_LABEL[status] ?? status}</span>
);
export const TypeBadge = ({ type }: { type: FlagType }) => (
  <span className={`${base} ${TYPE[type] ?? TYPE.damage}`}>{type === "alarm" ? "Alarm" : `Possible ${type}`}</span>
);
export const LevelBadge = ({ level }: { level: PriorityLevel }) => (
  <span className={`${base} gap-1.5 uppercase ${LEVEL[level]}`}>
    {level !== "low" && <WarningIcon />}
    {level}
  </span>
);
// What kind of problem it is. Neutral: how bad it is shows in the SeverityBadge next to it.
export const CategoryBadge = ({ category }: { category: Category }) => (
  <span className={`${base} bg-zinc-800 text-zinc-200 ring-zinc-600`}>{CATEGORY[category].label}</span>
);
// A facility's status, coloured by the backend's severity.
export const FacStatusBadge = ({ status, severity }: { status: FacilityStatus; severity?: Severity | "none" | null }) => (
  <span className={`${base} ${sevInfo(severity).cls}`}>
    {FAC_STATUS[status].label}{severity === "low" ? ", minor" : ""}
  </span>
);
export const TriggerBadge = ({ trigger }: { trigger: Trigger }) => (
  <span className={`${base} bg-zinc-800 text-zinc-300 ring-zinc-600`}>{trigger === "camera" ? "Camera" : trigger === "voice" ? "Voice" : "Data check"}</span>
);
