# NightShift iOS app

Hands-free assistant for oil and gas night-shift operators. Ray-Ban Meta Gen 2 glasses stream their camera to this iPhone app; the app speaks alerts through the glasses, takes voice commands from the glasses mic, flags possible leaks/smoke/damage, stores everything offline, and uploads a shift report. Started from Meta's CameraAccess sample (Meta Wearables DAT SDK 1.0.1). Hackathon project (HackUTD, EOG "Beat the Shutdown" + NVIDIA Nemotron track).

## Division of labor (important)
The BACKEND (separate Python server in the repo root) does ALL calculation: detecting failures, countdowns, cost optimization, ranking, writing spoken text (Nemotron agent). The APP only: captures frames, speaks the backend's text, listens for voice commands, stores flags/photos/notes offline, uploads. Never add ranking, sorting, cost, countdown or text-rewriting logic to the app. Show and speak alerts in the exact order the backend returns them, and speak spoken_text exactly as received.

## HARD RULES
- Free Apple account. NEVER add Wi-Fi Info / Hotspot Configuration capabilities or entitlements.
- Camera link uses Bluetooth Classic: keep UISupportedExternalAccessoryProtocols = com.meta.ar.wearable, the external-accessory background mode, and all background modes in Info.plist.
- Do not touch CameraAccess.entitlements, the MWDAT keys (MetaAppID, AppLinkURLScheme, TeamID, ClientToken) or the URL scheme.
- Bundle ID is com.kavin.nightshift (tied to the developer's personal team).
- Backend is reached over an https Cloudflare tunnel, so no ATS exceptions. Do not add NSAllowsArbitraryLoads or NSAllowsLocalNetworking.
- No secrets or API keys in any file.
- Build after every change, fix errors, one git commit per task. Do not change dependencies.
- You cannot test on the glasses; give a short hand-test checklist after each task.

## Layout
All NightShift code is in CameraAccess/NightShift/ (Config, Models, NightShiftAPI, NightShiftController, ShiftView, FlagRow, VoiceCommand, VoiceCommandListener, FrameGrabber, ShiftStore, UploadQueue, DataCache, NetworkMonitor, UploadStatusView, MockData/). Speaker.swift does chime + text-to-speech. CameraView.swift has the camera screen, the Test voice button and the clipboard button that opens ShiftView.

## Backend contract
- GET /alerts -> [{id, facility, facility_name, system, type, severity (number), severity_word, hours_to_shutdown, tripped, best_plan, cost, spoken_text}] already in priority order
- GET /facility/{id} -> {id, name, system, status, readings:[{label,value,unit,limit}], alerts, spoken_text}
- GET /handoff -> use only text and spoken_text
- GET /map -> {dataset, as_of, systems:[{id, center [lat,lon], truck_yard [lat,lon], disposal_site {id, lat, lon, pressure_psi}}], facilities:[{rank, id, name, system, lat, lon, importance, level "high"|"medium"|"low"|"none", status, hours_to_shutdown, reasons, spoken_text}]} already ranked (rank 1 = check first); never re-sort. Pin color from level. Reload after each upload. Shown in FacilityMapView: numbered pins + a route line (MKPolyline) through facilities with importance > 0 in rank order; importance 0 = small grey pins. Level also shown as text (Danger, Check soon, Minor, Normal). Reloaded every 10 s and after each upload; last good map stays on screen.
- GET /alarm -> {alarm, alarm_id, level, headline, spoken_text, reasons, facility_ids}. Polled every 4 s (AlarmMonitor). A new unacknowledged alarm_id flashes the whole screen red (own window, above sheets), vibrates every 2 s, loops a generated siren (AlarmSiren) on the current output (glasses when connected) with the audio session in .playback/.duckOthers, and speaks spoken_text every 15 s, until tapped. The acknowledged alarm_id is saved and never flashes again; alarm false stops it too. Voice commands pause during an alarm and resume after.
- POST /vision/check?facility=<id> with raw JPEG (Content-Type image/jpeg) -> {flag, type, confidence, description, available, error}. Skip silently if flag is not true, available is false, or any error/timeout. One request at a time.
- POST /report -> one JSON body {operator, date, started_at, ended_at, flags:[{type "leak"|"smoke"|"damage", facility (id), timestamp (ISO 8601), note, status "confirmed"|"dismissed"|"pending", trigger "camera"|"voice", photo_base64}]}
- Facility ids are strings like S5_FACILITY_C; spoken names look like "S five Facility C".
- Decode tolerantly: ignore unknown fields, optional fields default to nil.
- Backend base URL: the default address is in Config.swift, editable on the Shift screen and saved on the phone; the permanent ngrok address is https://stubble-sensitize-reset.ngrok-free.dev.

## Shifts, flags and test tools
- Shifts start only from the Start Shift button (never on launch or after End Shift). A shift left open by an earlier launch shows Resume / End Shift. Voice commands have their own on/off toggle on the Shift screen; Start Shift turns voice on and End Shift turns it off, but the toggle overrides either.
- Voice flags ("flag leak/smoke/damage") are auto-confirmed (the operator's own call), trigger "voice". Camera flags always start pending, trigger "camera"; nothing confirms or dismisses them automatically.
- Flags are confirmed or dismissed by voice ("confirm"/"dismiss" act on the newest pending flag) or by the on-screen Confirm/Dismiss buttons on each flag row.
- Check now (sends the current frame to /vision/check immediately and shows the raw result) and Simulate camera flag (creates a pending test camera flag) exist for testing. Simulate camera flag is shown only when Config.showTestTools is true; turn it off before a real demo.
- End Shift speaks only an app-built flag summary (confirmed / dismissed / unreviewed counts and up to three notes on confirmed flags), with no handoff text, plans or prices. Start Shift speaks the backend briefing as received.

## Working features (hand-tested on glasses)
Camera stream, chime + spoken alerts through the glasses, voice commands (next, status of <facility>, confirm, dismiss, note <text>, flag leak/smoke/damage), frame grabber every 6 s, flags with photos stored offline, upload queue with retry, Shift screen (Start Shift, Next alert, Refresh, End Shift, Test connection), offline cache of backend data.

## Not done
Gestures (SDK Inputs API is experimental and needs Meta capability approval).
