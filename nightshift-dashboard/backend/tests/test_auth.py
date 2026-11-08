"""Item 9: writes need X-API-Key when NIGHTSHIFT_KEY is set; reads stay open; CORS only for allowed origins."""
import pytest
from fastapi.testclient import TestClient

import main

c = TestClient(main.app)
WRITES = [("post", "/clock", {"json": {"dataset": "full_week", "now": None}}),
          ("post", "/flag/nope/dismiss", {}), ("post", "/report", {"json": {"dataset": "full_week"}}),
          ("post", "/agent/run", {}), ("delete", "/flag/nope", {}), ("post", "/shifts/upload", {"json": {}})]


@pytest.fixture
def keyed(monkeypatch):
    monkeypatch.setattr(main, "API_KEY", "s3cret")


@pytest.mark.parametrize("method, path, kw", WRITES)
def test_write_without_key_is_401(keyed, method, path, kw):
    assert getattr(c, method)(path, **kw).status_code == 401
    assert getattr(c, method)(path, headers={"X-API-Key": "wrong"}, **kw).status_code == 401


def test_write_with_key_passes(keyed):
    r = c.post("/clock", json={"dataset": "full_week", "now": None}, headers={"X-API-Key": "s3cret"})
    assert r.status_code == 200


def test_reads_stay_open(keyed):
    assert c.get("/clock").status_code == 200
    assert c.get("/health").status_code == 200


def test_dev_mode_without_key(monkeypatch):
    monkeypatch.setattr(main, "API_KEY", None)
    assert c.post("/clock", json={"dataset": "full_week", "now": None}).status_code == 200


def test_cors_allowlist():
    ok = c.get("/health", headers={"Origin": "http://localhost:3000"})
    assert ok.headers.get("access-control-allow-origin") == "http://localhost:3000"
    bad = c.get("/health", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in bad.headers


def test_401_carries_cors_headers(keyed):
    r = c.post("/clock", json={}, headers={"Origin": "http://localhost:3000"})
    assert r.status_code == 401 and r.headers.get("access-control-allow-origin") == "http://localhost:3000"
