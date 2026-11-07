"use client";

import { useState } from "react";
import { formatTime, photoSrc } from "@/lib/api";
import type { Flag } from "@/lib/types";
import { StatusBadge, TypeBadge } from "./Badges";

export default function FlagCard({ flag, isNew = false }: { flag: Flag; isNew?: boolean }) {
  const [imgOk, setImgOk] = useState(Boolean(flag.photo_url));
  const dimmed = flag.status === "dismissed";

  return (
    <article
      className={`flex gap-4 rounded-xl border border-zinc-800 bg-zinc-900 p-4 transition-opacity ${
        isNew ? "flag-new" : ""
      } ${dimmed ? "opacity-50" : ""}`}
    >
      <div className="h-28 w-40 shrink-0 overflow-hidden rounded-lg bg-zinc-800">
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
          <div className="flex h-full items-center justify-center text-xs text-zinc-500">No photo</div>
        )}
      </div>

      <div className="flex min-w-0 flex-1 flex-col gap-1.5">
        <div className="flex flex-wrap items-center gap-2">
          <TypeBadge type={flag.type} />
          <StatusBadge status={flag.status} />
          {isNew && <span className="text-xs font-semibold text-amber-300">NEW</span>}
        </div>
        <h3 className="text-lg font-semibold text-zinc-100">
          Possible {flag.type} at {flag.location}
        </h3>
        <p className="text-sm text-zinc-400">{formatTime(flag.timestamp)}</p>
        {flag.note && <p className="text-sm text-zinc-300">&ldquo;{flag.note}&rdquo;</p>}
      </div>
    </article>
  );
}
