#!/bin/bash
# Pull EOG's repo and install a dataset folder from it as data/<name> (default: test).
#
#   dev/get_test.sh                        judging day: copies the repo's test/ into data/test
#   dev/get_test.sh <folder-in-repo> [as]  practice: e.g. dev/get_test.sh history/mock_test_2026-10-10T1530 test
#
# Only network.json, ops.json and telemetry.csv are copied. answer_key.json is never copied.
set -e
cd "$(dirname "$0")/.."
REPO_URL="${EOG_REPO:-https://github.com/nihaal419/HackUTD-ZeroDay}"
SRC="${1:-test}"
AS="${2:-test}"
CLONE=dev/eog-repo

if [ -d "$CLONE/.git" ]; then
  echo "Pulling latest from $REPO_URL ..."
  git -C "$CLONE" pull --ff-only
else
  echo "Cloning $REPO_URL ..."
  git clone --depth 1 "$REPO_URL" "$CLONE"
fi

# judging day: if test/ isn't at the repo root, look one or two levels down for a folder with that name
if [ ! -d "$CLONE/$SRC" ] && [ "$SRC" = "test" ]; then
  FOUND=$(find "$CLONE" -maxdepth 3 -type d -name test -not -path "*/.git/*" | head -1)
  [ -n "$FOUND" ] && SRC="${FOUND#$CLONE/}" && echo "Found test folder at: $SRC"
fi

if [ ! -d "$CLONE/$SRC" ]; then
  echo "ERROR: '$SRC' is not in the repo yet. Folders available:"; ls "$CLONE" "$CLONE/history" 2>/dev/null; exit 1
fi
for f in network.json ops.json telemetry.csv; do
  [ -f "$CLONE/$SRC/$f" ] || { echo "ERROR: $SRC/$f is missing"; exit 1; }
done

mkdir -p "data/$AS"
for f in network.json ops.json telemetry.csv; do cp "$CLONE/$SRC/$f" "data/$AS/$f"; done
echo "Installed $SRC as data/$AS ($(wc -l < data/$AS/telemetry.csv) telemetry rows)."

backend/.venv/bin/python backend/seed.py "$AS"
echo
echo "Done. Refresh the dashboard (the backend notices the new files, no restart needed) and pick '$AS' in the Dataset switcher."
