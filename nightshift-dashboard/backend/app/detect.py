"""
Problem detection: plain rules over the sensor readings (no AI, no answer key).

What each problem looks like in the readings (worked out from comparing the
labelled practice events with normal operation):

  pump_failure     Pump status reads 2 (fault): flow drops to 0, the tank keeps filling.
                   Fallback rule: pump stays off although the tank is well above its start setpoint.
  pipeline_leak    While the pump runs, pipeline pressure at the disposal end sags below its
                   normal level and less water arrives than the pump sent out. Grows over hours.
  pump_degradation While the pump runs, it moves less than its rated flow and its discharge
                   pressure sags. Grows over hours.

The gradual problems are only visible while the pump is running, so they are
judged on "running" samples only. Normal levels are learned from each asset's own
readings (most common value), so the rules do not rely on fixed offsets.
"""

from typing import Optional

import numpy as np
import pandas as pd

from .dataset import Dataset, iso

WINDOW = 12  # running samples averaged together (1 hour of running time)
Z_ALERT = 7.0  # how many noise-widths away from normal counts as a real problem
MIN_RUN = 6  # a problem must hold for this many running samples
GAP_BRIDGE = 6  # a short return to normal inside a problem doesn't end it
FAULT_STATUS = 2
STOP_GAP_S = 3600  # no running reading for over an hour = the pump was stopped (fault or held off)
SAMPLE_S = 300  # readings come every 5 minutes


def _mode(x: np.ndarray, width: float) -> float:
    """Most common value of x (robust 'normal' level)."""
    x = x[np.isfinite(x)]
    if len(x) == 0:
        return 0.0
    bins = np.arange(x.min(), x.max() + width * 2, width)
    if len(bins) < 2:
        return float(np.median(x))
    h, edges = np.histogram(x, bins=bins)
    peak = (edges[h.argmax()] + edges[h.argmax() + 1]) / 2
    near = x[np.abs(x - peak) <= width * 3]
    return float(np.median(near))


def _noise(x: np.ndarray, center: float, floor: float, span: float) -> float:
    near = x[np.isfinite(x) & (np.abs(x - center) <= span)]
    return float(max(np.std(near), floor)) if len(near) > 5 else floor


def _runs(mask: np.ndarray, bridge: int) -> list[tuple[int, int]]:
    """Index ranges where mask is True, bridging short False gaps."""
    out: list[tuple[int, int]] = []
    start: Optional[int] = None
    gap = 0
    for i, v in enumerate(mask):
        if v:
            if start is None:
                start = i
            gap = 0
            last = i
        elif start is not None:
            gap += 1
            if gap > bridge:
                out.append((start, last))
                start, gap = None, 0
    if start is not None:
        out.append((start, last))
    return out


def _conf(z_peak: float) -> float:
    return float(round(0.5 + 0.49 * (1 - np.exp(-(z_peak - Z_ALERT) / Z_ALERT)), 2))


class _Pump:
    """The readings of one facility's pump and pipeline."""

    def __init__(self, ds: Dataset, fac_id: str, now: int):
        f = ds.facilities[fac_id]
        self.ds, self.f, self.now = ds, f, now
        w = ds.wide.loc[:now]
        self.idx = w.index.values
        p, pl, t = f.pump["id"], f.pipeline["id"], f.tank["id"]
        self.status = w[(p, "status")].values
        self.flow = w[(p, "flow_bpd")].values
        self.dis = w[(p, "discharge_psi")].values
        self.recv = w[(pl, "receive_flow_bpd")].values
        self.pp = w[(pl, "pressure_psi")].values
        self.level = w[(t, "level_pct")].values
        self.max_flow = f.pump["max_flow_bpd"]
        self.run = (self.status == 1) & (self.flow > 0.3 * self.max_flow)


