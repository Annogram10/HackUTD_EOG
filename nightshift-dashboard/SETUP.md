# NightShift: setup

## Backend
```bash
cd backend
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python seed.py            # fake iPhone uploads (shifts + flags) for every dataset in data/
.venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8000
```
API docs: http://localhost:8000/docs

## Frontend
```bash
cd frontend && npm install && npm run dev      # http://localhost:3000
```
Backend on another laptop: `frontend/.env.local` with `NEXT_PUBLIC_API_URL=http://<ip>:8000`.

## Datasets (EOG's files)
`data/<name>/` holds `network.json`, `ops.json`, `telemetry.csv`. The app reads only those three files.
`answer_key.json` is never loaded; the practice keys live in `dev/answer_keys/` and are used only by `python dev/evaluate.py`.
**At judging: drop the `test/` folder into `data/`, run `python seed.py` (optional, for demo shifts), refresh.** It appears first in the dataset picker. Override the location with `NIGHTSHIFT_DATA=/path`.

## What is code and what is the agent
- `app/detect.py`: pump failure / leak / worn pump from the readings (rules, no AI). `python dev/evaluate.py` finds 23/23 practice events, 0 extra.
- `app/forecast.py`: countdown to shutdown (p10 / p50 / p90).
- `app/optimize.py`: cheapest plan (trucks x trips, well shut-ins, or letting the tank trip), a system's failures planned together on the shared fleet.
- `app/agent.py`: the triage agent. Starts by itself on first request for a dataset, calls tools for every number, saves the handoff.
  - With `NVIDIA_API_KEY` set (export it in the shell that starts uvicorn; never commit it), `nvidia/nemotron-3.5-super-vl-120b-a12b` (override with `NEMOTRON_MODEL`) drives the tool calls with thinking on.
  - Without a key it runs the same tools in a fixed script and the Agent trace page says so. Weather is the real Open-Meteo API.

- `app/vision.py` + `POST /vision/check {image_url}`: one glasses camera frame checked by `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` (override with `NEMOTRON_VISION_MODEL`). Flags only; a human confirms.

## For the iPhone / glasses
- `POST /shifts/upload` a whole shift: `{dataset?, date, operator, started_at, ended_at, route_planned[], route_walked[], flags[]}` (stops and `location` are facility ids or names like `S1_FACILITY_C` / "S1 Facility C"). Flag: `{type, location, photo_url, timestamp, status, note?, trigger: "camera"|"data", reason?}`
- `POST /flag/{id}/confirm | /dismiss | /note` (`{note, author: "operator"|"control"}`)
- `GET /voice/alerts?dataset=` sentences for the glasses; `GET /voice/facility/{id}?dataset=` answer to "what's the status of Facility C?"
- `GET /events.json?dataset=` export in EOG's format

## Start everything
`./start.sh` from this folder starts the backend and the frontend. Put `NVIDIA_API_KEY=nvapi-...` in `backend/.env` (git-ignored) so you never have to export it. Ctrl+C stops both.

## Judging day: getting EOG's test/ folder
```bash
dev/get_test.sh        # pulls their repo, copies test/ (3 files only) into data/test, seeds demo shifts for it
```
Then refresh the dashboard and pick **test** in the Dataset switcher (it is listed first). No backend restart needed.
- If it says `'test' is not in the repo yet`, they haven't published it; run it again later.
- To practice with any existing folder: `dev/get_test.sh history/mock_test_2026-10-10T1530 practice`.
- Check a dataset end to end: `backend/.venv/bin/python dev/rehearse.py test` (needs `pip install httpx`, already in the venv).
