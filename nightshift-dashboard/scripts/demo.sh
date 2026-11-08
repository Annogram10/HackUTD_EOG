#!/bin/bash
# Judging-day launcher: production build of the dashboard (next build && next start, not next dev) + the backend.
# Ctrl+C stops both.
#
# Env (put secrets in backend/.env, which is git-ignored):
#   NVIDIA_API_KEY      Nemotron (AI notes, agent). Without it everything still works, rules + offline script.
#   NIGHTSHIFT_KEY      optional shared secret; when set, every write needs header X-API-Key (dashboard gets it too).
#   ALLOWED_ORIGINS     dashboard origin(s) for CORS (default http://localhost:3000,http://127.0.0.1:3000)
#   API_PORT / WEB_PORT default 8000 / 3000
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f backend/.env ] && set -a && . backend/.env && set +a

API_PORT="${API_PORT:-8000}"
WEB_PORT="${WEB_PORT:-3000}"
export NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_API_URL:-http://localhost:$API_PORT}"
export NEXT_PUBLIC_NIGHTSHIFT_KEY="${NIGHTSHIFT_KEY:-}"
export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-http://localhost:$WEB_PORT,http://127.0.0.1:$WEB_PORT}"

[ -x backend/.venv/bin/uvicorn ] || { echo "Missing backend/.venv. Run: cd backend && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"; exit 1; }
[ -d frontend/node_modules ] || (cd frontend && npm ci)
[ -z "${NVIDIA_API_KEY:-}" ] && echo "Note: NVIDIA_API_KEY not set. Rules + offline agent script only (labelled as such on screen)."
[ -z "${NIGHTSHIFT_KEY:-}" ] && echo "Note: NIGHTSHIFT_KEY not set. Writes are open (dev mode)."

echo "Building the dashboard (production)..."
(cd frontend && npm run build)

(cd backend && exec .venv/bin/uvicorn main:app --host 0.0.0.0 --port "$API_PORT") &
BACK=$!
(cd frontend && exec npx next start -p "$WEB_PORT") &
FRONT=$!
trap 'kill $BACK $FRONT 2>/dev/null' INT TERM EXIT

for _ in $(seq 1 60); do curl -sf "http://localhost:$API_PORT/health" >/dev/null && break; sleep 0.5; done
IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
echo
echo "  Dashboard:  http://localhost:$WEB_PORT"
echo "  API docs:   http://localhost:$API_PORT/docs"
[ -n "$IP" ] && echo "  Phone/glasses (same Wi-Fi): http://$IP:$API_PORT"
echo "  Clock:      curl http://localhost:$API_PORT/clock"
echo
wait