def _fault_events(P: _Pump) -> list[dict]:
    """Pump status 2 = fault. Also: pump stays off although the tank is far above its start setpoint."""
    f = P.f
    fault = P.status == FAULT_STATUS
    start_pct = f.pump["start_level_pct"]
    # fallback: stopped for >= 4 samples while tank is >3 points over the start setpoint
    stalled = (P.status == 0) & (P.level > start_pct + 3.0)
    stalled_runs = _runs(stalled, 0)
    out = []

    runs = [(a, b, "status") for a, b in _runs(fault, 1) if b - a + 1 >= 2]
    for a, b in stalled_runs:
        if b - a + 1 >= 4 and not any(a <= rb and b >= ra for ra, rb, _ in runs):
            runs.append((a, b, "stalled"))

    for a, b, how in sorted(runs):
        onset = P.idx[a]
        ongoing = b >= len(P.idx) - 1
        end = None if ongoing else P.idx[min(b + 1, len(P.idx) - 1)]
        nrun = b - a + 1
        before = P.flow[max(0, a - 24):a]
        before = before[before > 0.3 * P.max_flow]
        ev = {
            "category": "pump_failure",
            "facility_id": f.id,
            "asset_id": f.pump["id"],
            "onset_unix": int(onset),
            "end_unix": None if end is None else int(end),
            "status": "ongoing" if ongoing else "resolved",
            "detected_unix": int(P.idx[min(a + 1, len(P.idx) - 1)]),
            "confidence": 0.98 if how == "status" and nrun >= 3 else 0.85 if how == "status" else 0.7,
        }
        hrs = max(1, nrun) * 5 / 60
        ev["evidence"] = [
            (f"Pump status reads FAULT since {iso(onset)}" if how == "status"
             else f"Pump has not started although the tank is {P.level[b]:.0f}% full (start setpoint {start_pct}%)"),
            f"Pump flow fell to {float(np.mean(P.flow[a:b + 1])):.0f} bpd"
            + (f" from about {float(np.mean(before)):.0f} bpd" if len(before) else ""),
            f"Tank level is {P.level[b]:.1f}% and rising" if ongoing else f"Fault lasted about {hrs:.1f} h",
        ]
        out.append(ev)
    return out


