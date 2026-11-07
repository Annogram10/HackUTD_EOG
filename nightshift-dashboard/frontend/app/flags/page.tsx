"use client";

// SHIFT FLAGS: every flag from the selected shift, with filters and control-room notes.

import { useState } from "react";
import FlagCard from "@/components/FlagCard";
import { useApp } from "@/components/AppProvider";
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
          className={`rounded-full px-4 py-1.5 text-base font-medium ring-1 transition-colors ${
            value === o.value
              ? "bg-zinc-100 text-zinc-950 ring-zinc-100"
              : "bg-zinc-900 text-zinc-300 ring-zinc-700 hover:bg-zinc-800"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export default function Flags() {
  const { shift, loading } = useApp();
  const [status, setStatus] = useState<StatusFilter>("all");
  const [type, setType] = useState<TypeFilter>("all");

  if (loading || !shift) return <div className="h-96 animate-pulse rounded-2xl bg-zinc-900" />;

  const sorted = [...shift.flags].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  const shown = sorted.filter((f) => (status === "all" || f.status === status) && (type === "all" || f.type === type));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-4xl font-bold">Flags: {formatDate(shift.date)} night</h1>
        <p className="mt-1 text-lg text-zinc-400">
          Each flag is something for a person to check. Showing {shown.length} of {shift.flags.length}.
        </p>
      </div>

      <div className="space-y-3">
        <Pills options={STATUSES} value={status} onChange={setStatus} />
        <Pills options={TYPES} value={type} onChange={setType} />
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
