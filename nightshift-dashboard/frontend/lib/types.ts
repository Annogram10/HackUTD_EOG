// Shared data shapes. Must match backend/main.py.

export type FlagType = "leak" | "smoke" | "damage" | "alarm";
export type FlagStatus = "pending" | "confirmed" | "dismissed";
export type Trigger = "camera" | "voice" | "data";

export interface Flag {
  priority?: number; // 1 = marked as priority by the operator
  id: string;
  shift_id: string;
  type: FlagType;
  location: string; // facility name
  equipment_id: string; // facility id
  photo_url: string;
  timestamp: string; // UTC, no suffix
  status: FlagStatus;
  note?: string | null;
  control_note?: string | null;
  trigger: Trigger;
  reason?: string | null;
}

export interface Shift {
  id: string;
  dataset: string;
  date: string;
  operator: string;
  started_at: string;
  ended_at: string;
  uploaded_at: string;
  route_planned: string[]; // facility ids
  route_walked: string[];
  flags: Flag[];
}

export type FacilityStatus = "ok" | "worn" | "leak" | "failure" | "tripped";

export interface FacilityCard {
  risk_level?: RiskLevel; // green = nothing to act on (a minor decrease is fine)
  id: string;
  name: string;
  system_id: string;
  lat: number;
  lon: number;
  status: FacilityStatus;
  level_pct: number;
  warning_pct: number;
  shutdown_pct: number;
  capacity_bbl: number;
  pump_status: number; // 0 stopped, 1 running, 2 fault
  pump_flow_bpd: number;
  inflow_bpd: number;
  wells: { id: string; producing: boolean }[];
  pump_id: string;
  tank_id: string;
  pipeline_id: string;
  hours_to_limit: Hours | null;
  lost_revenue_per_hour: number;
  alert_ids: string[];
}

export interface Hours {
  p50: number;
  p10: number;
  p90: number;
}

export interface Plan {
  label: string;
  trucks: number;
  trips_per_truck: number;
  cost: number;
  shut_ins: { well: string; start_after_min: number }[];
  tank_trips: boolean;
  trip_ts: string | null;
  actions: Record<string, unknown>[];
}

export type Category = "pump_failure" | "pipeline_leak" | "pump_degradation";

export interface Alert {
  truck_cost?: TruckCost;
  level?: RiskLevel; // red danger, amber check soon, green minor (a small decrease is fine)
  event_id: string;
  category: Category;
  system_id: string;
  facility_id: string;
  facility_name: string;
  asset_id: string;
  status: "ongoing" | "resolved";
  onset_ts: string;
  end_ts: string | null;
  detected_ts: string;
  confidence: number;
  evidence: string[];
  order: number;
  lost_revenue_per_hour: number;
  level_pct: number | null;
  hours_to_limit: Hours | null;
  tripped?: boolean;
  repair_end_ts?: string;
  plan: Plan | null;
  options: Plan[];
  action_text: string;
  trucks_shared_with?: string[];
  whatif?: {
    shutdown_pct: number;
    warning_pct: number;
    repair_end_ts: string;
    do_nothing: { ts: number; level_pct: number }[];
    with_plan: { ts: number; level_pct: number }[];
    marks: { min: number; label: string }[];
  };
}

export interface EventRow {
  event_id: string;
  category: Category;
  facility_id: string;
  asset_id: string;
  status: "ongoing" | "resolved";
  onset_ts: string;
  end_ts: string | null;
  confidence: number;
  evidence: string[];
}

export interface System {
  id: string;
  center: [number, number];
  truck_yard: [number, number];
  fleet_size: number;
  disposal_site: { id: string; lat: number; lon: number; pressure_psi: number };
  facilities: FacilityCard[];
  shared: { fleet: number; trucks_used: number; total_cost: number; events: string[] } | null;
}

export interface Overview {
  dataset: string;
  now_ts: string;
  first_ts: string;
  systems: System[];
  alerts: Alert[];
  counts: { failures: number; leaks: number; worn: number };
}

export interface DatasetInfo {
  name: string;
  now_ts: string;
  first_ts: string;
  systems: number;
  facilities: number;
}

export interface Series {
  asset: string;
  metric: string;
  label: string;
  unit: string;
  points: [number, number][]; // [unix, value]
}

