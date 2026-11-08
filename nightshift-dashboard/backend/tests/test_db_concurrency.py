"""Item 3: the first alarm on a brand-new database must not crash when many requests arrive at once."""
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient

import main

ALARM_AT = 1791419400


def test_20_concurrent_alarms_on_empty_db(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "empty.db")
    main.init_db()
    main.run_triage(main.ds_for("full_week"), ALARM_AT)  # warm, so the requests really overlap on the database
    c = TestClient(main.app)
    with ThreadPoolExecutor(20) as pool:
        codes = list(pool.map(lambda _: c.get("/alarm", params={"dataset": "full_week", "now": ALARM_AT}).status_code, range(20)))
    assert codes == [200] * 20
    with main.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM shifts WHERE id = 'alarms-full_week'").fetchone()[0] == 1
        n = conn.execute("SELECT COUNT(*) FROM flags WHERE id LIKE 'alarm-%'").fetchone()[0]
        assert n == len({f["id"] for f in conn.execute("SELECT id FROM flags").fetchall()})
