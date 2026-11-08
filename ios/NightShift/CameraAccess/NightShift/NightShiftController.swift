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
  }

  init(api: any NightShiftAPI = Config.makeAPI(), cache: DataCache = DataCache()) {
    self.api = api
    self.cache = cache
    vision = FrameGrabber(api: api)
    uploads = UploadQueue(api: api)
    alerts = cache.load([ShiftAlert].self, from: CacheKey.alerts) ?? []
    facilities = cache.load([FacilityStatus].self, from: CacheKey.facilities) ?? []
    handoff = cache.load(Handoff.self, from: CacheKey.handoff)
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
      await Speaker.shared.announce(text)
    } else {
      await Speaker.shared.speak("This alert has no spoken text.")
    }
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
    guard alerts.contains(where: { $0.facility == id }) || facilities.contains(where: { $0.id == id }) else {
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
      store.current?.flags.first(where: { $0.id == flagID })?.status == .pending
    else { return false }
    store.setStatus(status, for: flagID)
    return true
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
  }

  /// Runs a voice command. Every path shows a line and speaks a short confirmation
  /// or the reason it couldn't complete, so a command never fails silently.
  func handle(_ command: VoiceCommand) async {
    switch command {
    case .next:
      voiceFeedback = ("Next alert", true)
      await speakNextAlert()
    case .status(let name):
      voiceFeedback = ("Status of \(name)", true)
      await speakStatus(of: name)
    case .confirm, .dismiss:
      let status: FlagStatus = command == .confirm ? .confirmed : .dismissed
      guard let flag = store.currentFlag else {
        await reply("No flag waiting", ok: false)
        return
      }
      decide(flag.id, as: status)
      await reply(status == .confirmed ? "Confirmed" : "Dismissed")
    case .note(let text):
      guard isOnShift else {
        await reply("Start a shift first", ok: false)
        return
      }
      store.addNote(text, to: store.currentFlag?.id)
      await reply("Note saved")
    case .flag(let type):
      await flagByVoice(type: type)
    }
  }

  private func flagByVoice(type: String) async {
    guard voice.isListening else {
      await reply("Voice commands are off", ok: false)
      return
    }
    guard isOnShift else {
      await reply("Start a shift first", ok: false)
      return
    }
    guard let facility = currentFacilityID else {
      await reply("Pick a facility first", ok: false)
      return
    }
    let label = type.prefix(1).uppercased() + type.dropFirst()
    // The operator raised it, so it needs no confirm step.
    guard let frame = vision.latestFrame else {
      // No frame: keep the flag anyway, marked as having no photo.
      let flag = store.addFlag(type: type, source: "voice", status: .confirmed, photo: nil, facility: facility)
      store.addNote("no photo", to: flag?.id)
      await reply("\(label) flagged, no photo. Start the camera first", ok: false)
      return
    }
    // Same scaled size as camera evidence; encoded off the main actor.
    let photo = await Task.detached(priority: .userInitiated) { FrameGrabber.scaledJPEG(frame) }.value
    store.addFlag(type: type, source: "voice", status: .confirmed, photo: photo, facility: facility)
    await reply("\(label) flagged")
  }

  /// Shows `text` on the Shift screen and speaks it.
  private func reply(_ text: String, ok: Bool = true) async {
    voiceFeedback = (text, ok)
    await Speaker.shared.speak(text + ".")
  }
}
