"""Item 11: one parser; naive means UTC."""
import pytest

from app.timeutil import parse_ts

E = 1791419400  # 2026-10-08T00:30:00Z


@pytest.mark.parametrize("text", ["2026-10-08T00:30:00Z", "2026-10-08T00:30:00+00:00", "2026-10-07T18:30:00-06:00",
                                  "2026-10-08T00:30:00", "2026-10-08 00:30:00", E, float(E)])
def test_parse(text):
    assert parse_ts(text) == E


def test_fractional_and_date():
    assert parse_ts("2026-10-08T00:30:00.500Z") == E
    assert parse_ts("2026-10-08") == E - 30 * 60


def test_seen_by_handles_offsets():
    import main
    flags = [{"timestamp": "2026-10-07T18:30:00-06:00"}, {"timestamp": "2026-10-08T00:31:00"}]
    assert main.seen_by(flags, E) == flags[:1]
