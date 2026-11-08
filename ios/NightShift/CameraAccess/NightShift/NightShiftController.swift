//
// NightShiftController.swift
//
// The phone side of NightShift: fetch and cache backend data, speak it as received,
// listen for commands, capture flags, store them, and upload the shift report. All
// ranking, analysis and spoken wording come from the backend.
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class NightShiftController {
  static let shared = NightShiftController()

  // MARK: - Backend data (loaded from cache first, in backend order)

  private(set) var alerts: [ShiftAlert] = []
  private(set) var facilities: [FacilityStatus] = []
  private(set) var handoff: Handoff?
  private(set) var isRefreshing = false

  /// GET /map: facilities ranked by importance, in backend order (loaded from cache first).
  private(set) var map: FacilityMap?
  private(set) var isLoadingMap = false
  /// System shown on the map (nil = all). Starts at the Settings default.
  var mapSystemFilter: String? = Config.defaultSystem
  /// When /map last loaded successfully (for "Updated Xs ago").
  private(set) var mapUpdatedAt: Date?
  /// Error text of the last failed map load; nil after a success.
  private(set) var mapError: String?

  /// Result of the last "Test connection": `ok` is true when GET /alerts succeeded.
  private(set) var connectionTestResult: (text: String, ok: Bool)?
  private(set) var isTestingConnection = false

  /// Backend address in use (Config.baseURL), kept here so the Shift screen updates on change.
  private(set) var backendURL: URL = Config.baseURL
  private(set) var isUsingDefaultBackend = Config.savedBaseURL == nil

  /// Facility id the operator is at (e.g. "S5_FACILITY_C"): from the last alert or
  /// status spoken, the "I'm at" picker, or the top alert at Start Shift. Sent with
  /// vision checks and saved on flags; while nil, camera and voice flags are blocked.
  private(set) var currentFacilityID: String?

  /// Facilities the "I'm at" picker offers: unique ids from the cached alerts, in
  /// backend order, with the best name available.
  var facilityChoices: [(id: String, name: String)] {
    var seen = Set<String>()
    return alerts.compactMap { alert in
      guard let id = alert.facility, seen.insert(id).inserted else { return nil }
      let name = alert.facilityName ?? facilities.first { $0.id == id }?.name ?? id
      return (id, name)
    }
  }

  // MARK: - Components

  let voice = VoiceCommandListener()
  /// Red full-screen alarm from GET /alarm.
  @ObservationIgnored let alarm: AlarmMonitor
  let store = ShiftStore()
  let uploads: UploadQueue
  @ObservationIgnored let vision: FrameGrabber
  @ObservationIgnored let api: any NightShiftAPI
  @ObservationIgnored private let cache: DataCache
  @ObservationIgnored private var nextAlertIndex = 0
  @ObservationIgnored private var connectionTestID = 0

  private enum CacheKey {
    static let alerts = "alerts"
    static let facilities = "facilities"
    static let handoff = "handoff"
    static let map = "map"
    static let history = "alert_history"
    static let todo = "todo_progress"
  }

  init(api: any NightShiftAPI = Config.makeAPI(), cache: DataCache = DataCache()) {
    self.api = api
    self.cache = cache
    vision = FrameGrabber(api: api)
    uploads = UploadQueue(api: api)
    alarm = AlarmMonitor(api: api, voice: voice)
    alarm.onDecided = { [weak self] in
      // A prioritized facility moves to stop 1.
      await self?.refreshMap()
    }
    alarm.onFlagDecision = { [weak self] action, flag, issue in
      // The decision acknowledges a flashing alarm right after this; don't log it twice.
      self?.suppressNextAcknowledgedEntry = self?.alarm.active != nil
      self?.recordHistory(
        kind: .alarm,
        title: issue.name ?? flag.equipmentId ?? "Alarm",
        facilityID: issue.facilityId ?? flag.equipmentId,
        outcome: action == .dismiss ? .dismissed : .prioritized
      )
    }
    alarm.onAcknowledged = { [weak self] status in
      guard let self else { return }
      // A dismiss/prioritize already logged this alarm.
      if self.suppressNextAcknowledgedEntry {
        self.suppressNextAcknowledgedEntry = false
        return
      }
      self.recordHistory(kind: .alarm, title: status.headline ?? "Alarm", facilityID: status.facilityIds.first, outcome: .acknowledged)
    }
    uploads.onUploaded = { [weak self] in
      // The ranking uses the latest uploaded shift, so reload it.
      await self?.refreshMap()
    }
    alerts = cache.load([ShiftAlert].self, from: CacheKey.alerts) ?? []
    facilities = cache.load([FacilityStatus].self, from: CacheKey.facilities) ?? []
    handoff = cache.load(Handoff.self, from: CacheKey.handoff)
    map = cache.load(FacilityMap.self, from: CacheKey.map)
    history = cache.load([AlertHistoryEntry].self, from: CacheKey.history) ?? []
    todo = cache.load(TodoProgress.self, from: CacheKey.todo) ?? TodoProgress()
    // A shift saved by an earlier launch is not continued automatically.
    isAwaitingResume = store.current != nil

    voice.onCommand = { [weak self] command in
      await self?.handle(command)
    }
    voice.onUnrecognized = { [weak self] transcript in
      self?.handleUnrecognized(transcript)
    }
    vision.facility = { [weak self] in self?.currentFacilityID }
    vision.isEnabled = { [weak self] in self?.isOnShift ?? false }
    vision.onFlag = { [weak self] type, description, facility, photo in
      await self?.handleCameraFlag(type: type, description: description, facility: facility, photo: photo)
    }
  }

  // MARK: - Camera

  /// Called by the camera screen. Frames are read from its decoded preview.
  func attachCamera(frame: @escaping @MainActor () -> UIImage?, isStreaming: @escaping @MainActor () -> Bool) {
    vision.start(frame: frame, isStreaming: isStreaming)
  }

  func detachCamera() {
    vision.stop()
  }

  // MARK: - Shift

  /// True when the saved shift was left open by an earlier launch and the operator
  /// hasn't chosen Resume or End Shift yet. Flags are blocked meanwhile.
  private(set) var isAwaitingResume = false

  /// A shift is open and active. Only Start Shift (or Resume) makes this true.
  var isOnShift: Bool { store.current != nil && !isAwaitingResume }

  /// Start time of a shift left open by an earlier launch, while awaiting Resume.
  var unfinishedShiftStart: Date? { isAwaitingResume ? store.current?.startedAt : nil }

  /// Opens the shift record, turns on voice commands, refreshes, then speaks the
  /// handoff and the first alert.
  func startShift() async {
    // A new shift starts with an empty to-do progress.
    if store.current == nil {
      todo = TodoProgress()
      cache.save(todo, as: CacheKey.todo)
    }
    isAwaitingResume = false
    store.startShift()
    await voice.start()
    await refresh()
    // Default to the top alert's facility so flags can be raised right away.
    if let topFacility = alerts.first?.facility {
      setCurrentFacility(topFacility)
    }
    if let briefing = handoff?.spokenText {
      await Speaker.shared.speak(briefing)
    }
    nextAlertIndex = 0
    await speakNextAlert()
  }

  /// Continues a shift left open by an earlier launch and turns voice on.
  func resumeShift() async {
    guard isAwaitingResume else { return }
    isAwaitingResume = false
    await voice.start()
  }

  /// Turns voice commands on or off, independent of the shift.
  func setVoiceEnabled(_ enabled: Bool) async {
    if enabled {
      await voice.start()
    } else {
      voice.stop()
    }
  }

  /// Archives the shift, queues its report for upload, turns voice off, and speaks a
  /// short summary built from this shift's flags only (no handoff text, plans or costs).
  func endShift() async {
    isAwaitingResume = false
    guard let ended = store.endShift() else { return }
    uploads.enqueue(store.makeReport(for: ended))
    voice.stop()
    await Speaker.shared.speak(Self.endOfShiftSummary(for: ended.flags))
  }

  /// Notes the app adds itself; not read out in the summary.
  private static let markerNotes: Set<String> = ["no photo", "(test)"]

  /// "Shift ended. 2 confirmed, 1 dismissed, 0 unreviewed." plus up to three operator
  /// notes from confirmed flags, or "No flags this shift."
  static func endOfShiftSummary(for flags: [Flag]) -> String {
    guard !flags.isEmpty else { return "No flags this shift." }
    let confirmed = flags.filter { $0.status == .confirmed }
    let dismissed = flags.count(where: { $0.status == .dismissed })
    let unreviewed = flags.count(where: { $0.status == .pending })
    var summary = "Shift ended. \(confirmed.count) confirmed, \(dismissed) dismissed, \(unreviewed) unreviewed."
    let notes = confirmed
      .flatMap { flag in flag.notes.map { (type: flag.type, text: $0.text) } }
      .filter { !markerNotes.contains($0.text) }
      .prefix(3)
    for note in notes {
      summary += " \(note.type.prefix(1).uppercased() + note.type.dropFirst()) note: \(note.text)."
    }
    return summary
  }

  // MARK: - Refresh

  /// Refetches alerts, handoff, and the facilities the alerts mention, and caches them.
  /// On failure the cached copy stays in use.
  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    // Independent of alerts: a map failure doesn't block the rest.
    async let mapDone: Void = refreshMap()

    do {
      async let fetchedAlerts = api.fetchAlerts()
      async let fetchedHandoff = api.fetchHandoff()
      let newAlerts = try await fetchedAlerts
      let newHandoff = try await fetchedHandoff

      var newFacilities: [FacilityStatus] = []
      for id in newAlerts.compactMap(\.facility) where !newFacilities.contains(where: { $0.id == id }) {
        // One facility failing keeps its cached entry.
        if let facility = (try? await api.fetchFacility(id: id)) ?? facilities.first(where: { $0.id == id }) {
          newFacilities.append(facility)
        }
      }

      alerts = newAlerts
      handoff = newHandoff
      facilities = newFacilities
      cache.save(newAlerts, as: CacheKey.alerts)
      cache.save(newHandoff, as: CacheKey.handoff)
      cache.save(newFacilities, as: CacheKey.facilities)
    } catch {
      NSLog("[NightShift] Refresh failed, using cached data: \(error)")
    }
    await mapDone
  }

  @ObservationIgnored private var mapPollTask: Task<Void, Never>?
  @ObservationIgnored private var clockPollTask: Task<Void, Never>?

  // MARK: - Server clock (LIVE / REPLAY / OFFLINE)

  /// What the server says "now" is, and whether it's live or replay.
  private(set) var serverClock: ServerClock?
  /// nil until the first check; then whether the backend answered.
  private(set) var isBackendReachable: Bool?
  private(set) var clockCheckedAt: Date?

  /// GET /clock; servers without GET /clock (404/405) fall back to GET /alarm's
  /// live, as_of and dataset.
  func refreshClock() async {
    do {
      serverClock = try await api.fetchClock()
      isBackendReachable = true
    } catch NightShiftAPIError.badStatus(let code, _) where code == 404 || code == 405 {
      if let status = try? await api.fetchAlarm() {
        let mode = status.mode ?? (status.live == false ? "replay" : "live")
        serverClock = ServerClock(dataset: status.dataset, now: status.asOf, nowTs: nil, mode: mode)
        isBackendReachable = true
      } else {
        isBackendReachable = false
      }
    } catch {
      isBackendReachable = false
    }
    clockCheckedAt = Date()
    // The backend answered: send anything waiting in the outbox.
    if isBackendReachable == true, uploads.pendingCount > 0 {
      await uploads.drain()
    }
  }

  /// Starts the app-wide polls: GET /alarm every 4 s and GET /map every 10 s. Called
  /// once from the app root; safe to call again.
  func startPolling() {
    alarm.startPolling()
    if clockPollTask == nil {
      clockPollTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          await self?.refreshClock()
          try? await Task.sleep(for: Config.clockRefreshInterval)
        }
      }
    }
    guard mapPollTask == nil else { return }
    mapPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.refreshMap()
        try? await Task.sleep(for: Config.mapRefreshInterval)
      }
    }
  }

  /// Reloads GET /map and caches it. On failure the cached map stays in use.
  func refreshMap() async {
    guard !isLoadingMap else { return }
    isLoadingMap = true
    defer { isLoadingMap = false }
    do {
      let newMap = try await api.fetchMap()
      map = newMap
      mapError = nil
      mapUpdatedAt = Date()
      cache.save(newMap, as: CacheKey.map)
    } catch {
      mapError = NightShiftAPIError.describe(error)
      NSLog("[NightShift] Map load failed, using cached map: \(error)")
    }
  }

  /// GET /alerts once on the current address and reports success or the error text.
  func testConnection() async {
    // A newer test (e.g. after the address changed) supersedes this one's result.
    connectionTestID += 1
    let testID = connectionTestID
    isTestingConnection = true
    let result: (text: String, ok: Bool)
    do {
      let alerts = try await api.fetchAlerts()
      result = ("Connected, \(alerts.count) alerts", true)
    } catch {
      result = (NightShiftAPIError.describe(error), false)
    }
    guard testID == connectionTestID else { return }
    isTestingConnection = false
    connectionTestResult = result
    if result.ok {
      // The address works: send any reports queued while it didn't.
      await uploads.drain()
    }
  }

  // MARK: - Backend address

  /// Normalizes and saves a new backend address, then tests it.
  /// Returns false (nothing saved) if the address is invalid.
  func saveBackendAddress(_ input: String) async -> Bool {
    guard Config.saveBaseURL(input) != nil else { return false }
    await backendAddressChanged()
    return true
  }

  /// Goes back to the built-in address, then tests it.
  func resetBackendAddress() async {
    Config.resetBaseURL()
    await backendAddressChanged()
  }

  private func backendAddressChanged() async {
    backendURL = Config.baseURL
    Task { await refreshClock() }
    isUsingDefaultBackend = Config.savedBaseURL == nil
    connectionTestResult = nil
    BackendStatus.shared.reset()
    await testConnection()
  }

  // MARK: - Spoken output

  /// Speaks the next alert's spoken_text, in the order the backend returned them.
  func speakNextAlert() async {
    guard !alerts.isEmpty else {
      await Speaker.shared.speak("No alerts.")
      return
    }
    guard nextAlertIndex < alerts.count else {
      nextAlertIndex = 0
      await Speaker.shared.speak("No more alerts.")
      return
    }
    let alert = alerts[nextAlertIndex]
    nextAlertIndex += 1
    if let facility = alert.facility {
      setCurrentFacility(facility)
    }
    if let text = alert.spokenText {
      lastSpokenContent = text
      await Speaker.shared.announce(text)
    } else {
      await Speaker.shared.speak("This alert has no spoken text.")
    }
  }

  /// "status" alone: everything in progress at the server's current time (live, or the
  /// moment the dashboard slider set with POST /clock). Fetches fresh /clock, /alerts and
  /// /map first, then speaks the time (in replay), every alert's spoken_text in the
  /// backend's order, and this shift's flag counts. Falls back to the saved data, and
  /// says so, when the console can't be reached.
  func speakStatusAtServerTime() async {
    await refreshClock()
    var reachedConsole = isBackendReachable == true
    if let fresh = try? await api.fetchAlerts() {
      alerts = fresh
      cache.save(fresh, as: CacheKey.alerts)
    } else {
      reachedConsole = false
    }
    await refreshMap()
    if mapError != nil { reachedConsole = false }

    var parts: [String] = []
    if !reachedConsole {
      parts.append("Can't reach the console. This is the last saved status.")
    }
    if let clock = serverClock, clock.isReplay, let date = clock.nowDate {
      parts.append("Replay, \(date.formatted(.dateTime.weekday(.wide).hour().minute())).")
    }
    // Alerts as the server wrote them, in its order; /map's when /alerts is empty.
    let alertTexts = alerts.compactMap(\.spokenText)
    let mapTexts = (map?.facilities ?? []).filter(\.needsCheck).compactMap(\.spokenText)
    let items = alertTexts.isEmpty ? mapTexts : alertTexts
    if items.isEmpty {
      parts.append("No problems in progress.")
    } else {
      parts.append("\(items.count) alert\(items.count == 1 ? "" : "s").")
      parts.append(contentsOf: items)
    }
    let flags = store.current?.flags ?? []
    if !flags.isEmpty {
      let waiting = flags.count(where: { $0.status == .pending })
      let confirmed = flags.count(where: { $0.status == .confirmed })
      parts.append("Flags this shift: \(waiting) waiting, \(confirmed) confirmed.")
    }
    let text = parts.joined(separator: " ")
    lastSpokenContent = text
    await Speaker.shared.speak(text)
  }

  /// Answers "status of <name>" from cached facility data.
  func speakStatus(of spokenName: String) async {
    guard !spokenName.trimmingCharacters(in: .whitespaces).isEmpty else {
      await Speaker.shared.speak("Say status of, then a facility name.")
      return
    }
    guard let facility = facility(matching: spokenName) else {
      await Speaker.shared.speak("No status for \(spokenName).")
      return
    }
    setCurrentFacility(facility.id)
    if let text = facility.spokenText {
      lastSpokenContent = text
      await Speaker.shared.speak(text)
    } else {
      await Speaker.shared.speak("No status for \(spokenName).")
    }
  }

  /// Case-insensitive containment either way between what was said and a cached name.
  func facility(matching spokenName: String) -> FacilityStatus? {
    let query = spokenName.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    guard !query.isEmpty else { return nil }
    return facilities.first { facility in
      let name = facility.displayName.lowercased()
      return name.contains(query) || query.contains(name)
    }
  }

  // MARK: - Facility

  /// Sets the current facility, accepting only a non-empty id known from /alerts (or
  /// the facility statuses fetched for them), never a spoken name.
  func setCurrentFacility(_ id: String?) {
    guard let id, !id.isEmpty else { return }
    guard alerts.contains(where: { $0.facility == id })
      || facilities.contains(where: { $0.id == id })
      || map?.facilities.contains(where: { $0.id == id }) == true
    else {
      NSLog("[NightShift] Ignoring unknown facility id \(id)")
      return
    }
    currentFacilityID = id
  }

  // MARK: - Flags

  /// Backend flagged a frame: save it with the facility the check was sent for, chime,
  /// and ask for a decision.
  @discardableResult
  private func handleCameraFlag(type: String, description: String?, facility: String, photo: Data?, note: String? = nil) async -> Bool {
    // The shift may have ended while the check was in flight.
    guard let flag = store.addFlag(type: type, source: "camera", status: .pending, photo: photo, facility: facility, description: description) else { return false }
    if let note {
      store.addNote(note, to: flag.id)
    }
    await Speaker.shared.announce("possible \(type), confirm or dismiss")
    return true
  }

  /// Result line of the last "Simulate camera flag".
  private(set) var simulateResult: (text: String, ok: Bool)?

  /// Test tool (Config.showTestTools): creates a pending camera leak flag with the
  /// current frame, exactly as a real vision flag would, marked "(test)".
  func simulateCameraFlag() async {
    guard isOnShift else {
      simulateResult = ("Start a shift first", false)
      return
    }
    guard let facility = currentFacilityID else {
      simulateResult = ("Pick a facility first", false)
      return
    }
    var photo: Data?
    if let frame = vision.latestFrame {
      photo = await Task.detached(priority: .userInitiated) { FrameGrabber.scaledJPEG(frame) }.value
    }
    simulateResult = ("Simulated leak flag created\(photo == nil ? " (no camera frame)" : "")", true)
    await handleCameraFlag(type: "leak", description: "Simulated flag for testing", facility: facility, photo: photo, note: "(test)")
  }

  /// Confirms or dismisses a pending flag (on-screen buttons and voice). Flags that
  /// are already decided are left alone.
  @discardableResult
  func decide(_ flagID: Flag.ID, as status: FlagStatus) -> Bool {
    guard status != .pending,
      let flag = store.current?.flags.first(where: { $0.id == flagID }),
      flag.status == .pending
    else { return false }
    store.setStatus(status, for: flagID)
    recordHistory(kind: .flag, title: flagTitle(flag), facilityID: flag.facility, outcome: status == .confirmed ? .confirmed : .dismissed)
    return true
  }

  /// On-screen Prioritize for a phone flag: confirms it and marks it a priority. There
  /// is no backend endpoint for phone flags, so the priority travels in the report.
  @discardableResult
  func prioritize(_ flagID: Flag.ID) -> Bool {
    guard let flag = store.current?.flags.first(where: { $0.id == flagID }), flag.status == .pending else { return false }
    store.setPriority(for: flagID)
    recordHistory(kind: .flag, title: flagTitle(flag), facilityID: flag.facility, outcome: .prioritized)
    return true
  }

  private func flagTitle(_ flag: Flag) -> String {
    let name = flag.facility.flatMap { id in map?.facilities.first { $0.id == id }?.displayName } ?? flag.facility
    return "Possible \(flag.type)" + (name.map { " at \($0)" } ?? "")
  }

  // MARK: - Alarm decisions from the screen

  /// Dismiss or Prioritize on the alarm card (Alerts / To-do): asks /issue for the
  /// alarm's flag (quietly), POSTs the decision, acknowledges the alarm and reloads
  /// /map. Returns an error line, or nil on success.
  func decideCurrentAlarm(_ action: FlagAction) async -> String? {
    do {
      let issue = try await api.fetchIssue(facility: alarm.backendStatus?.facilityIds.first)
      guard let flag = issue.flag else { return "There is nothing to act on." }
      _ = try await api.decideFlag(id: flag.id, action: action)
      suppressNextAcknowledgedEntry = alarm.active != nil
      recordHistory(
        kind: .alarm,
        title: issue.name ?? alarm.backendStatus?.headline ?? "Alarm",
        facilityID: issue.facilityId,
        outcome: action == .dismiss ? .dismissed : .prioritized
      )
      alarm.acknowledgeBackendAlarm()
      suppressNextAcknowledgedEntry = false
      await refreshMap()
      return nil
    } catch {
      return NightShiftAPIError.describe(error)
    }
  }

  // MARK: - To-do progress (this shift, on this phone only)

  /// "I'm here" and "Done" per facility id. Local only; reset at Start Shift.
  struct TodoProgress: Codable, Sendable {
    var here: [String: Date] = [:]
    var done: [String: Date] = [:]
  }

  private(set) var todo = TodoProgress()

  /// "I'm here": tag new flags with this facility and mark it visited.
  func markHere(_ facilityID: String) {
    setCurrentFacility(facilityID)
    todo.here[facilityID] = Date()
    cache.save(todo, as: CacheKey.todo)
  }

  /// "Done": moves the facility to the Done section for this shift.
  func markDone(_ facilityID: String) {
    todo.done[facilityID] = Date()
    cache.save(todo, as: CacheKey.todo)
  }

  func undoDone(_ facilityID: String) {
    todo.done[facilityID] = nil
    cache.save(todo, as: CacheKey.todo)
  }

  // MARK: - Alert history (on this phone only)

  struct AlertHistoryEntry: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case alarm, flag }
    enum Outcome: String, Codable, Sendable {
      case confirmed = "Confirmed"
      case dismissed = "Dismissed"
      case prioritized = "Prioritized"
      case acknowledged = "Acknowledged"
    }
    var id = UUID()
    let kind: Kind
    let title: String
    let facilityID: String?
    let outcome: Outcome
    let at: Date
  }

  /// Newest first.
  private(set) var history: [AlertHistoryEntry] = []
  @ObservationIgnored private var suppressNextAcknowledgedEntry = false

  private func recordHistory(kind: AlertHistoryEntry.Kind, title: String, facilityID: String?, outcome: AlertHistoryEntry.Outcome) {
    history.insert(AlertHistoryEntry(kind: kind, title: title, facilityID: facilityID, outcome: outcome, at: Date()), at: 0)
    history = Array(history.prefix(200))
    cache.save(history, as: CacheKey.history)
  }

  /// Unresolved items for the Alerts tab badge: pending flags plus an unacknowledged alarm.
  var unresolvedCount: Int {
    let pending = store.current?.flags.count(where: { $0.status == .pending }) ?? 0
    let alarmOpen = alarm.backendStatus?.alarm == true && !alarm.isBackendAlarmAcknowledged
    return pending + (alarmOpen ? 1 : 0)
  }

  /// Adds an on-screen note to a flag. Returns false if empty or no shift is active.
  @discardableResult
  func addNote(_ text: String, to flagID: Flag.ID) -> Bool {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isOnShift, !text.isEmpty else { return false }
    return store.addNote(text, to: flagID)
  }

  // MARK: - Voice commands

  /// Visible result of the last voice command or unrecognized phrase. `ok` is false
  /// when the command could not complete or wasn't understood.
  private(set) var voiceFeedback: (text: String, ok: Bool)?

  /// Shows a phrase that matched no command (not spoken).
  func handleUnrecognized(_ transcript: String) {
    voiceFeedback = ("Not understood: \(transcript)", false)
    // Spoken at most every few seconds, so background noise (or the siren) can't
    // make the app talk over itself. No network side effects.
    let now = Date()
    guard now.timeIntervalSince(lastNotUnderstoodAt) > 8 else { return }
    lastNotUnderstoodAt = now
    Task { await Speaker.shared.speak("I didn't catch that.") }
  }

  @ObservationIgnored private var lastNotUnderstoodAt = Date.distantPast
  /// The last backend message spoken (alert or status), for "repeat".
  @ObservationIgnored private var lastSpokenContent: String?

  /// Runs a whitelisted voice command. Every path shows a line and speaks a short
  /// confirmation or the reason it couldn't complete, so a command never fails silently.
  func handle(_ command: VoiceCommand) async {
    switch command {
    case .issue:
      voiceFeedback = ("What's the issue", true)
      await alarm.askIssue()
    case .prioritize:
      voiceFeedback = ("Prioritize", true)
      if !(await alarm.decide(.prioritize)) {
        await reply("Say what's the issue first", ok: false)
      }
    case .confirm:
      voiceFeedback = ("Confirm", true)
      if let flag = store.currentFlag {
        decide(flag.id, as: .confirmed)
        await reply("Confirmed")
      } else {
        await reply("No flag waiting", ok: false)
      }
    case .dismiss:
      voiceFeedback = ("Dismiss", true)
      // After "what's the issue" (or during an alarm), dismiss acts on that issue;
      // otherwise on the newest pending camera flag.
      if alarm.isAwaitingDecision || alarm.active != nil {
        if !(await alarm.decide(.dismiss)) {
          await reply("Say what's the issue first", ok: false)
        }
      } else if let flag = store.currentFlag {
        decide(flag.id, as: .dismissed)
        await reply("Dismissed")
      } else {
        await reply("No flag waiting", ok: false)
      }
    case .acknowledge, .stop:
      if alarm.active != nil {
        alarm.acknowledge()
        await reply("Acknowledged")
      } else if command == .stop {
        Speaker.shared.stopAll()
        voiceFeedback = ("Stopped", true)
      } else {
        await reply("No alarm to acknowledge", ok: false)
      }
    case .repeatLast:
      voiceFeedback = ("Repeat", true)
      if let text = alarm.issue?.spokenText ?? alarm.active?.spokenText ?? lastSpokenContent {
        await Speaker.shared.speak(text)
      } else {
        await reply("Nothing to repeat", ok: false)
      }
    case .status(let name):
      if name.isEmpty {
        voiceFeedback = ("Status", true)
        await speakStatusAtServerTime()
      } else {
        voiceFeedback = ("Status of \(name)", true)
        await speakStatus(of: name)
      }
    case .next:
      voiceFeedback = ("Next alert", true)
      await speakNextAlert()
    }
  }

  /// Shows `text` on the Shift screen and speaks it.
  private func reply(_ text: String, ok: Bool = true) async {
    voiceFeedback = (text, ok)
    await Speaker.shared.speak(text + ".")
  }
}
