# NightShift: dashboard + backend setup

Copy `frontend/` and `backend/` into your repo (replace the frontend files create-next-app made).

## Backend
```bash
cd backend
pip install -r requirements.txt
python seed.py                                   # fake flags for tonight + past nights
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```
Check http://localhost:8000/docs to try every endpoint.
Test photos: put them in `backend/photos/` named f_001.jpg ... f_006.jpg, h_001.jpg ... h_006.jpg.

## Frontend
```bash
cd frontend
npm install
npm run dev
```
Open http://localhost:3000. If the backend is off, it shows the fake JSON and says "Demo data".
If the backend runs on another laptop, create `frontend/.env.local`:
```
NEXT_PUBLIC_API_URL=http://<that-laptop-ip>:8000
```

## Demo trick: make a flag pop in live
With the dashboard open, run:
```bash
curl -X POST localhost:8000/flags -H "Content-Type: application/json" \
  -d '{"type":"leak","location":"Pump 04","photo_url":"/photos/f_005.jpg"}'
```
It shows up within 2 seconds with the amber flash.

## For the iPhone app / detection code
- Create a flag: `POST /flags` with `{type, location, photo_url, note?}`
- Operator says confirm/dismiss: `POST /flag/{id}/confirm` or `/dismiss`
- Voice note: `POST /flag/{id}/note` with `{note}`
- Save photos into `backend/photos/` and pass `/photos/<name>.jpg` as photo_url
