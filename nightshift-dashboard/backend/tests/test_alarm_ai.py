"""Item 1: /alarm never waits for the model. Item 2: alarm_id is well formed and stable."""
import time
import urllib.request

import pytest
from fastapi.testclient import TestClient

import main
from app import risk

ALARM_AT = 1791419400  # full_week: S1 Facility C pump failure, tank trips before the repair ends
c = TestClient(main.app)


@pytest.fixture
def hanging_model(monkeypatch):
    calls = []

    def hang(*a, **k):
        calls.append(1)
        time.sleep(10)
        raise OSError("model down")

    monkeypatch.setenv("NVIDIA_API_KEY", "test-key")
    monkeypatch.setattr(urllib.request, "urlopen", hang)
    risk._ai_cache.clear(); risk._ai_inflight.clear()
    return calls


def test_alarm_makes_no_model_call_and_is_fast(hanging_model):
    c.get("/alarm", params={"dataset": "full_week", "now": ALARM_AT})  # warm the triage cache
    t = time.time()
    r = c.get("/alarm", params={"dataset": "full_week", "now": ALARM_AT})
    assert r.status_code == 200
    assert time.time() - t < 0.5
    assert hanging_model == []
    body = r.json()
    assert body["alarm"] is True and body["level"] == "red"


def test_risk_does_not_wait_for_model(hanging_model):
    c.get("/risk", params={"dataset": "full_week", "now": ALARM_AT, "ai": "false"})  # warm
    t = time.time()
    r = c.get("/risk", params={"dataset": "full_week", "now": ALARM_AT})
    assert r.status_code == 200 and time.time() - t < 1.0
    assert r.json()["ai"].get("pending") is True
    assert r.json()["level"] == "red"  # the rules' level, never the model's


def test_failure_is_cached(monkeypatch):
    calls = []

    def fail(*a, **k):
        calls.append(1)
        raise OSError("model down")

    monkeypatch.setenv("NVIDIA_API_KEY", "test-key")
    monkeypatch.setattr(urllib.request, "urlopen", fail)
    risk._ai_cache.clear(); risk._ai_inflight.clear()
    for _ in range(5):
        c.get("/risk/note", params={"dataset": "full_week", "now": ALARM_AT})
        time.sleep(0.2)
    assert len(calls) == 1
    assert c.get("/risk/note", params={"dataset": "full_week", "now": ALARM_AT}).json()["status"] == "unavailable"


def test_ai_never_changes_level(monkeypatch):
    """Even if the model says red at a quiet moment, the level stays the rules' level."""
    import io, json
    ds = main.ds_for("full_week")
    quiet = int(ds.t_first) + 7 * 3600

    def says_red(*a, **k):
        msg = {"level": "red", "headline": "Danger", "why": "Looks bad.", "money": ""}
        return io.BytesIO(json.dumps({"choices": [{"message": {"content": json.dumps(msg)}}]}).encode())

    class Ctx(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setenv("NVIDIA_API_KEY", "test-key")
    monkeypatch.setattr(urllib.request, "urlopen", lambda *a, **k: Ctx(says_red().getvalue()))
    risk._ai_cache.clear(); risk._ai_inflight.clear()
    before = risk.assess(ds, quiet, use_ai=False)
    risk.assess(ds, quiet, use_ai=True)
    time.sleep(0.5)
    after = risk.assess(ds, quiet, use_ai=True)
    assert after["level"] == before["level"]
    assert after["alarm"] == before["alarm"] and after["alarm_id"] == before["alarm_id"]
