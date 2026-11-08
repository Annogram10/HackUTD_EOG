// Small indicator so you always know if you're looking at real backend data
// or the fake JSON fallback.
export default function SourceTag({ live }: { live: boolean }) {
  return live ? (
    <span className="inline-flex items-center gap-2 text-sm text-emerald-400">
      <span className="h-2 w-2 rounded-full bg-emerald-400" />
      Connected
    </span>
  ) : (
    <span className="inline-flex items-center gap-2 bg-zinc-800 px-3 py-1 text-sm text-zinc-400">
      <span className="h-2 w-2 rounded-full bg-zinc-500" />
      Demo data
    </span>
  );
}