export interface FacilityDetail extends FacilityCard {
  dataset: string;
  now: number;
  readings: { label: string; unit: string; value: number; limit: number; warning?: number; note: string }[];
  series: Series[];
  alerts: Alert[];
  events: EventRow[];
  wells_detail: { id: string; baseline_water_bpd: number; oil_bpd: number; gas_mcfd: number; rev_per_hour: number }[];
  response_min: number;
  cycle_min: number;
  flags: Flag[];
  assets: { tank: string; pump: string; pipeline: string; wells: string[] };
}

export interface Report {
  shift: Pick<Shift, "id" | "dataset" | "date" | "operator" | "started_at" | "ended_at" | "uploaded_at">;
  totals: { total: number; confirmed: number; pending: number; dismissed: number };
  by_type: Record<string, number>;
  confirmed: Flag[];
  pending: Flag[];
  notes: { flag_id: string; location: string; note: string; author: "operator" | "control"; timestamp: string }[];
  stops_planned: number;
  stops_walked: number;
  missed_stops: string[]; // facility ids
}

export type PriorityLevel = "high" | "medium" | "low";

export interface Priority {
  equipment_id: string;
  location: string;
  score: number;
  level: PriorityLevel;
  reasons: string[];
  latest_flag: Flag | null;
}

export interface TraceStep {
  step: number;
  kind: "plan" | "tool" | "thought";
  t: number;
  tool?: string;
  args?: Record<string, unknown>;
  why?: string;
  text?: string;
  result?: string;
  ms?: number;
  error?: string | null;
}

export interface AgentRun {
  dataset: string;
  status: "running" | "done" | "error";
  mode: "nemotron" | "offline-script";
  model: string | null;
  steps: TraceStep[];
  handoff: string | null;
  error: string | null;
}

export interface Handoff {
  dataset: string;
  as_of: string;
  headline: string;
  lines: string[];
  spoken: string[];
  agent_text?: string;
  agent_mode?: string;
  events_count: number;
}

export type RiskLevel = "green" | "amber" | "red";

export interface Timeline {
  dataset: string;
  first: number; // unix seconds
  last: number;
  step_s: number;
  bands: { level: RiskLevel; start: number; end: number }[]; // pump-failure stretches: amber and red
  slow_bands: { level: RiskLevel; start: number; end: number }[]; // a leak or worn pump is open (days long)
  alarms: number[]; // moments a red alarm would have started
}

export interface Risk {
  dataset: string;
  as_of: string;
  now: number;
  level: RiskLevel;
  rules_level: RiskLevel;
  alarm: boolean;
  alarm_id: string | null;
  headline: string;
  reasons: { level: RiskLevel; facility_id: string; text: string }[];
  facilities: Record<string, RiskLevel>;
  ai: { available: boolean; level?: RiskLevel; headline?: string; why?: string; money?: string; model?: string; error?: string } | null;
  money: {
    rows: { facility_id: string; name: string; fix: string; cost: number; do_nothing: number | null; saves: number | null; trucks: TruckCost }[];
    trip_price: number; // what one truck trip costs (ops.json)
    trip_bbl: number; // water one trip takes away
    total_cost: number;
    total_do_nothing: number;
    total_saves: number;
    text: string;
    from_ai: boolean; // the sentence was written by the model (every dollar figure in it is checked against the real numbers)
  };
  spoken_text: string;
}

export interface EvidenceChart {
  asset: string;
  metric: string;
  label: string;
  unit: string;
  base: number; // normal value before the problem
  current: number;
  change: number; // % change (points for the tank level)
  caption: string;
  points: [number, number][];
}

export interface Evidence {
  dataset: string;
  as_of: string;
  now: number;
  ai: { available: boolean; model?: string; error?: string } | null;
  sections: { facility_id: string; name: string; system: string; category: string; level: RiskLevel; onset_unix: number; onset_ts: string; charts: EvidenceChart[] }[];
}

export interface TruckCost {
  trip_price: number;
  trip_bbl: number;
  trucks: number;
  trips: number; // per truck
  trucks_total: number;
  shut_in_total: number; // the part of the plan that is lost sales from wells shut in
  arrive_min: number | null;
}
