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
- `GET /clock`: `{dataset, now, now_ts, mode}`. Read the dataset from here; `mode` is `live` or `replay`.
- `POST /report`: one JSON body for a whole round, photos as base64 (`photo_jpeg_base64`). Send a new `client_id` (UUID) per send: a retry with the same one is not saved twice. Without `client_id`, the same shift id replaces the shift and the same facility + type replaces the older flag.
- `POST /vision/check`: raw JPEG (`Content-Type: image/jpeg`), returns `{flag, type, confidence, description}`. Needs `NVIDIA_API_KEY`.
- `GET /alarm`: poll every few seconds (rules only, never waits on the AI). When `alarm` is true, sound the alarm and speak `spoken_text`. `alarm_id` is `<dataset>:<facility>:pf-<onset>` of the worst danger; it changes only for a new situation. Also `severity`, `mode`, `as_of`, optional `note`.
- `GET /map`: every facility with lat/lon, already ordered by importance, with `severity` per facility, `mode`, `as_of`.
- Every write (`POST`/`PUT`/`DELETE`) needs header `X-API-Key: <NIGHTSHIFT_KEY>` when the backend runs with `NIGHTSHIFT_KEY` set.
- `POST /flag/{id}/confirm | /dismiss | /reopen | /note`, `POST /flag/{id}/photo` (raw JPEG), `DELETE /flag/{id}/photo`.

Severity is one scale everywhere (`backend/app/triage.py`, `severity()`): high = red, alarm; medium = amber, check soon; low = minor.

Dashboard routes: `/overview`, `/risk` (danger check by the rules; the AI only adds a note), `/risk/note`, `/timeline` (time-travel bar), `/evidence` (what dropped), `/next-shift`, `/report`, `/agent/trace`, `/events.json`. Most take `?dataset=` and `?now=` (unix seconds) for time travel. `POST /clock` makes the phone and glasses follow the dashboard's replay time.

Phone to laptop: expose port 8000 with a tunnel (for example `ngrok http --url=<your-domain> 8000`) and put that address in the phone app's `Config.baseURL`.

Tuning: `FORECAST_QUANTILE` (p10, early warning) and `LEAK_MISSING_MEDIUM` (6%) in `backend/app/triage.py`.

## Start everything
Development: `./start.sh` from this folder starts the backend and the frontend (`next dev`). Put `NVIDIA_API_KEY=nvapi-...` in `backend/.env` (git-ignored) so you never have to export it. Ctrl+C stops both.

## Judging day
1. `backend/.env` (git-ignored):
   ```
   NVIDIA_API_KEY=nvapi-...        # optional; without it the screens say "offline script" / "rules only"
   NIGHTSHIFT_KEY=<long random>    # optional; only once the iPhone app sends X-API-Key
   ALLOWED_ORIGINS=http://localhost:3000
   ```
2. Get the test data (below), then `backend/.venv/bin/python dev/rehearse.py test`.
3. `scripts/demo.sh`: builds the dashboard (`next build && next start`, not dev mode), starts the backend, prints the URLs.
4. Tunnel for the phone: `ngrok http --url=<your-domain> 8000`.
5. Before going on stage: `backend/.venv/bin/python -m pytest backend/tests -q` (all green), and check the banner under the menu says **LIVE** or **REPLAY** as intended.
   The dashboard opens in replay at the dataset start (+6 h) and pushes that moment to the phone; press **Latest** on the time bar for live.

Env used by the frontend at build time: `NEXT_PUBLIC_API_URL` (required for a production build; the page shows an error if missing) and `NEXT_PUBLIC_NIGHTSHIFT_KEY` (demo.sh copies it from `NIGHTSHIFT_KEY`).

## Getting EOG's test/ folder
```bash
dev/get_test.sh        # pulls their repo, copies test/ (3 files only) into data/test, seeds demo shifts for it
```
Then refresh the dashboard and pick **test** in the Dataset switcher (it is listed first). No backend restart needed.
- If it says `'test' is not in the repo yet`, they haven't published it; run it again later.
- To practice with any existing folder: `dev/get_test.sh history/mock_test_2026-10-10T1530 practice`.
- Check a dataset end to end: `backend/.venv/bin/python dev/rehearse.py test` (needs `pip install httpx`).
