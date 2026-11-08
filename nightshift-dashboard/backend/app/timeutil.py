"""One timestamp parser for the whole backend. Naive timestamps (no zone) are UTC, like all of EOG's data."""

from datetime import datetime, timezone
from typing import Union


def parse_ts(ts: Union[str, int, float, datetime]) -> int:
    """ISO 8601 text ("...Z", "...+00:00", "...-06:00" or naive), a datetime, or epoch seconds -> epoch seconds (int)."""
    if isinstance(ts, (int, float)):
        return int(ts)
    if isinstance(ts, datetime):
        d = ts
    else:
        s = str(ts).strip()
        if s.endswith(("Z", "z")):
            s = s[:-1] + "+00:00"
        if len(s) == 10:  # a bare date
            s += "T00:00:00"
        d = datetime.fromisoformat(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return int(d.timestamp())
