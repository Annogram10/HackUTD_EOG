"""The 30-second plain-English handoff download."""
from fastapi.testclient import TestClient

import main

c = TestClient(main.app)


def test_brief_is_plain_text_and_short():
    for params in ({"dataset": "full_week", "now": 1791419400}, {"dataset": "snapshot_2026-10-10T0900"}):
        r = c.get("/handoff.txt", params=params)
        assert r.status_code == 200 and r.headers["content-type"].startswith("text/plain")
        assert "attachment" in r.headers["content-disposition"]
        assert len(r.text.split()) <= 150  # about 30 seconds of reading
        assert "Nothing here operates equipment" in r.text


def test_brief_puts_danger_first_with_real_numbers():
    text = c.get("/handoff.txt", params={"dataset": "snapshot_2026-10-10T0900"}).text
    assert text.index("ACT NOW") < text.index("KEEP AN EYE ON")
    assert "S4 Facility A: pump failed, shutdown in 3.0 h" in text
    assert "$3,084 total" in text  # the shared-fleet total from the optimizer


def test_events_json_shape_unchanged():
    ev = c.get("/events.json", params={"dataset": "full_week"}).json()
    assert isinstance(ev, list) and {"event_id", "category", "status", "onset_ts"} <= set(ev[0])
