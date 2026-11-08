# NightShift iOS app

Hands-free assistant for oil and gas night-shift operators. Ray-Ban Meta Gen 2 glasses stream their camera to this iPhone app; the app speaks alerts through the glasses, takes voice commands from the glasses mic, flags possible leaks/smoke/damage, stores everything offline, and uploads a shift report. Started from Meta's CameraAccess sample (Meta Wearables DAT SDK 1.0.1). Hackathon project (HackUTD, EOG "Beat the Shutdown" + NVIDIA Nemotron track).

## Division of labor (important)
The BACKEND (separate Python server in the repo root) does ALL calculation: detecting failures, countdowns, cost optimization, ranking, writing spoken text (Nemotron agent). The APP only: captures frames, speaks the backend's text, listens for voice commands, stores flags/photos/notes offline, uploads. Never add ranking, sorting, cost, countdown or text-rewriting logic to the app. Show and speak alerts in the exact order the backend returns them, and speak spoken_text exactly as received.

## HARD RULES
- Free Apple account. NEVER add Wi-Fi Info / Hotspot Configuration capabilities or entitlements.
- Camera link uses Bluetooth Classic: keep UISupportedExternalAccessoryProtocols = com.meta.ar.wearable and the background modes bluetooth-central, bluetooth-peripheral, audio and external-accessory, plus NSBonjourServices. ("processing" and the photo-library permission were removed in hardening item 10 as unused.)
- Do not touch CameraAccess.entitlements, the MWDAT keys (MetaAppID, AppLinkURLScheme, TeamID, ClientToken) or the URL scheme.
- Bundle ID is com.kavin.nightshift (tied to the developer's personal team).
- Backend is reached over https (ngrok), so it needs no ATS exception. Never add NSAllowsArbitraryLoads. The only ATS exception is NSAllowsLocalNetworking, added on request for the Pico buzzer (plain http on the local network); NSLocalNetworkUsageDescription covers glasses Wi-Fi and the Pico.
- No secrets or API keys in any file.
- Build after every change, fix errors, one git commit per task. Do not change dependencies.
- You cannot test on the glasses; give a short hand-test checklist after each task.

## Layout
All NightShift code is in CameraAccess/NightShift/ (Config, Models, NightShiftAPI, NightShiftController, RootTabView, LiveView, ShiftTabView, MapTabView, CityMap, CityMapView, AlertsView, SettingsView, FacilityDetailSheet, FlagCardView, DangerBanner, Theme, FlagRow, AlarmMonitor, AlarmSiren, PicoNudge, VoiceCommand, VoiceCommandListener, FrameGrabber, ShiftStore, ShiftRecord, UploadQueue, DataCache, NetworkMonitor, Keychain, MockData/). Speaker.swift does chime + text-to-speech.

## Tabs (RootTabView, via MainAppView)
Three tabs: LIVE, SHIFT, SETTINGS, under one AppHeader ("Night" periwinkle + "Shift" salmon in Big Shoulders Stencil, "AVON NEVER SLEEPS", link chip OPTICS ONLINE / CONNECTING... / OPTICS OFFLINE -> ConnectionSheet). Under the header: DangerBanner (filled red while /alarm is on; plan + cost from /alerts best_plan/cost; ACKNOWLEDGE collapses it to a strip), the LIVE/REPLAY/OFFLINE pill, and monitoring-lost / offline banners. 4 pt red screen border while /alarm is on. RootTabView owns the CameraViewModel so the stream and vision checks run on any tab. The full-screen alarm overlay (AlarmMonitor) is separate.
- LIVE (LiveView): framed glasses preview with corner brackets, "CAM · AUDIO · <facility>", SCAN dot per vision check (VISION OFFLINE when the backend is down), I'm at facility card, voice status bar. FlagCardView slides up for each new pending flag (CONFIRM / DISMISS, "SAVED · ..." toast).
- SHIFT (ShiftTabView): status (START / CONTINUE / END SHIFT, operator name, timer), briefing (PLAY AGAIN), priorities (backend rank order, link to MapTabView), alerts (link to AlertsView: Active + History), flags (summary + list -> flag card), upload status (RETRY NOW). EndShiftSheet shows the handover summary + note, then uploads.
- SETTINGS (SettingsView): HUD cards: console URL (read-only), mock mode, version, operator name, glasses, voice (whitelist + transcript), voice speed + Test voice, map default, backend address + API key + uploads, supervisor, Pico, collapsed Developer (camera controls, I'm at, Check now, Simulate, all flags).
- Map (MapTabView -> CityMapView): the dashboard's neon city map (frontend SiteMap.tsx + lib/city.ts). CityMap.swift is a line-by-line port of city.ts (same seeded generator, so each system's city matches the dashboard exactly; CityMapTests pin it). One system at a time (chips; none saved = system of the top-ranked facility). Facility layout input is sorted by id so it never moves when ranks change; cards show the server's severity/status/hours, compact chips when zoomed out. Drawn from GET /map only (no tank level, wells or pump state). The map's glow, vignette and neon colors are the one exception to the no-shadow/no-gradient rule, to match the dashboard.
- Voice whitelist: what's the issue, confirm (camera flags), dismiss, prioritize, acknowledge, stop, repeat, status, next alert.

## Design tokens (Theme.swift)
Deep-wine dark, forced dark mode. Solid cards with 1 pt border and a chamfered top-right corner (ChamferedRect, 10 pt; 4 pt radius elsewhere). No shadows, gradients or blur. HUD label above each card (SysCard / HudLabel: SF Mono 12, 0.08em tracking).
- Background #1A0710, card #342B30, raised #3F3238, border #5A3A42, key border #A83C47. Text cream #F8EED7, muted #C9B8B0, secondary #C59FB0.
- Primary buttons + "Shift": salmon #BC7579 with #1A0710 text. Links / selected tab / "Night": periwinkle #8E95B5. HUD decoration #AD6564 (label text #B56B6A for AA). Tiny highlights #F3F654.
- Status, always with text: danger #FF2D2D as a FILLED badge (dark text); red text on cards uses #FF7A7A. Check soon #FF9F1C. Normal #5DD39E. Severity labels HIGH/MEDIUM/LOW/NORMAL from the server's severity (else level).
- Fonts (bundled, OFL licenses in NightShift/Fonts, UIAppFonts): Rajdhani Medium/SemiBold/Bold (Font.ns), Big Shoulders Stencil Display Bold (Font.nsDisplay), SF Mono via the system monospaced font (Font.nsMono) for every number. All scale with Dynamic Type.
- Buttons (FlatButton): full width, 56 pt, chamfered, Rajdhani Bold uppercase; secondary outlined. Reduce Motion: no slides, pulses or blinking (alarm overlay goes steady red).

## Working features (hand-tested on glasses)
Camera stream, chime + spoken alerts through the glasses, voice commands (next, status of <facility>, confirm, dismiss, note <text>, flag leak/smoke/damage), frame grabber every 6 s, flags with photos stored offline, upload queue with retry, Shift screen (Start Shift, Next alert, Refresh, End Shift, Test connection), offline cache of backend data.

## Not done
Gestures (SDK Inputs API is experimental and needs Meta capability approval).
