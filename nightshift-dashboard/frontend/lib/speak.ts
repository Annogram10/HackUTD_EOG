// What the owl says. The spoken wording matches the glasses alerts (backend app/speech.py and handoff.spoken):
// numbers spelled out, hours to one decimal, every plan worded as a proposal. Built from data already loaded.

import { facName, fmtHours, money } from "./api";
import type { Alert, Plan } from "./types";

const ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(" ");
const TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split(" ");

export function intWords(n: number): string {
  if (n < 0) return "minus " + intWords(-n);
  if (n < 20) return ONES[n];
  if (n < 100) return TENS[Math.floor(n / 10)] + (n % 10 ? " " + ONES[n % 10] : "");
  if (n < 1000) return ONES[Math.floor(n / 100)] + " hundred" + (n % 100 ? " " + intWords(n % 100) : "");
  if (n < 1_000_000) return intWords(Math.floor(n / 1000)) + " thousand" + (n % 1000 ? " " + intWords(n % 1000) : "");
  return String(n);
}

function numWords(x: number, decimals = 0): string {
  const r = Number(x.toFixed(decimals));
  const whole = Math.floor(Math.abs(r));
  let out = intWords(whole);
  if (decimals && Math.abs(r) - whole > 0) {
    out += " point " + Math.abs(r).toFixed(decimals).split(".")[1].split("").map((d) => ONES[Number(d)]).join(" ");
  }
  return r < 0 ? "minus " + out : out;
}

const hoursWords = (h: number) => {
  const s = numWords(h, 1);
  return `${s} hour${s === "one" ? "" : "s"}`;
};
const dollarWords = (x: number) => {
  const n = Math.round(x);
  return `${intWords(n)} dollar${n === 1 ? "" : "s"}`;
};
const facilityWords = (name: string) =>
  name.split(" ").map((w) => (w.length > 1 && w[0] === "S" && /^\d+$/.test(w.slice(1)) ? "S " + intWords(Number(w.slice(1))) : w)).join(" ");

function planWords(p: Plan, words: boolean): string {
  const num = (n: number) => (words ? intWords(n) : String(n));
  const bits: string[] = [];
  if (p.trucks) bits.push(`send ${num(p.trucks)} truck${p.trucks > 1 ? "s" : ""}` + (p.trips_per_truck > 1 ? `, ${num(p.trips_per_truck)} trips each` : ""));
  for (const s of p.shut_ins) {
    bits.push(`shut in well ${s.well.split("_").pop()}` + (s.start_after_min <= 0 ? "" : ` in ${num(Math.round(s.start_after_min))} minutes`));
  }
  return bits.join(", ") || (p.tank_trips ? "no action, the tank reaches shutdown" : "no action needed");
}

/** One alert, spoken the way the glasses say it. */
export function spokenAlert(a: Alert): string {
  const who = facilityWords(facName(a.facility_id));
  if (a.category === "pump_failure") {
    if (a.tripped) return `${who} pump has failed and the tank has already reached shutdown. The wells stay shut in until the repair ends.`;
    const h = a.hours_to_limit ? `Shutdown in about ${hoursWords(a.hours_to_limit.p50)}.` : "";
    const fix = a.plan ? ` Proposed plan for supervisor approval: ${planWords(a.plan, true)}, ${dollarWords(a.plan.cost)}.` : "";
    return `${who} pump has failed. ${h}${fix}`;
  }
  if (a.category === "pipeline_leak") return `${who} pipeline may be leaking. Proposed for supervisor approval: an inspector checks it.`;
  return `${who} pump may be wearing out. Proposed for supervisor approval: an inspector checks it.`;
}

/** The whole summary for the speak button: the three most urgent problems, or all clear. */
export function spokenSummary(alerts: Alert[]): string {
  if (!alerts.length) return "All clear. No problems in progress.";
  const top = [...alerts].sort((a, b) => a.order - b.order).slice(0, 3).map(spokenAlert).join(" ");
  const more = alerts.length > 3 ? ` And ${intWords(alerts.length - 3)} more on the screen.` : "";
  return `${intWords(alerts.length)} problem${alerts.length > 1 ? "s" : ""} in progress. ${top}${more}`;
}

/** The on-screen danger line in the owl's bubble (digits, not words). */
export function dangerLine(a: Alert): string {
  const who = facName(a.facility_id);
  if (a.tripped) return `${who}: the tank is already at shutdown.`;
  const left = a.hours_to_limit ? `${fmtHours(a.hours_to_limit.p50)} left` : "pump failed";
  const fix = a.plan ? ` Cheapest fix (needs supervisor approval): ${planWords(a.plan, false)}, ${money(a.plan.cost)}.` : "";
  return `${who}: ${left}.${fix}`;
}
