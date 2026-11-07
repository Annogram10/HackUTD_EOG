import { money } from "@/lib/api";
import type { Alert } from "@/lib/types";

// Every option side by side. The cheapest is highlighted. "Recommended" uses the shared fleet.
export default function PlanTable({ a }: { a: Alert }) {
  if (!a.plan) return null;
  const rows = [a.plan, ...a.options];
  const cheapest = Math.min(...rows.map((r) => r.cost));
  return (
    <div className="overflow-x-auto rounded-xl border border-zinc-800 bg-zinc-900">
      <table className="w-full text-left text-lg">
        <thead className="text-sm uppercase tracking-wide text-zinc-500">
          <tr><th className="px-4 py-3">Option</th><th className="px-4 py-3">What happens</th><th className="px-4 py-3">Tank</th><th className="px-4 py-3 text-right">Cost</th></tr>
        </thead>
        <tbody className="divide-y divide-zinc-800">
          {rows.map((r, i) => {
            const best = r.cost === cheapest;
            return (
              <tr key={i} className={i === 0 ? "bg-emerald-500/10" : ""}>
                <td className="px-4 py-3 font-semibold">{r.label}{i === 0 && <span className="ml-2 text-sm font-normal text-emerald-300">(shares the fleet with the other failures)</span>}</td>
                <td className="px-4 py-3 text-zinc-300">
                  {[r.trucks ? `${r.trucks} truck${r.trucks > 1 ? "s" : ""} × ${r.trips_per_truck} trip${r.trips_per_truck > 1 ? "s" : ""}` : null,
                    ...r.shut_ins.map((s) => `shut in ${s.well} ${s.start_after_min <= 0 ? "now" : `at +${s.start_after_min} min`}`)]
                    .filter(Boolean).join(", ") || "Nothing"}
                </td>
                <td className="px-4 py-3">{r.tank_trips ? <span className="text-red-300">Trips, wells shut in</span> : <span className="text-emerald-300">Stays under shutdown</span>}</td>
                <td className={`px-4 py-3 text-right text-xl font-bold tabular-nums ${best ? "text-emerald-300" : "text-zinc-100"}`}>{money(r.cost)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
