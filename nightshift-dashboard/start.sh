#!/bin/bash
# Starts the backend (port 8000) and the frontend (port 3000). Ctrl+C stops both.
# Put your key in backend/.env as:  NVIDIA_API_KEY=nvapi-...   (that file is git-ignored)
cd "$(dirname "$0")"
[ -f backend/.env ] && set -a && . backend/.env && set +a
[ -z "$NVIDIA_API_KEY" ] && echo "Note: NVIDIA_API_KEY not set, the agent will use the offline script."

(cd backend && .venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000) &
BACK=$!
(cd frontend && npm run dev) &
FRONT=$!
trap "kill $BACK $FRONT 2>/dev/null" INT TERM EXIT
IP=$(ipconfig getifaddr en0 2>/dev/null)
echo "Dashboard: http://localhost:3000   API: http://localhost:8000/docs"
[ -n "$IP" ] && echo "Phone/glasses base URL: http://$IP:8000   (same Wi-Fi as this laptop)"
wait
