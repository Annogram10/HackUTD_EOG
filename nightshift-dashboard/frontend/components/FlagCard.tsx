"use client";

import Link from "next/link";
import { useState } from "react";
import { addControlNote, clearFlagPhoto, deleteFlag, replaceFlagPhoto, setFlagStatus, formatDate, formatTime, photoSrc } from "@/lib/api";
import type { Flag } from "@/lib/types";
import { StatusBadge, TriggerBadge, TypeBadge } from "./Badges";
import { useApp } from "./AppProvider";

interface Props {
  flag: Flag;
  showDate?: boolean; // equipment timeline spans several nights
  allowNote?: boolean; // control room can add a note
  linkEquipment?: boolean;
}

// "S5_FACILITY_C" -> { system: "S5", facility: "Facility C" }; ids that are not dataset facilities have no section.
function sectionOf(equipmentId: string) {
  const m = equipmentId.match(/^(S\d+)_FACILITY_([A-Z0-9]+)$/i);
  return m ? { system: m[1].toUpperCase(), facility: `Facility ${m[2].toUpperCase()}` } : null;
}

export default function FlagCard({ flag, showDate = false, allowNote = false, linkEquipment = true }: Props) {
  const { patchFlag, removeFlag } = useApp();
  const remove = async () => {
    if (!window.confirm(`Delete this ${flag.type} flag at ${flag.location}? This cannot be undone.`)) return;
    if (await deleteFlag(flag.id)) removeFlag(flag.id);
    else window.alert("Could not delete the flag. Is the backend running?");
  };
  const [imgOk, setImgOk] = useState(Boolean(flag.photo_url));
  const [draft, setDraft] = useState("");
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [localNote, setLocalNote] = useState<string | null>(null); // used when backend is offline
  const dimmed = flag.status === "dismissed";
  const controlNote = localNote ?? flag.control_note;

  const [deciding, setDeciding] = useState(false);
  const [failed, setFailed] = useState(false);

  async function decide(action: "confirm" | "dismiss" | "prioritize" | "reopen") {
    setDeciding(true);
    setFailed(false);
    const updated = await setFlagStatus(flag.id, action);
    if (updated) patchFlag(updated);
    else setFailed(true);
    setDeciding(false);
  }

  async function photoAction(run: () => Promise<Flag | null>) {
    setDeciding(true);
    setFailed(false);
    const updated = await run();
    if (updated) {
      patchFlag(updated);
      setImgOk(Boolean(updated.photo_url));
    } else setFailed(true);
    setDeciding(false);
  }

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
          {flag.priority ? <span className="inline-flex items-center bg-red-500/15 px-2.5 py-0.5 text-sm font-semibold uppercase text-red-300 ring-1 ring-red-500/50">Priority</span> : null}
          <TypeBadge type={flag.type} />
          <TriggerBadge trigger={flag.trigger} />
        </div>

        <p className="text-sm text-zinc-400">
          {(() => {
            const sec = sectionOf(flag.equipment_id);
            return sec ? `System ${sec.system} · ${sec.facility}` : `Section unknown (the app sent "${flag.equipment_id}")`;
          })()}
        </p>

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
          <p className="text-base text-zinc-200">
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
          <p className="text-base text-zinc-200">
            <span className="text-zinc-500">Control room: </span>&ldquo;{controlNote}&rdquo;
          </p>
        )}

        {allowNote && (
          <div className="no-print flex flex-wrap items-center gap-2 pt-1">
            {flag.status === "pending" ? (
              <>
                <button onClick={() => decide("confirm")} disabled={deciding}
                  className="btn-primary px-4 py-2 text-base font-semibold disabled:opacity-50">
                  Confirm issue
                </button>
                <button onClick={() => decide("prioritize")} disabled={deciding}
                  className="border border-red-500/60 px-4 py-2 text-base font-semibold text-red-300 hover:bg-red-500/10 disabled:opacity-50">
                  Prioritize
                </button>
                <button onClick={() => decide("dismiss")} disabled={deciding}
                  className="rounded-lg border border-zinc-600 px-4 py-2 text-base font-semibold text-zinc-200 hover:bg-zinc-800 disabled:opacity-50">
                  Dismiss
                </button>
              </>
            ) : (
              <button onClick={() => decide("reopen")} disabled={deciding}
                className="rounded-lg border border-zinc-700 px-4 py-2 text-base font-medium text-zinc-300 hover:bg-zinc-800 disabled:opacity-50">
                Undo ({flag.status === "dismissed" ? "dismissed" : "confirmed"}), back to needs review
              </button>
            )}
            <label className={`cursor-pointer rounded-lg border border-zinc-700 px-4 py-2 text-base font-medium text-zinc-300 hover:bg-zinc-800 ${deciding ? "pointer-events-none opacity-50" : ""}`}>
              {flag.photo_url ? "Replace photo" : "Add photo"}
              <input
                type="file"
                accept="image/jpeg,image/png"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  e.target.value = "";
                  if (file) photoAction(() => replaceFlagPhoto(flag.id, file));
                }}
              />
            </label>
            <button onClick={remove} disabled={deciding}
              className="border border-zinc-700 px-4 py-2 text-base font-medium text-zinc-300 hover:bg-zinc-800 disabled:opacity-50">
              Delete flag
            </button>
            {flag.photo_url && (
              <button onClick={() => photoAction(() => clearFlagPhoto(flag.id))} disabled={deciding}
                className="rounded-lg border border-zinc-700 px-4 py-2 text-base font-medium text-zinc-300 hover:bg-zinc-800 disabled:opacity-50">
                Remove photo
              </button>
            )}
            {failed && <span className="text-base text-red-300">Couldn&apos;t save. Is the backend running?</span>}
          </div>
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
                className="min-w-0 flex-1 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-base text-zinc-100 placeholder:text-zinc-500"
              />
              <button
                onClick={save}
                disabled={saving || !draft.trim()}
                className="btn-primary px-4 py-2 text-base font-semibold disabled:opacity-50"
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
              className="no-print mt-1 self-start text-base font-medium text-sky-300 hover:text-sky-300"
            >
              {controlNote ? "Edit control-room note" : "+ Add control-room note"}
            </button>
          ))}
      </div>
    </article>
  );
}
