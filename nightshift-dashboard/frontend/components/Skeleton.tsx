// Loading shapes that match the page they stand in for. Flat grey blocks, no spinners.

const B = ({ h, w = "w-full", className = "" }: { h: string; w?: string; className?: string }) => (
  <div className={`${h} ${w} animate-pulse bg-zinc-900 ${className}`} />
);

// A card with a title, a few lines and an action row.
export const CardSkeleton = ({ lines = 3 }: { lines?: number }) => (
  <div className="space-y-3 border border-zinc-800 p-5">
    <B h="h-7" w="w-2/5" />
    {Array.from({ length: lines }, (_, i) => <B key={i} h="h-4" w={i === lines - 1 ? "w-3/5" : "w-full"} />)}
  </div>
);

// Now page: status box, then a chart, then rows.
export const NowSkeleton = () => (
  <div className="space-y-8" aria-busy="true">
    <div className="space-y-4 border border-zinc-800 p-5">
      <B h="h-8" w="w-3/5" />
      <B h="h-4" w="w-4/5" />
      <B h="h-4" w="w-2/3" />
      <B h="h-14" />
    </div>
    <div className="space-y-3">
      <B h="h-7" w="w-40" />
      <B h="h-56" />
    </div>
  </div>
);

// A page with a heading and a stack of cards (flags, handover, facility).
export const PageSkeleton = ({ cards = 3 }: { cards?: number }) => (
  <div className="space-y-6" aria-busy="true">
    <div className="space-y-2">
      <B h="h-9" w="w-72" />
      <B h="h-4" w="w-96 max-w-full" />
    </div>
    {Array.from({ length: cards }, (_, i) => <CardSkeleton key={i} />)}
  </div>
);

// Shown instead of a view when its data could not be loaded. Plain words, never a raw error.
export const ErrorState = ({ what }: { what: string }) => (
  <div role="alert" className="border-2 border-red-500/60 bg-red-500/10 p-6 text-lg text-red-100">
    <p className="font-semibold">Could not load {what}.</p>
    <p className="mt-1 text-base text-red-200">The backend did not answer. It will retry by itself; check that the backend is running.</p>
  </div>
);
