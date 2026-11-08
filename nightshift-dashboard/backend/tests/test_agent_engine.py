"""Item 14: every agent response says which engine really ran."""
import time

from fastapi.testclient import TestClient

import main


def test_engine_reported_offline(monkeypatch):
    monkeypatch.delenv("NVIDIA_API_KEY", raising=False)
    c = TestClient(main.app)
    run = c.post("/agent/run", params={"dataset": "snapshot_2026-10-08T1200"}).json()
    for _ in range(100):
        if run["status"] != "running":
            break
        time.sleep(0.1)
        run = c.get("/agent/trace", params={"dataset": "snapshot_2026-10-08T1200"}).json()
    assert run["engine"] == "offline" and run["status"] == "done"
    assert [s for s in run["steps"] if s["kind"] == "tool"], "the trace shows the real tool calls"
