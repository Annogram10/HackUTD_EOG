export default function Stat({
  label,
  value,
  sub,
  tone = "text-zinc-100",
  bare = false,
}: {
  label: string;
  value: number | string;
  sub?: string;
  tone?: string;
  bare?: boolean;
}) {
  return (
    <div className={bare ? "bg-zinc-900 px-5 py-4" : "rounded-xl border border-zinc-800 bg-zinc-900 px-5 py-4"}>
      <p className="text-base text-zinc-400">{label}</p>
      <p className={`mt-1 text-5xl font-bold tabular-nums ${tone}`}>{value}</p>
      {sub && <p className="mt-1 text-sm text-zinc-500">{sub}</p>}
    </div>
  );
}
