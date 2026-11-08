# NightShift iOS app

Hands-free assistant for oil and gas night-shift operators. Ray-Ban Meta Gen 2 glasses stream their camera to this iPhone app; the app speaks alerts through the glasses, takes voice commands from the glasses mic, flags possible leaks/smoke/damage, stores everything offline, and uploads a shift report. Started from Meta's CameraAccess sample (Meta Wearables DAT SDK 1.0.1). Hackathon project (HackUTD, EOG "Beat the Shutdown" + NVIDIA Nemotron track).

## Division of labor (important)
The BACKEND (separate Python server in the repo root) does ALL calculation: detecting failures, countdowns, cost optimization, ranking, writing spoken text (Nemotron agent). The APP only: captures frames, speaks the backend's text, listens for voice commands, stores flags/photos/notes offline, uploads. Never add ranking, sorting, cost, countdown or text-rewriting logic to the app. Show and speak alerts in the exact order the backend returns them, and speak spoken_text exactly as received.

## HARD RULES
- Free Apple account. NEVER add Wi-Fi Info / Hotspot Configuration capabilities or entitlements.
- Camera link uses Bluetooth Classic: keep UISupportedExternalAccessoryProtocols = com.meta.ar.wearable, the external-accessory background mode, and all background modes in Info.plist.
- Do not touch CameraAccess.entitlements, the MWDAT keys (MetaAppID, AppLinkURLScheme, TeamID, ClientToken) or the URL scheme.
- Bundle ID is com.kavin.nightshift (tied to the developer's personal team).
- Backend is reached over https (ngrok), so it needs no ATS exception. Never add NSAllowsArbitraryLoads. The only ATS exception is NSAllowsLocalNetworking, added on request for the Pico buzzer (plain http on the local network); NSLocalNetworkUsageDescription covers glasses Wi-Fi and the Pico.
- No secrets or API keys in any file.
- Build after every change, fix errors, one git commit per task. Do not change dependencies.
- You cannot test on the glasses; give a short hand-test checklist after each task.

## Layout
All NightShift code is in CameraAccess/NightShift/ (Config, Models, NightShiftAPI, NightShiftController, RootTabView, TodoView, MapTabView, AlertsView, SettingsView, FacilityDetailSheet, Theme, FlagRow, AlarmMonitor, AlarmSiren, PicoNudge, VoiceCommand, VoiceCommandListener, FrameGrabber, ShiftStore, UploadQueue, DataCache, NetworkMonitor, MockData/). Speaker.swift does chime + text-to-speech.

## Tabs (RootTabView, via MainAppView)
Four-tab TabView with a custom flat tab bar (2 pt blue underline on the active tab, red unresolved-count badge on Alerts). Red offline banner on every tab when the backend is unreachable (cached data stays). While GET /alarm says alarm true: header lines turn red and a 4 pt red border goes around the whole screen (the alarm overlay window is separate and unchanged). RootTabView owns the CameraViewModel so the glasses stream and vision checks run on any tab.
- To-do (TodoView, home): header (NightShift, glasses dot, shift timer, Start/End/Continue shift, Read aloud = rank 1 spoken_text). One list: Do now (unacknowledged alarm, rank 1 + high facilities, pending flags), Check soon (medium), Routine (other importance > 0), Done (collapsed). Facility rows: I'm here (sets facility tag, marks visited) and Done. Flag rows: Dismiss / Prioritize. End shift opens EndShiftSheet (app-built summary + handover note saved as a shift note "Handover: ...").
- Map (MapTabView): muted dark map, square rank chips with 2 pt status border + level text, dashed route (done part solid), system chips with red problem dot, Updated Xs ago (amber > 30 s), recenter, legend. Wells and pipelines are DEMO layers (not in /map), toggle in Settings > Developer.
- Alerts (AlertsView): Active (backend alarm card + pending flags, Dismiss/Prioritize, What's the issue?) and History (on-phone log: Confirmed, Dismissed, Prioritized, Acknowledged). Call supervisor (tel:, number in Settings).
- Settings (SettingsView): glasses, voice, default map system, backend address + uploads, supervisor phone, Pico address + Test nudge 1/2/3, collapsed Developer (camera preview, I'm at, Check now, Simulate, demo layers, all flags).
- FacilityDetailSheet (To-do and Map): reasons, hours left, tank bar from GET /facility/{id} "Tank level" reading (warning level is a stub: 85% of the limit), Read aloud, I'm here, Done, Open in Apple Maps.
- To-do progress (I'm here/Done) and alert history are local to the phone (DataCache), reset/capped by the app. Prioritize on a phone flag sets Flag.priority (sent in the report); alarm Dismiss/Prioritize use POST /flag/{id}/dismiss|prioritize via /issue.
- Pico (PicoNudge): fire-and-forget GET http://<PICO_IP>/wake?level=N, 1 s timeout, errors ignored. Level 2 when an alarm starts, level 3 with each 15 s repeat of spoken_text.

## Design tokens (Theme.swift, copied from the web dashboard)
Flat dark, 1 pt borders, no shadows/gradients/blur, square corners (radius 0) everywhere. Color = status only; blue is the only accent for tappable things. Always pair color with a text label.
- Background #0E0F11, surface #17191C, raised/selected #22252A, border #32363D, strong border #4D535C; text muted #8B929C, secondary #A9AFB8, body #C8CCD2, primary #ECEEF1.
- Accent #5A9BF0 (pressed #2F6FD6). Green #3FB97F (strong #2C9C67), amber #F2B33D (text #F6C76A), red #E5484D (text #F5A3A5), alarm red #E5484D.
- Badges: 1 pt ring at 40% opacity, 15% tinted fill, lighter text, medium weight. Level badges uppercase (HIGH/MEDIUM/LOW, warning icon on high and medium). Status labels: Normal, Pump wearing out, Possible leak, Pump failure, Tank tripped, wells shut in.
- Type: SF (IBM Plex not bundled) with monospacedDigit for times, readings and costs; titles .title3 semibold (20), body (17), secondary .subheadline (15). Tap targets >= 56 pt, VoiceOver label on every control, haptic on main buttons (FlatButton).
- User-visible name is "NightShift" (CFBundleDisplayName). The Xcode project, target and bundle id keep their CameraAccess names.

## Backend contract
- GET /alerts -> [{id, facility, facility_name, system, type, severity (number), severity_word, hours_to_shutdown, tripped, best_plan, cost, spoken_text}] already in priority order
- GET /facility/{id} -> {id, name, system, status, readings:[{label,value,unit,limit}], alerts, spoken_text}
- GET /handoff -> use only text and spoken_text
- GET /map -> {dataset, as_of, systems:[{id, center [lat,lon], truck_yard [lat,lon], disposal_site {id, lat, lon, pressure_psi}}], facilities:[{rank, id, name, system, lat, lon, importance, level "high"|"medium"|"low"|"none", status, hours_to_shutdown, reasons, spoken_text}]} already ranked (rank 1 = check first); never re-sort. Shown in MapTabView and the To-do list: route (MKPolyline) through facilities with importance > 0 in rank order; importance 0 = small chips off the route. Level always shown as text (HIGH/MEDIUM/LOW/NORMAL). Reloaded every 10 s and after each upload; last good map stays on screen.
- GET /alarm -> {alarm, alarm_id, level, headline, spoken_text, reasons, facility_ids}. Polled every 4 s (AlarmMonitor). A new unacknowledged alarm_id flashes the whole screen red (own window, above sheets), vibrates every 2 s, loops a generated siren (AlarmSiren) on the current output (glasses when connected) with the audio session in .playAndRecord + .duckOthers (so the glasses mic still works), and speaks spoken_text every 15 s, until tapped. The acknowledged alarm_id is saved and never flashes again; alarm false stops it too.
- Alarm voice flow: the alarm turns the listener on for up to 3 minutes. "what's the issue" (also "what is the issue", "what's wrong", "what's going on") stops the siren (flash stays), calls GET /issue -> {facility_id, name, problem, level, spoken_text, flag {id, status, priority, ...} or null, options} and speaks spoken_text as received. Then "dismiss" -> POST /flag/{flag.id}/dismiss ("Dismissed."), "prioritize"/"priority"/"escalate" -> POST /flag/{flag.id}/prioritize ("Marked as priority."); flag null -> "There is nothing to act on." Either decision acknowledges the alarm and reloads /map. On-screen Dismiss/Prioritize buttons do the same; "I saw this" acknowledges without deciding. "Hey Meta" belongs to the glasses' assistant and can't be used; the alarm screen has a Listen button if the mic is off.
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
