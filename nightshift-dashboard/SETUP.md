# NightShift: setup

## Backend
A fresh clone has no database or photos (they are git-ignored). `seed.py` below creates demo shifts; real phone uploads fill the same database.
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

- `app/vision.py` + `POST /vision/check`: one glasses camera frame checked by `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` (override with `NEMOTRON_VISION_MODEL`). Flags only; a human confirms.

## For the iPhone / glasses
App format (what the phone app calls):
- `GET /alerts`, `GET /facility/{id}`, `GET /handoff`: each has a `spoken_text` with numbers spelled out for the glasses.
- `POST /report`: one JSON body for a whole round, photos as base64 (`photo_jpeg_base64`). Same shift id replaces the shift; the same facility and type replaces the older flag.
- `POST /vision/check`: raw JPEG (`Content-Type: image/jpeg`), returns `{flag, type, confidence, description}`. Needs `NVIDIA_API_KEY`.
- `GET /alarm`: poll every few seconds. When `alarm` is true, sound the alarm and speak `spoken_text`. `alarm_id` changes for each new danger.
- `GET /map`: every facility with lat/lon, already ordered by importance.
- `POST /flag/{id}/confirm | /dismiss | /reopen | /note`, `POST /flag/{id}/photo` (raw JPEG), `DELETE /flag/{id}/photo`.

Dashboard routes: `/overview`, `/risk` (danger check, rules plus the AI), `/timeline` (time-travel bar), `/evidence` (what dropped), `/next-shift`, `/report`, `/agent/trace`, `/events.json`. Most take `?dataset=` and `?now=` (unix seconds) for time travel. `POST /clock` makes the phone and glasses follow the dashboard's replay time.

Phone to laptop: expose port 8000 with a tunnel (for example `ngrok http --url=<your-domain> 8000`) and put that address in the phone app's `Config.baseURL`.

Tuning: the yellow thresholds are `LEAK_MISSING_AMBER` and `WEAR_LOSS_AMBER` in `backend/app/risk.py`.

## Start everything
`./start.sh` from this folder starts the backend and the frontend. Put `NVIDIA_API_KEY=nvapi-...` in `backend/.env` (git-ignored) so you never have to export it. Ctrl+C stops both.

## Judging day: getting EOG's test/ folder
```bash
dev/get_test.sh        # pulls their repo, copies test/ (3 files only) into data/test, seeds demo shifts for it
```
Then refresh the dashboard and pick **test** in the Dataset switcher (it is listed first). No backend restart needed.
- If it says `'test' is not in the repo yet`, they haven't published it; run it again later.
- To practice with any existing folder: `dev/get_test.sh history/mock_test_2026-10-10T1530 practice`.
- Check a dataset end to end: `backend/.venv/bin/python dev/rehearse.py test` (needs `pip install httpx`).
