"""Item 5: one severity rule, and every endpoint agrees with it."""
import pytest
from fastapi.testclient import TestClient

import main
from app import triage
from app.triage import FORECAST_QUANTILE, severity

NOW = 1_800_000_000
END_IN_5H = "2027-01-15T13:00:00Z"  # NOW + 5 h


def fail(tripped=False, hours=None):
    h = None if hours is None else {"p10": hours, "p50": hours, "p90": hours}
    return {"category": "pump_failure", "facility_id": "S1_FACILITY_A", "tripped": tripped, "hours_to_limit": h,
            "repair_end_ts": END_IN_5H}


@pytest.mark.parametrize("alert, measured, expected", [
    (fail(tripped=True), None, "high"),
    (fail(hours=2.0), None, "high"),          # tank reaches shutdown 3 h before the repair ends
    (fail(hours=8.0), None, "medium"),        # the tank can wait out the repair
    (fail(hours=None), None, "medium"),       # no forecast: cannot claim danger
    ({"category": "pipeline_leak", "facility_id": "S1_FACILITY_A"}, (0.10, 0.0), "medium"),
    ({"category": "pipeline_leak", "facility_id": "S1_FACILITY_A"}, (0.02, 0.0), "low"),
    ({"category": "pipeline_leak", "facility_id": "S1_FACILITY_A"}, None, "low"),  # pump stopped: cannot measure
    ({"category": "pump_degradation", "facility_id": "S1_FACILITY_A"}, (0.0, 0.30), "low"),
])
def test_severity_rule(monkeypatch, alert, measured, expected):
    monkeypatch.setattr(triage, "drop", lambda ds, a, now: measured)
    assert severity(alert, NOW, ds=None) == expected


def test_quantile_is_a_named_constant():
    assert FORECAST_QUANTILE in ("p10", "p50", "p90")


def test_endpoints_agree():
    c = TestClient(main.app)
    p = {"dataset": "full_week", "now": 1791419400}
    tri = main.run_triage(main.ds_for("full_week"), p["now"])
    sev = {}
    for a in tri["alerts"]:
        sev[a["facility_id"]] = max(sev.get(a["facility_id"], "low"), a["severity"], key=triage.SEVERITY_RANK.get)
    color = {"high": "red", "medium": "amber", "low": "green"}
    alarm = c.get("/alarm", params=p).json()
    assert alarm["alarm"] == ("high" in sev.values())
    risk = c.get("/risk", params={**p, "ai": "false"}).json()
    assert risk["facilities"] == {f: color[s] for f, s in sev.items()}
    for pt in c.get("/map", params=p).json()["facilities"]:
        assert pt["severity"] == sev.get(pt["id"], "none")
    for row in c.get("/next-shift", params=p).json():
        if row["severity"] != "none":
            assert row["severity"] == sev[row["equipment_id"]]
            assert triage.SEVERITY_RANK[row["level"]] >= triage.SEVERITY_RANK[row["severity"]]
    for a in c.get("/alerts", params=p).json():
        assert a["severity"] == triage.SEVERITY_RANK[a["severity_word"]]
    ov = c.get("/overview", params=p).json()
    for a in ov["alerts"]:
        assert a["level"] == color[a["severity"]]
    # a pump failure the tank can wait out is never called Danger anywhere
    for a in tri["alerts"]:
        if a["severity"] == "medium" and a["category"] == "pump_failure":
            assert a["facility_id"] not in alarm["facility_ids"]
