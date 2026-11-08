"""Flags from the phone are saved at the data's time (the replay moment), not the phone's real clock."""
import uuid

from fastapi.testclient import TestClient

import main
from app.timeutil import parse_ts

c = TestClient(main.app)
T = 1791419400  # full_week replay moment, 2026-10-08T00:30:00Z


def test_phone_times_move_onto_the_replay_moment():
    c.post("/clock", json={"dataset": "full_week", "now": T})
    try:
        sid = f"t-{uuid.uuid4().hex[:6]}"
        body = {"dataset": "full_week", "shift_id": sid, "client_id": str(uuid.uuid4()),
                "started_at": "2026-11-08T15:01:06Z", "ended_at": "2026-11-08T15:02:57Z", "generated_at": "2026-11-08T15:02:57Z",
                "flags": [{"id": f"{sid}-a", "type": "leak", "facility": "S1_FACILITY_C", "created_at": "2026-11-08T15:02:14Z", "source": "voice"}]}
        assert c.post("/report", json=body).status_code == 200
        shift = c.get(f"/shifts/{sid}").json()
        flag = shift["flags"][0]
        assert parse_ts(flag["timestamp"]) == T - 43  # raised 43 s before upload -> 43 s before the replay moment
        assert parse_ts(shift["ended_at"]) == T
        # and the dashboard at that moment sees it
        report = c.get("/report", params={"shift_id": sid, "now": T}).json()
        assert report["totals"]["total"] == 1
    finally:
        c.post("/clock", json={"dataset": "full_week", "now": None})


def test_times_inside_the_data_are_kept():
    sid = f"t-{uuid.uuid4().hex[:6]}"
    body = {"dataset": "full_week", "shift_id": sid, "started_at": "2026-10-07T18:00:00Z", "ended_at": "2026-10-08T06:00:00Z",
            "generated_at": "2026-10-08T06:00:00Z",
            "flags": [{"id": f"{sid}-a", "type": "leak", "facility": "S1_FACILITY_C", "created_at": "2026-10-08T01:00:00Z"}]}
    c.post("/report", json=body)
    assert c.get(f"/shifts/{sid}").json()["flags"][0]["timestamp"] == "2026-10-08T01:00:00Z"
