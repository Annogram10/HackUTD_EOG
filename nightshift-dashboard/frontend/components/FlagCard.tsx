"use client";

import Link from "next/link";
import { useState } from "react";
import { addControlNote, formatDate, formatTime, photoSrc } from "@/lib/api";
import type { Flag } from "@/lib/types";
import { StatusBadge, TriggerBadge, TypeBadge } from "./Badges";
import { useApp } from "./AppProvider";

interface Props {
  flag: Flag;
  showDate?: boolean; // equipment timeline spans several nights
  allowNote?: boolean; // control room can add a note
  linkEquipment?: boolean;
}

export default function FlagCard({ flag, showDate = false, allowNote = false, linkEquipment = true }: Props) {
  const { patchFlag } = useApp();
  const [imgOk, setImgOk] = useState(Boolean(flag.photo_url));
  const [draft, setDraft] = useState("");
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [localNote, setLocalNote] = useState<string | null>(null); // used when backend is offline
  const dimmed = flag.status === "dismissed";
  const controlNote = localNote ?? flag.control_note;

  async function save() {
    const text = draft.trim();
    if (!text) return;
    setSaving(true);
    const updated = await addControlNote(flag.id, text);
    if (updated) patchFlag(updated);
    else setLocalNote(text); // demo mode: keep it on screen only
    setSaving(false);
    setEditing(false);
    setDraft("");
  }

  return (
    <article
      className={`flex flex-col gap-4 rounded-xl border border-zinc-800 bg-zinc-900 p-4 sm:flex-row ${
        dimmed ? "opacity-60" : ""
      }`}
    >
      <div className="h-36 w-full shrink-0 overflow-hidden rounded-lg bg-zinc-800 sm:w-52">
        {imgOk ? (
          // Plain <img> on purpose: photos come from the backend, no next/image config needed
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={photoSrc(flag.photo_url)}
            alt={`Possible ${flag.type} at ${flag.location}`}
            className="h-full w-full object-cover"
            onError={() => setImgOk(false)}
          />
        ) : (
          <div className="flex h-full items-center justify-center text-sm text-zinc-500">No photo</div>
        )}
      </div>

      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <StatusBadge status={flag.status} />
          <TypeBadge type={flag.type} />
          <TriggerBadge trigger={flag.trigger} />
        </div>

        <h3 className="text-xl font-semibold text-zinc-100">
          {linkEquipment ? (
            <Link href={`/facility/${flag.equipment_id}`} className="hover:text-amber-300 hover:underline">
              {flag.location}
            </Link>
          ) : (
            flag.location
          )}
          <span className="ml-3 text-base font-normal text-zinc-500">
            {showDate && `${formatDate(flag.timestamp)}, `}
            {formatTime(flag.timestamp)}
          </span>
        </h3>

        {flag.reason && (
          <p className="text-base text-violet-200">
            <span className="text-zinc-500">Why it was flagged: </span>
            {flag.reason}
          </p>
        )}
        {flag.note && (
          <p className="text-base text-zinc-300">
            <span className="text-zinc-500">Operator: </span>&ldquo;{flag.note.replace(/^operator:\s*/i, "")}&rdquo;
          </p>
        )}
        {controlNote && (
          <p className="text-base text-sky-200">
            <span className="text-zinc-500">Control room: </span>&ldquo;{controlNote}&rdquo;
          </p>
        )}

        {allowNote &&
          (editing ? (
            <div className="no-print mt-1 flex gap-2">
              <input
                autoFocus
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && save()}
                placeholder="Add a note for the next shift..."
                className="min-w-0 flex-1 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-base text-zinc-100 placeholder:text-zinc-600"
              />
              <button
                onClick={save}
                disabled={saving || !draft.trim()}
                className="rounded-lg bg-amber-400 px-4 py-2 text-base font-semibold text-zinc-950 hover:bg-amber-300 disabled:opacity-50"
              >
                Save
              </button>
              <button onClick={() => setEditing(false)} className="px-2 text-base text-zinc-400 hover:text-zinc-100">
                Cancel
              </button>
            </div>
          ) : (
            <button
              onClick={() => {
                setDraft(controlNote ?? "");
                setEditing(true);
              }}
              className="no-print mt-1 self-start text-base font-medium text-sky-300 hover:text-sky-200"
            >
              {controlNote ? "Edit control-room note" : "+ Add control-room note"}
            </button>
          ))}
      </div>
    </article>
  );
}
