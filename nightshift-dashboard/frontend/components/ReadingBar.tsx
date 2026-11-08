// A reading next to its limit. The white tick is the limit (amber tick = warning); the bar goes red over the limit.
export default function ReadingBar({
  label, unit, value, limit, warning, note,
}: { label: string; unit: string; value: number; limit: number; warning?: number; note?: string }) {
  const over = value > limit;
  const close = !over && (warning !== undefined ? value >= warning : value >= limit * 0.9);
  const tone = over ? "bg-red-500" : close ? "bg-amber-400" : "bg-emerald-500";
  const text = over ? "text-red-400" : close ? "text-amber-300" : "text-emerald-400";
  const scale = Math.max(limit * 1.15, value * 1.05);
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="flex items-baseline justify-between">
        <h3 className="text-lg text-zinc-300">{label}</h3>
        <span className={`text-sm font-semibold uppercase ${text}`}>{over ? "Over limit" : close ? "Close to limit" : "Within limit"}</span>
      </div>
      <p className={`mt-2 text-4xl font-bold tabular-nums ${text}`}>
        {value.toLocaleString()} <span className="text-xl font-normal text-zinc-500">{unit}</span>
      </p>
      <div className="relative mt-4 h-4 bg-zinc-800">
        <div className={`h-full ${tone}`} style={{ width: `${Math.min(100, (value / scale) * 100)}%` }} />
        {warning !== undefined && <div className="absolute -top-1 h-6 w-0.5 bg-amber-400" style={{ left: `${(warning / scale) * 100}%` }} />}
        <div className="absolute -top-1.5 h-7 w-0.5 bg-zinc-300" style={{ left: `${(limit / scale) * 100}%` }} />
      </div>
      <p className="mt-2 text-sm text-zinc-500">
        Limit {limit.toLocaleString()} {unit}
        {note ? ` · ${note}` : ""}
      </p>
    </div>
  );
}
