export default function Stat({
  label,
  value,
  tone = "text-zinc-100",
}: {
  label: string;
  value: number | string;
  tone?: string;
}) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 px-5 py-4">
      <p className="text-sm text-zinc-400">{label}</p>
      <p className={`mt-1 text-4xl font-bold tabular-nums ${tone}`}>{value}</p>
    </div>
  );
}
