"""The phone can ask for a facility the way speech recognition writes it, and gets the slider's moment."""
import pytest
from fastapi.testclient import TestClient

import main

c = TestClient(main.app)


@pytest.mark.parametrize("heard", ["S1_FACILITY_C", "S1 Facility C", "s one facility c", "S 1 facility C", "s1 c", "S One Facility C."])
def test_spoken_names_resolve(heard):
    assert main.resolve_facility(main.ds_for("full_week"), heard) == "S1_FACILITY_C"


def test_facility_by_spoken_name_follows_the_clock():
    c.post("/clock", json={"dataset": "full_week", "now": 1791419400})
    try:
        body = c.get("/facility/s one facility c").json()
        assert body["id"] == "S1_FACILITY_C" and body["mode"] == "replay" and body["as_of"] == "2026-10-08T00:30:00Z"
        assert "pump has failed" in body["spoken_text"]
    finally:
        c.post("/clock", json={"dataset": "full_week", "now": None})
