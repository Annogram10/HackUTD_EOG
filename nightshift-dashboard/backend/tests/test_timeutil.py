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


def test_flags_are_never_hidden_by_time():
    """Flags stay visible until deleted, even ones stamped later than the replay moment."""
    import main
    flags = [{"timestamp": "2026-10-07T18:30:00-06:00"}, {"timestamp": "2026-11-08T15:02:14Z"}]
    assert main.seen_by(flags, E) == flags
