"""Countdown to tank shutdown, from the tank's current level and its inflow."""

from typing import Optional

import numpy as np

from .dataset import Dataset


def current_state(ds: Dataset, fac_id: str, now: Optional[int] = None) -> dict:
    now = ds.t_last if now is None else min(now, ds.t_last)
    f = ds.facilities[fac_id]
    w = ds.wide.loc[:now]
    cap = f.tank["capacity_bbl"]
    lim = ds.limits
    level = float(w[(f.tank["id"], "level_pct")].iloc[-1])
    inflow_s = w[(fac_id, "inflow_bpd")].iloc[-12:]
    inflow_mean = float(inflow_s.iloc[-6:].mean())
    # While the pump is down the tank fills along a straight line, so fit the whole fault period instead of
    # trusting the last noisy reading (cuts the level error roughly 3x).
    status = w[(f.pump["id"], "status")].values
    if status[-1] == 2 and level < ds.limits["shutdown"] - 0.05:
        i = len(status) - 1
        while i > 0 and status[i - 1] == 2:
            i -= 1
        seg = w.iloc[i:]
        lv = seg[(f.tank["id"], "level_pct")]
        inf = seg[(fac_id, "inflow_bpd")]
        if len(seg) >= 6 and (inf > 0).all():
            t = (lv.index.values - lv.index.values[-1]) / 3600.0
            slope, icpt = np.polyfit(t, lv.values, 1)
            if abs(icpt - level) < 1.0:  # sanity: the fit must agree with the reading
                level = float(icpt)
            inflow_mean = float(inf.mean())
            inflow_s = inf.iloc[-12:]
    wells = []
    for well in f.wells:
        st = w[(well["id"], "status")].iloc[-1]
        water = float(w[(well["id"], "water_bpd")].iloc[-6:].mean()) if st == 1 else 0.0
        wells.append({**well, "producing": bool(st == 1), "water_bpd": round(water, 1),
                      "rev_per_hour": ds.well_rev_per_hour(well)})
    return {
        "facility_id": fac_id,
        "now": now,
        "capacity_bbl": cap,
        "level_pct": level,
        "warning_pct": lim["warning"],
        "shutdown_pct": lim["shutdown"],
        "inflow_bpd": inflow_mean,
        "inflow_std": float(inflow_s.std()) if len(inflow_s) > 2 else 0.0,
        "wells": wells,
        "pump_status": int(w[(f.pump["id"], "status")].iloc[-1]),
        "pump_flow_bpd": float(w[(f.pump["id"], "flow_bpd")].iloc[-1]),
        "tripped": bool(level >= lim["shutdown"] - 0.05),
        "lost_revenue_per_hour": ds.revenue_per_hour(fac_id),
    }


def forecast_shutdown(ds: Dataset, fac_id: str, now: Optional[int] = None) -> dict:
    """
    Hours until the tank reaches `shutdown` if nothing changes (pump stays off).
    Reported as a range because the readings are noisy: p10 = worst case (fills
    faster), p50 = likely, p90 = best case. The band is the larger of the inflow's own
    noise and a 5% allowance for the inflow drifting.
    """
    s = current_state(ds, fac_id, now)
    gap_pct = s["shutdown_pct"] - s["level_pct"]
    if s["tripped"]:
        return {**_pick(s), "hours_to_limit": {"p50": 0.0, "p10": 0.0, "p90": 0.0}, "rate_pct_per_hour": 0.0,
                "tripped": True}
    inflow = s["inflow_bpd"]
    if inflow <= 1:
        return {**_pick(s), "hours_to_limit": None, "rate_pct_per_hour": 0.0, "tripped": False}
    rate = inflow / 24.0 / s["capacity_bbl"] * 100.0  # % per hour
    rel = max(0.05, 1.28 * s["inflow_std"] / inflow)
    h = lambda r: round(gap_pct / r, 2)
    return {
        **_pick(s),
        "hours_to_limit": {"p50": h(rate), "p10": h(rate * (1 + rel)), "p90": h(rate * (1 - rel))},
        "rate_pct_per_hour": round(rate, 3),
        "tripped": False,
    }


def _pick(s: dict) -> dict:
    return {k: s[k] for k in ("facility_id", "level_pct", "shutdown_pct", "warning_pct", "capacity_bbl",
                              "inflow_bpd", "lost_revenue_per_hour")}
