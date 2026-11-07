import type { Category, FacilityStatus, FlagStatus, FlagType, PriorityLevel, Trigger } from "@/lib/types";

const STATUS: Record<FlagStatus, string> = {
  pending: "bg-amber-500/15 text-amber-300 ring-amber-500/40",
  confirmed: "bg-red-500/15 text-red-300 ring-red-500/40",
  dismissed: "bg-zinc-500/15 text-zinc-400 ring-zinc-500/40",
};
const STATUS_LABEL: Record<FlagStatus, string> = { pending: "Needs review", confirmed: "Confirmed", dismissed: "Dismissed" };
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
const CATEGORY: Record<Category, { label: string; cls: string }> = {
  pump_failure: { label: "Pump failure", cls: "bg-red-500/15 text-red-300 ring-red-500/40" },
  pipeline_leak: { label: "Possible pipeline leak", cls: "bg-orange-500/15 text-orange-300 ring-orange-500/40" },
  pump_degradation: { label: "Pump wearing out", cls: "bg-amber-500/15 text-amber-300 ring-amber-500/40" },
};
export const FAC_STATUS: Record<FacilityStatus, { label: string; cls: string }> = {
  ok: { label: "Normal", cls: "bg-emerald-500/15 text-emerald-300 ring-emerald-500/40" },
  worn: { label: "Pump wearing out", cls: CATEGORY.pump_degradation.cls },
  leak: { label: "Possible leak", cls: CATEGORY.pipeline_leak.cls },
  failure: { label: "Pump failure", cls: CATEGORY.pump_failure.cls },
  tripped: { label: "Tank tripped, wells shut in", cls: "bg-red-600/25 text-red-200 ring-red-500/60" },
};

const base = "inline-flex items-center rounded-full px-3 py-1 text-sm font-medium ring-1";

export const StatusBadge = ({ status }: { status: FlagStatus }) => (
  <span className={`${base} ${STATUS[status] ?? STATUS.pending}`}>{STATUS_LABEL[status] ?? status}</span>
);
export const TypeBadge = ({ type }: { type: FlagType }) => (
  <span className={`${base} ${TYPE[type] ?? TYPE.damage}`}>Possible {type}</span>
);
export const LevelBadge = ({ level }: { level: PriorityLevel }) => (
  <span className={`${base} uppercase ${LEVEL[level]}`}>{level}</span>
);
export const CategoryBadge = ({ category }: { category: Category }) => (
  <span className={`${base} ${CATEGORY[category].cls}`}>{CATEGORY[category].label}</span>
);
export const FacStatusBadge = ({ status }: { status: FacilityStatus }) => (
  <span className={`${base} ${FAC_STATUS[status].cls}`}>{FAC_STATUS[status].label}</span>
);
export const TriggerBadge = ({ trigger }: { trigger: Trigger }) => (
  <span className={`${base} bg-violet-500/15 text-violet-300 ring-violet-500/40`}>{trigger === "camera" ? "Camera" : "Data check"}</span>
);
