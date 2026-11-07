"""
Cheapest plan for pump failures. Pure code, follows SPEC.md "Plans".

For one failure the choices are: n trucks x k trips each, plus shutting in wells (each
from some start time until the repair ends), or letting the tank trip. The tank is
simulated exactly (piecewise linear, trips remove water only when they arrive). A
system's failures share its fleet, so they are planned together: every split of the
trucks across the failures is tried and the cheapest total wins.

Assumption: a truck sent to one facility is not reused by another failure inside the
repair window (response + cycle time is longer than the window in all practice data).
"""

import itertools
from dataclasses import dataclass
from typing import Optional

EPS = 1e-6
# A plan must keep the tank strictly below shutdown, with a small safety margin (percentage points of the tank).
MARGIN_PCT = 0.02


@dataclass
class Ctx:
    event_id: str
    facility_id: str
    capacity: float  # bbl
    level_pct: float
    shutdown_pct: float
    wells: list  # producing wells: {id, water_bpd, rev_per_hour}
    horizon_min: float  # minutes until the repair ends
    response_min: float
    cycle_min: float
    truck_bbl: float
    trip_cost: float

    @property
    def rev_per_hour(self) -> float:
        return sum(w["rev_per_hour"] for w in self.wells)


def arrivals(c: Ctx, k: int) -> list[float]:
    return [c.response_min + j * c.cycle_min for j in range(k)]


def max_trips(c: Ctx) -> int:
    n = 0
    while c.response_min + n * c.cycle_min < c.horizon_min - EPS:
        n += 1
    return n


def simulate(c: Ctx, trucks: int, trips: int, shut: dict) -> dict:
    """shut = {well_id: start_min}. Returns trip time (None = never) and timeline points."""
    vol = c.level_pct / 100 * c.capacity
    limit = (c.shutdown_pct - MARGIN_PCT) / 100 * c.capacity  # never plan to touch the real limit
    ev = sorted(set([0.0, c.horizon_min] + [t for t in arrivals(c, trips) if t < c.horizon_min]
                    + [s for s in shut.values() if 0 <= s < c.horizon_min]))
    arr = set(arrivals(c, trips)) if trucks else set()
    t = 0.0
    pts = [(0.0, vol)]
    trip_t = None
    for i in range(len(ev) - 1):
        t0, t1 = ev[i], ev[i + 1]
        # trucks that arrive at t0 empty the tank first
        if t0 in arr:
            vol = max(0.0, vol - trucks * c.truck_bbl)
            pts.append((t0, vol))
        rate = sum(w["water_bpd"] for w in c.wells if not (w["id"] in shut and shut[w["id"]] <= t0 + EPS)) / 1440.0
        if rate > 0 and vol + rate * (t1 - t0) >= limit - EPS:
            trip_t = t0 + (limit - vol) / rate
            pts.append((trip_t, limit))
            break
        vol += rate * (t1 - t0)
        pts.append((t1, vol))
    return {"trip_min": trip_t, "points": pts, "end_vol": pts[-1][1]}


def cost_of(c: Ctx, trucks: int, trips: int, shut: dict, trip_min: Optional[float]) -> float:
    truck_cost = trucks * trips * c.trip_cost
    loss = 0.0
    for w in c.wells:
        off = [x for x in (shut.get(w["id"]), trip_min) if x is not None]
        if off:
            loss += w["rev_per_hour"] * (c.horizon_min - min(off)) / 60.0
    return truck_cost + loss


def _feasible(c, trucks, trips, shut) -> bool:
    return simulate(c, trucks, trips, shut)["trip_min"] is None


def best_for_trucks(c: Ctx, trucks: int) -> dict:
    """Cheapest plan that uses exactly `trucks` trucks (0 = none)."""
    best = None

    def consider(trips, shut, label):
        nonlocal best
        sim = simulate(c, trucks, trips, shut)
        cost = cost_of(c, trucks, trips, shut, sim["trip_min"])
        cand = {"trucks": trucks, "trips": trips, "shut_ins": dict(shut), "cost": cost,
                "trip_min": sim["trip_min"], "tripped": sim["trip_min"] is not None}
        key = (round(cost, 4), trucks * trips, len(shut))
        if best is None or key < best[0]:
            best = (key, cand)

    for trips in ([0] if trucks == 0 else range(1, max_trips(c) + 1)):
        consider(trips, {}, "none")  # no shut-ins (may trip)
        if _feasible(c, trucks, trips, {}):
            continue
        wells = c.wells
        ids = [w["id"] for w in wells]
        # subsets shut in right now + at most one well shut in as late as possible
        for r in range(0, len(ids) + 1):
            for full in itertools.combinations(ids, r):
                base = {w: 0.0 for w in full}
                rest = [i for i in ids if i not in full]
                if r and _feasible(c, trucks, trips, base):
                    consider(trips, base, "full")
                for p in rest:
                    if not _feasible(c, trucks, trips, {**base, p: 0.0}):
                        continue
                    lo, hi = 0.0, c.horizon_min  # latest feasible start for p
                    for _ in range(40):
                        mid = (lo + hi) / 2
                        if _feasible(c, trucks, trips, {**base, p: mid}):
                            lo = mid
                        else:
                            hi = mid
                    consider(trips, {**base, p: max(0.0, lo - 1e-3)}, "partial")
    return best[1]


def optimize_system(ctxs: list[Ctx], fleet: int) -> dict:
    """Plan every failure in a system together. Returns plans keyed by event id + totals."""
    per = {c.event_id: {n: best_for_trucks(c, n) for n in range(0, fleet + 1)} for c in ctxs}
    best = None
    for split in itertools.product(range(fleet + 1), repeat=len(ctxs)):
        if sum(split) > fleet:
            continue
        total = sum(per[c.event_id][n]["cost"] for c, n in zip(ctxs, split))
        key = (round(total, 4), sum(split))
        if best is None or key < best[0]:
            best = (key, split, total)
    _, split, total = best
    chosen = {c.event_id: per[c.event_id][n] for c, n in zip(ctxs, split)}
    return {"chosen": chosen, "per_trucks": per, "total_cost": total, "trucks_used": sum(split), "fleet": fleet}


def do_nothing(c: Ctx) -> dict:
    sim = simulate(c, 0, 0, {})
    return {"trucks": 0, "trips": 0, "shut_ins": {}, "tripped": sim["trip_min"] is not None,
            "trip_min": sim["trip_min"], "cost": cost_of(c, 0, 0, {}, sim["trip_min"])}


def shut_in_only(c: Ctx) -> dict:
    return best_for_trucks(c, 0)
