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

  /// Facility the operator is at: the one from the last alert or status spoken.
  /// Sent with vision checks and saved on flags.
  private(set) var currentFacilityID: String?

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

    voice.onCommand = { [weak self] command in
      await self?.handle(command)
    }
    vision.facility = { [weak self] in self?.currentFacilityID }
    vision.onFlag = { [weak self] type, frame in
      await self?.handleCameraFlag(type: type, frame: frame)
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

  var isOnShift: Bool { store.current != nil }

  /// Opens the shift record, turns on voice commands, refreshes, then speaks the
  /// handoff and the first alert.
  func startShift() async {
    store.startShift()
    await voice.start()
    await refresh()
    if let briefing = handoff?.spokenText {
      await Speaker.shared.speak(briefing)
    }
    nextAlertIndex = 0
    await speakNextAlert()
  }

  /// Speaks the flag counts, archives the shift, and queues its report for upload.
  func endShift() async {
    guard let ended = store.endShift() else { return }
    uploads.enqueue(store.makeReport(for: ended))
    voice.stop()
    let flags = ended.flags
    let confirmed = flags.count(where: { $0.status == .confirmed })
    let dismissed = flags.count(where: { $0.status == .dismissed })
    let waiting = flags.count(where: { $0.status == .waiting })
    await Speaker.shared.speak(
      "Shift ended. \(flags.count) flags: \(confirmed) confirmed, \(dismissed) dismissed, \(waiting) waiting. Report queued for upload."
    )
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
      currentFacilityID = facility
    }
    if let text = alert.spokenText {
      await Speaker.shared.announce(text)
    }
  }

  /// Answers "status of <name>" from cached facility data.
  func speakStatus(of spokenName: String) async {
    guard let facility = facility(matching: spokenName) else {
      await Speaker.shared.speak("No status for \(spokenName).")
      return
    }
    currentFacilityID = facility.id
    if let text = facility.spokenText {
      await Speaker.shared.speak(text)
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

  // MARK: - Flags

  /// Backend flagged a frame: save it, chime, and ask for a decision.
  private func handleCameraFlag(type: String, frame: UIImage) async {
    store.addFlag(type: type, source: "camera", status: .waiting, frame: frame, facility: currentFacilityID)
    await Speaker.shared.announce("possible \(type), confirm or dismiss")
  }

  // MARK: - Voice commands

  func handle(_ command: VoiceCommand) async {
    switch command {
    case .next:
      await speakNextAlert()
    case .status(let facility):
      await speakStatus(of: facility)
    case .confirm, .dismiss:
      let status: FlagStatus = command == .confirm ? .confirmed : .dismissed
      guard let flag = store.currentFlag else {
        await Speaker.shared.speak("No flag waiting.")
        return
      }
      store.setStatus(status, for: flag.id)
      await Speaker.shared.speak(status == .confirmed ? "Confirmed." : "Dismissed.")
    case .note(let text):
      store.addNote(text, to: store.currentFlag?.id)
      await Speaker.shared.speak("Note saved.")
    case .flag(let type):
      // The operator raised it, so it needs no confirm step.
      store.addFlag(type: type, source: "voice", status: .confirmed, frame: vision.latestFrame, facility: currentFacilityID)
      await Speaker.shared.speak("\(type) flagged.")
    }
  }
}
