"""Item 10: /report is idempotent on client_id and keeps the audit trail; old clients keep the old behaviour."""
import uuid

from fastapi.testclient import TestClient

import main

c = TestClient(main.app)


def body(shift, flags, client_id=None):
    b = {"dataset": "full_week", "shift_id": shift, "started_at": "2026-10-05T18:00:00Z", "ended_at": "2026-10-06T06:00:00Z",
         "flags": flags}
    if client_id:
        b["client_id"] = client_id
    return b


LEAK1 = {"id": "r-a", "type": "leak", "facility": "S1_FACILITY_C", "created_at": "2026-10-05T20:00:00Z"}
LEAK2 = {"id": "r-b", "type": "leak", "facility": "S1_FACILITY_C", "created_at": "2026-10-05T22:00:00Z"}


def test_same_client_id_saved_once():
    cid, shift = str(uuid.uuid4()), f"rep-{uuid.uuid4().hex[:6]}"
    first = c.post("/report", json=body(shift, [LEAK1], cid)).json()
    again = c.post("/report", json=body(shift, [LEAK1, LEAK2], cid)).json()  # a retry, even with changed content
    assert first["duplicate"] is False and again["duplicate"] is True
    assert again["flags_saved"] == first["flags_saved"] == 1
    assert len(c.get(f"/shifts/{shift}").json()["flags"]) == 1


def test_new_client_id_is_new_record_and_keeps_history():
    shift = f"rep-{uuid.uuid4().hex[:6]}"
    c.post("/report", json=body(shift, [LEAK1], str(uuid.uuid4())))
    c.post("/report", json=body(shift, [LEAK2], str(uuid.uuid4())))
    ids = {f["id"] for f in c.get(f"/shifts/{shift}").json()["flags"]}
    assert ids == {"r-a", "r-b"}  # same facility + type, both kept


def test_old_clients_keep_dedupe():
    shift = f"rep-{uuid.uuid4().hex[:6]}"
    r = c.post("/report", json=body(shift, [LEAK1, LEAK2])).json()
    assert r["replaced_duplicates"] == 1 and "duplicate" not in r
    assert [f["id"] for f in c.get(f"/shifts/{shift}").json()["flags"]] == ["r-b"]
