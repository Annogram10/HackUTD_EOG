"""Every test run gets its own empty database, so tests never touch backend/nightshift.db."""
import os
import sys
import tempfile
from pathlib import Path

_tmp = tempfile.mkdtemp(prefix="nightshift-test-")
os.environ["NIGHTSHIFT_DB"] = str(Path(_tmp) / "test.db")
os.environ.pop("NIGHTSHIFT_KEY", None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
