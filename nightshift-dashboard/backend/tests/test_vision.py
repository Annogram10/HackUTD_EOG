"""Item 13: the camera check fails fast and plainly."""
import time
import urllib.request

from fastapi.testclient import TestClient

import main
from app import vision


def test_timeout_is_15s():
    assert vision.VISION_TIMEOUT_S == 15


def test_failure_is_plain(monkeypatch):
    seen = {}

    def boom(req, timeout):
        seen["timeout"] = timeout
        raise OSError("timed out")

    monkeypatch.setenv("NVIDIA_API_KEY", "k")
    monkeypatch.setattr(urllib.request, "urlopen", boom)
    r = TestClient(main.app).post("/vision/check", content=b"\xff\xd8\xff fake jpeg", headers={"Content-Type": "image/jpeg"})
    body = r.json()
    assert r.status_code == 200 and body["available"] is False and body["flag"] is False
    assert body["message"] == vision.UNAVAILABLE and seen["timeout"] == 15
