"""A slow camera check must not hold up other requests (prioritize, alarm) from the phone."""
import threading
import time

import httpx
import pytest
import uvicorn

import main
from app import vision


@pytest.fixture
def server(monkeypatch):
    def slow(_url):
        time.sleep(3)
        return {"available": True, "finding": "none", "description": "nothing", "confidence": 0.1}
    monkeypatch.setattr(vision, "check_image", slow)
    cfg = uvicorn.Config(main.app, host="127.0.0.1", port=8765, log_level="error")
    srv = uvicorn.Server(cfg)
    t = threading.Thread(target=srv.run, daemon=True)
    t.start()
    while not srv.started:
        time.sleep(0.05)
    yield "http://127.0.0.1:8765"
    srv.should_exit = True
    t.join(5)


def test_prioritize_answers_while_a_camera_check_is_running(server):
    flag = "vis-test-flag"
    with httpx.Client() as c:
        c.post(f"{server}/report", json={"dataset": "full_week", "shift_id": "vis-test", "started_at": "2026-10-07T18:00:00Z",
                                         "ended_at": "2026-10-08T06:00:00Z", "flags": [{"id": flag, "type": "leak", "facility": "S1_FACILITY_C",
                                                                                        "created_at": "2026-10-08T01:00:00Z"}]})
        slow = threading.Thread(target=lambda: httpx.post(f"{server}/vision/check", content=b"\xff\xd8 jpeg", timeout=10))
        slow.start()
        time.sleep(0.3)  # the camera check is now waiting on the model
        t = time.time()
        r = c.post(f"{server}/flag/{flag}/prioritize", timeout=10)
        took = time.time() - t
        slow.join()
    assert r.status_code == 200 and r.json()["priority"] == 1
    assert took < 0.5, f"prioritize waited {took:.1f}s behind the camera check"
