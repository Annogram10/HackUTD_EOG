"""Item 4: every endpoint follows the shared replay clock and says which mode it is in."""
import pytest
from fastapi.testclient import TestClient

import main
from app import dataset as D

c = TestClient(main.app)
T = 1791419400  # full_week, S1 Facility C alarm
FAC = "S1_FACILITY_C"


@pytest.fixture
def replay():
    r = c.post("/clock", json={"dataset": "full_week", "now": T})
    assert r.status_code == 200
    yield
    c.post("/clock", json={"dataset": "full_week", "now": None})


def test_clock_get_and_persist(replay):
    body = c.get("/clock").json()  # no dataset given: the one the dashboard set
    assert body == {"dataset": "full_week", "now": T, "now_ts": D.iso(T), "mode": "replay", "live": False}
    main.CLOCK.clear(); main.ACTIVE["dataset"] = None
    main._load_clock()  # as after a backend restart
    assert c.get("/clock").json()["now"] == T


def test_live_after_clear():
    c.post("/clock", json={"dataset": "full_week", "now": None})
    body = c.get("/clock", params={"dataset": "full_week"}).json()
    assert body["mode"] == "live" and body["now"] is None


@pytest.mark.parametrize("path", ["/alarm", "/map", f"/facility/{FAC}", "/handoff", "/overview", "/risk", "/report"])
def test_endpoints_follow_clock(replay, path):
    if path == "/report":  # needs an uploaded shift
        c.post("/report", json={"dataset": "full_week", "shift_id": "t-clock", "started_at": "2026-10-04T18:00:00Z",
                                "ended_at": "2026-10-05T06:00:00Z", "flags": []})
        body = c.get(path, params={"shift_id": "t-clock"}).json()
        assert body["mode"] == "replay"
        return
    body = c.get(path).json()  # no dataset and no ?now=: the phone's call
    assert body["mode"] == "replay", body
    assert body.get("as_of", body.get("now_ts")) == D.iso(T)


def test_voice_and_alerts_follow_clock(replay):
    ds = main.ds_for("full_week")
    at_t = main.run_triage(ds, T)["alerts"]
    assert len(c.get("/voice/alerts").json()) == len(at_t)
    assert len(c.get("/alerts").json()) == len(at_t)


def test_facility_spoken_text_matches_screen(replay):
    body = c.get(f"/facility/{FAC}").json()
    level = next(r["value"] for r in body["readings"] if r["label"] == "Tank level")
    expected = main.voice_facility(FAC, "full_week", T)["text"]
    assert body["spoken_text"] == expected
    latest = main.voice_facility(FAC, "full_week", int(main.ds_for("full_week").t_last))["text"]
    assert latest != expected  # really built at the replay moment, not the latest reading
    assert level == main._facility_card(main.ds_for("full_week"), main.run_triage(main.ds_for("full_week"), T), FAC)["level_pct"]
