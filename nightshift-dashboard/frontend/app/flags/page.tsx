"use client";

// SHIFT FLAGS: every flag from the selected shift, with filters and control-room notes.

import { useState } from "react";
import FlagCard from "@/components/FlagCard";
import { useApp } from "@/components/AppProvider";
import { PageSkeleton } from "@/components/Skeleton";
import { formatDate } from "@/lib/api";
import type { FlagStatus, FlagType } from "@/lib/types";

type StatusFilter = FlagStatus | "all";
type TypeFilter = FlagType | "all";

const STATUSES: { value: StatusFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "confirmed", label: "Confirmed" },
  { value: "pending", label: "Needs review" },
  { value: "dismissed", label: "Dismissed" },
];
const TYPES: { value: TypeFilter; label: string }[] = [
  { value: "all", label: "All types" },
  { value: "leak", label: "Possible leak" },
  { value: "smoke", label: "Possible smoke" },
  { value: "damage", label: "Possible damage" },
  { value: "alarm", label: "Alarm" },
];

function Pills<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (v: T) => void;
}) {
  return (
    <div className="flex flex-wrap gap-2">
      {options.map((o) => (
        <button
          key={o.value}
          onClick={() => onChange(o.value)}
          className={`px-4 py-1.5 text-base font-medium ring-1 ${
            value === o.value
              ? "bg-zinc-800 text-zinc-100 ring-sky-400"
              : "bg-zinc-900 text-zinc-300 ring-zinc-700 hover:bg-zinc-800"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

// "S5_FACILITY_C" -> "S5". Anything that is not a dataset facility id (e.g. a mock id) goes under "Other".
const systemOf = (equipmentId: string) => equipmentId.match(/^(S\d+)_/)?.[1] ?? "Other";

export default function Flags() {
  const { shift, loading, asOf } = useApp();
  const [status, setStatus] = useState<StatusFilter>("all");
  const [type, setType] = useState<TypeFilter>("all");
  const [system, setSystem] = useState<string>("all");

  if (loading) return <PageSkeleton cards={3} />;
  if (!shift)
    return (
      <div className="space-y-4">
        <h1 className="text-3xl font-bold">Flags</h1>
        <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-lg text-zinc-500">
          {asOf !== null ? "No shift had started yet at this time. " : "No phone report for this dataset yet. "}Flags the operator raises on the phone appear here after they end the shift.
        </div>
      </div>
    );

  const sorted = [...shift.flags].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  const systems = [...new Set(shift.flags.map((f) => systemOf(f.equipment_id)))].sort((a, b) =>
    a === "Other" ? 1 : b === "Other" ? -1 : a.localeCompare(b, undefined, { numeric: true }),
  );
  const systemOptions = [{ value: "all", label: "All systems" }, ...systems.map((x) => ({ value: x, label: x }))];
  const activeSystem = system === "all" || systems.includes(system) ? system : "all"; // the list changes with the shift
  const shown = sorted.filter(
    (f) =>
      (status === "all" || f.status === status) &&
      (type === "all" || f.type === type) &&
      (activeSystem === "all" || systemOf(f.equipment_id) === activeSystem),
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Flags: {formatDate(shift.date)} night</h1>
        <p className="mt-1 text-lg text-zinc-400">
          Each flag is something for a person to check. Showing {shown.length} of {shift.flags.length}.
        </p>
      </div>

      <div className="space-y-3">
        <Pills options={STATUSES} value={status} onChange={setStatus} />
        <Pills options={TYPES} value={type} onChange={setType} />
        <Pills options={systemOptions} value={activeSystem} onChange={setSystem} />
      </div>

      {shown.length === 0 ? (
        <div className="rounded-xl border border-dashed border-zinc-800 p-12 text-center text-lg text-zinc-500">
          {shift.flags.length === 0 ? "No flags this shift." : "No flags match these filters."}
        </div>
      ) : (
        <div className="space-y-4">
          {shown.map((f) => (
            <FlagCard key={f.id} flag={f} allowNote />
          ))}
        </div>
      )}
    </div>
  );
}
