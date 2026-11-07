"""
Loads one dataset folder: network.json, ops.json, telemetry.csv. Nothing else.

The app NEVER reads answer_key.json. Only these three files are opened, by name,
so a stray answer key sitting in a folder is ignored.
"""

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

DATA_DIR = Path(os.environ.get("NIGHTSHIFT_DATA", Path(__file__).resolve().parents[2] / "data"))
REQUIRED = ("network.json", "ops.json", "telemetry.csv")  # the only files the app opens

_cache: dict = {}


def iso(ts: float) -> str:
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_datasets() -> list[dict]:
    """Every folder in DATA_DIR that has the three files. test/ first, it's the one judges add."""
    out = []
    if DATA_DIR.exists():
        for d in sorted(DATA_DIR.iterdir()):
            if d.is_dir() and all((d / f).exists() for f in REQUIRED):
                out.append({"name": d.name})
    order = lambda n: (0 if n == "test" else 1 if n.startswith("mock") else 2 if n.startswith("snap") else 3, n)
    return sorted(out, key=lambda x: order(x["name"]))


@dataclass
class Facility:
    id: str
    system_id: str
    lat: float
    lon: float
    wells: list[dict]
    tank: dict
    pump: dict
    pipeline: dict
    disposal_psi: float
    response_min: float
    cycle_min: float

    @property
    def lost_revenue_per_hour(self) -> float:
        return 0.0  # filled by Dataset.revenue_per_hour


@dataclass
class Dataset:
    name: str
    network: dict
    ops: dict
    wide: pd.DataFrame  # index = ts_unix, columns = (asset_id, metric)
    facilities: dict = field(default_factory=dict)
    systems: dict = field(default_factory=dict)
    token: str = ""  # changes when the files on disk change, so caches know to refresh

    @property
    def t_first(self) -> int:
        return int(self.wide.index[0])

    @property
    def t_last(self) -> int:  # "now" is the last timestamp in the telemetry
        return int(self.wide.index[-1])

    @property
    def step_s(self) -> int:
        idx = self.wide.index
        return int(np.median(np.diff(idx[:50]))) if len(idx) > 1 else 300

    @property
    def prices(self) -> dict:
        return self.ops["prices"]

    @property
    def repair_hours(self) -> float:
        return float(self.ops["expected_repair_hours"]["pump_failure"])

    @property
    def limits(self) -> dict:
        return self.network.get("defaults", {}).get("tank_limits_pct", {"warning": 85, "shutdown": 92})

    def well_rev_per_hour(self, well: dict) -> float:
        p = self.prices
        return (well["oil_bpd"] * p["oil_per_bbl"] + well["gas_mcfd"] * p["gas_per_mcf"]) / 24.0

    def revenue_per_hour(self, fac_id: str) -> float:
        return sum(self.well_rev_per_hour(w) for w in self.facilities[fac_id].wells)

    def series(self, asset: str, metric: str, now: Optional[int] = None) -> pd.Series:
        s = self.wide[(asset, metric)]
        return s if now is None else s.loc[:now]

    def has(self, asset: str, metric: str) -> bool:
        return (asset, metric) in self.wide.columns


def _read_telemetry(path: Path) -> pd.DataFrame:
    df = pd.read_csv(
        path,
        usecols=["ts_unix", "asset_id", "metric", "value"],
        dtype={"ts_unix": "int64", "asset_id": "string", "metric": "string", "value": "float64"},
    )
    wide = df.set_index(["ts_unix", "asset_id", "metric"])["value"].unstack(["asset_id", "metric"])
    wide.columns = pd.MultiIndex.from_tuples([(str(a), str(m)) for a, m in wide.columns])
    return wide.sort_index()


def _token(folder: Path) -> str:
    return "-".join(str((folder / f).stat().st_mtime_ns) for f in REQUIRED)


def load(name: str) -> Dataset:
    folder = (DATA_DIR / name).resolve()
    if DATA_DIR.resolve() not in folder.parents or not all((folder / f).exists() for f in REQUIRED):
        raise FileNotFoundError(f"dataset '{name}' not found")
    if name in _cache and _cache[name].token == _token(folder):  # reload if someone replaced the files
        return _cache[name]

    network = json.loads((folder / "network.json").read_text())
    ops = json.loads((folder / "ops.json").read_text())
    wide = _read_telemetry(folder / "telemetry.csv")
    ds = Dataset(name=name, network=network, ops=ops, wide=wide, token=_token(folder))

    for s in network["systems"]:
        sid = s["id"]
        ds.systems[sid] = {
            "id": sid,
            "center": s.get("center"),
            "truck_yard": s.get("truck_yard"),
            "disposal_site": s["disposal_site"],
            "fleet_size": ops["systems"][sid]["emergency_fleet_size"],
            "facility_ids": [f["id"] for f in s["facilities"]],
        }
        for f in s["facilities"]:
            o = ops["systems"][sid]["facilities"][f["id"]]
            ds.facilities[f["id"]] = Facility(
                id=f["id"], system_id=sid, lat=f["lat"], lon=f["lon"], wells=f["wells"],
                tank=f["tank"], pump=f["pump"], pipeline=f["pipeline"],
                disposal_psi=s["disposal_site"]["pressure_psi"],
                response_min=o["response_min"], cycle_min=o["cycle_min"],
            )
    _cache[name] = ds
    return ds