def _gradual(P: _Pump, signal: np.ndarray, base: float, sigma: float, sign: int) -> tuple[np.ndarray, np.ndarray]:
    """Rolling z-score of a signal over running samples (sign=-1: low is bad, +1: high is bad)."""
    s = pd.Series(signal)
    roll = s.rolling(WINDOW, min_periods=WINDOW // 2).mean().values
    z = sign * (roll - base) / (sigma / np.sqrt(WINDOW))
    return roll, z


def _refine_onset(t: np.ndarray, dev: np.ndarray, first_flag: int, sigma: float) -> int:
    """
    The problems grow roughly linearly from zero. Fit a line to the first hours after the
    alert and extend it back to where it meets normal: that is the estimated onset.
    """
    lo, hi = max(0, first_flag - 6), min(len(t), first_flag + 36)
    if hi - lo >= 8:
        x = (t[lo:hi] - t[first_flag]) / 3600.0
        slope, icpt = np.polyfit(x, dev[lo:hi], 1)
        if abs(slope) > 1e-6 and np.sign(slope) == np.sign(np.mean(dev[first_flag:hi])):
            hrs_back = icpt / -slope  # hours relative to the alert where the line crosses zero
            target = t[first_flag] + hrs_back * 3600.0
            earliest = t[max(0, first_flag - 48)]
            target = min(max(target, earliest), t[first_flag])
            return int(np.searchsorted(t, target))
    return first_flag


def _gradual_events(P: _Pump, fault_events: list[dict]) -> list[dict]:
    f = P.f
    r = P.run
    if r.sum() < WINDOW * 2:
        return []
    t = P.idx[r]
    ratio = P.flow[r] / P.max_flow
    disp = f.disposal_psi
    dis_dev = P.dis[r] - disp
    pp_dev = P.pp[r] - disp
    leak = 1.0 - P.recv[r] / np.maximum(P.flow[r], 1.0)

    # normal levels, learned from the healthy samples
    healthy = ratio > 0.985
    base_dis = _mode(dis_dev[healthy] if healthy.sum() > 20 else dis_dev, 2.0)
    base_pp = _mode(pp_dev, 2.0)
    sig_dis = _noise(dis_dev, base_dis, 1.0, 8.0)
    sig_pp = _noise(pp_dev, base_pp, 1.0, 8.0)
    sig_ratio = _noise(ratio, 1.0, 0.002, 0.03)
    sig_leak = _noise(leak, 0.0, 0.002, 0.03)

    _, z_ratio = _gradual(P, ratio, 1.0, sig_ratio, -1)
    _, z_dis = _gradual(P, dis_dev, base_dis, sig_dis, -1)
    _, z_pp = _gradual(P, pp_dev, base_pp, sig_pp, -1)
    _, z_leak = _gradual(P, leak, 0.0, sig_leak, +1)

    now_idx = len(P.idx) - 1
    run_pos = np.where(r)[0]
    out = []

    def build(category, z_a, z_b, dev_series, sigma, ev_lines):
        flagged = (np.nan_to_num(z_a) > Z_ALERT) | (np.nan_to_num(z_b) > Z_ALERT)
        for a, b in _runs(flagged, GAP_BRIDGE):
            if b - a + 1 < MIN_RUN:
                continue
            ongoing = run_pos[b] == run_pos[-1] and True
            on_i = _refine_onset(t, dev_series, a, sigma)
            onset = t[on_i]
            detected = t[a]
            end = None
            if not ongoing:
                nxt = t[b + 1] if b + 1 < len(t) else None
                end = nxt
                # The readings are averaged over WINDOW running samples, and that window reaches across a stop.
                # So when the run ends within one window after a long stop (a fault, or the pump held off), the
                # flags after the restart are only the window catching up: the problem ended when the pump stopped.
                gaps = [i for i in range(a, b + 1) if i + 1 < len(t) and t[i + 1] - t[i] > STOP_GAP_S and b - i <= WINDOW]
                if gaps:
                    end = int(t[gaps[-1]]) + SAMPLE_S
            # a pump that went on to fail ends its wear event at the fault
            for fe in fault_events:
                if fe["onset_unix"] >= t[b] and (end is None or fe["onset_unix"] <= end):
                    end, ongoing = fe["onset_unix"], False
                    break
            zpk = float(max(np.nanmax(z_a[a:b + 1]), np.nanmax(z_b[a:b + 1])))
            ev = {
                "category": category,
                "facility_id": f.id,
                "asset_id": f.pump["id"] if category == "pump_degradation" else f.pipeline["id"],
                "onset_unix": int(onset),
                "end_unix": None if (ongoing or end is None) else int(end),
                "status": "ongoing" if ongoing else "resolved",
                "detected_unix": int(detected),
                "confidence": _conf(zpk),
                "evidence": ev_lines(a, b, on_i),
            }
            if ongoing:
                stale_h = (P.idx[-1] - t[-1]) / 3600.0
                if stale_h > 1.0:
                    # the pump is stopped, so these readings can't be re-checked until it restarts
                    ev["confidence"] = round(ev["confidence"] * (0.8 if stale_h > 2 else 0.9), 2)
                    ev["evidence"].append(
                        f"Last confirmed by a running reading {stale_h:.1f} h ago; the pump is stopped, "
                        "so this can't be re-checked until it restarts")
            out.append(ev)

    def leak_lines(a, b, on_i):
        sl = slice(max(a, b - WINDOW + 1), b + 1)
        d = float(np.mean(pp_dev[sl]) - base_pp)
        lf = float(np.mean(leak[sl]))
        hrs = (t[b] - t[on_i]) / 3600
        lines = [f"Pipeline pressure is {abs(d):.0f} psi below its normal level ({d / sig_pp:+.0f} noise widths)"]
        if lf > 2 * sig_leak:
            lines.append(f"Only {100 * (1 - lf):.1f}% of the water the pump sends arrives at the disposal site ({100 * lf:.1f}% missing)")
        if hrs > 1:
            lines.append(f"Getting worse for about {hrs:.1f} h (about {abs(d) / hrs:.1f} psi/h)")
        return lines

    def wear_lines(a, b, on_i):
        sl = slice(max(a, b - WINDOW + 1), b + 1)
        rr = float(np.mean(ratio[sl]))
        d = float(np.mean(dis_dev[sl]) - base_dis)
        hrs = (t[b] - t[on_i]) / 3600
        lines = [f"Pump moves {100 * rr:.1f}% of its rated flow while running (normally about 100%)"]
        if d < -2 * sig_dis:
            lines.append(f"Discharge pressure is {abs(d):.0f} psi below normal")
        if hrs > 1:
            lines.append(f"Losing about {100 * (1 - rr) / hrs:.2f}% of rated flow per hour over {hrs:.1f} h")
        return lines

    build("pipeline_leak", z_pp, z_leak, pp_dev - base_pp, sig_pp, leak_lines)
    build("pump_degradation", z_ratio, z_dis, dis_dev - base_dis, sig_dis, wear_lines)
    return out


def detect_events(ds: Dataset, now: Optional[int] = None) -> list[dict]:
    """All problems found in the telemetry up to `now` (default: the last timestamp)."""
    now = ds.t_last if now is None else min(now, ds.t_last)
    events: list[dict] = []
    for fac_id, f in ds.facilities.items():
        P = _Pump(ds, fac_id, now)
        faults = _fault_events(P)
        events += faults + _gradual_events(P, faults)
    events.sort(key=lambda e: (e["onset_unix"], e["asset_id"]))
    for n, e in enumerate(events, 1):
        e["event_id"] = f"EV-{n:04d}"
        e["system_id"] = ds.facilities[e["facility_id"]].system_id
        e["onset_ts"] = iso(e["onset_unix"])
        e["end_ts"] = iso(e["end_unix"]) if e["end_unix"] else None
        e["detected_ts"] = iso(e["detected_unix"])
    return events
