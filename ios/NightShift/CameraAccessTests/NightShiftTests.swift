//
// NightShiftTests.swift
//
// Unit tests for the alarm path, decoding and the report outbox. The network is
// mocked at the protocol seams (NightShiftAPI, HTTPTransport); time is injected, so
// no test sleeps for real escalation intervals.
//

@testable import CameraAccess
import Foundation
import os
import Testing

// MARK: - Test doubles

/// Scriptable backend. Handlers run off the main actor; counters are lock-protected.
final class TestAPI: NightShiftAPI, @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock()
  private var _alarmCalls = 0
  private var _reports: [ShiftReport] = []

  var alarmHandler: @Sendable () async throws -> AlarmStatus = { try decodeAlarm(#"{"alarm": false}"#) }
  var reportHandler: @Sendable (Int) async throws -> Void = { _ in }

  var alarmCalls: Int { lock.withLock { _alarmCalls } }
  var reports: [ShiftReport] { lock.withLock { _reports } }

  func fetchAlarm() async throws -> AlarmStatus {
    lock.withLock { _alarmCalls += 1 }
    return try await alarmHandler()
  }

  func submitReport(_ report: ShiftReport, progress: (@Sendable (Double) -> Void)?) async throws {
    let attempt = lock.withLock { () -> Int in
      _reports.append(report)
      return _reports.count
    }
    try await reportHandler(attempt)
  }

  func fetchAlerts() async throws -> [ShiftAlert] { [] }
  func fetchFacility(id: String) async throws -> FacilityStatus { throw URLError(.unsupportedURL) }
  func fetchHandoff() async throws -> Handoff { throw URLError(.unsupportedURL) }
  func fetchMap() async throws -> FacilityMap { throw URLError(.unsupportedURL) }
  func fetchClock() async throws -> ServerClock { ServerClock(dataset: "test", now: nil, nowTs: nil, mode: "live") }
  func fetchIssue(facility: String?) async throws -> IssueReport { throw URLError(.unsupportedURL) }
  func decideFlag(id: String, action: FlagAction) async throws -> BackendFlag { throw URLError(.unsupportedURL) }
  func checkVision(jpeg: Data, facility: String?) async throws -> VisionResult { VisionResult(flag: false, type: nil) }
}

/// Records what the alarm would have done instead of making sound or windows.
@MainActor
final class RecordingEffects: AlarmEffects {
  var starts = 0
  var stops = 0
  var spoken: [String] = []
  var nudges: [Int] = []

  func startAlarm(monitor: AlarmMonitor) { starts += 1 }
  func stopAlarm() { stops += 1 }
  func silenceSiren() {}
  func setSirenDucked(_ ducked: Bool) {}
  func speak(_ text: String) async { spoken.append(text) }
  func stopSpeech() {}
  func nudge(level: Int) { nudges.append(level) }
}

/// A clock the test moves by hand. `sleep` just parks until cancelled, so loops that
/// sleep never spin; tests drive time-based logic through `now`.
@MainActor
final class TestClock: AlarmClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  func sleep(for duration: Duration) async {
    try? await Task.sleep(for: .seconds(3600))
  }
}

/// Captures requests and replies with a fixed response.
final class MockTransport: HTTPTransport, @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock()
  private var _requests: [URLRequest] = []
  let status: Int
  let body: Data
  let headers: [String: String]

  init(status: Int = 200, body: String = "{}", headers: [String: String] = [:]) {
    self.status = status
    self.body = Data(body.utf8)
    self.headers = headers
  }

  var requests: [URLRequest] { lock.withLock { _requests } }

  func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
    lock.withLock { _requests.append(request) }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    return (body, response)
  }
}

private func decodeAlarm(_ json: String) throws -> AlarmStatus {
  try JSONCoding.decoder.decode(AlarmStatus.self, from: Data(json.utf8))
}

private let sampleAlarm = #"{"alarm": true, "alarm_id": "ds:S5_FACILITY_C:pump", "headline": "Tank will shut down", "spoken_text": "Alarm.", "facility_ids": ["S5_FACILITY_C"], "level": "red"}"#

/// Waits (briefly, in real time) for unstructured tasks to catch up.
@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async {
  let deadline = ContinuousClock.now + timeout
  while !condition() && ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor
private func makeMonitor(
  api: TestAPI,
  effects: RecordingEffects,
  clock: TestClock = TestClock(),
  defaults: UserDefaults
) -> AlarmMonitor {
  AlarmMonitor(api: api, voice: VoiceCommandListener(), effects: effects, clock: clock, defaults: defaults, listensDuringAlarm: false)
}

private func freshDefaults() -> UserDefaults {
  let name = "NightShiftTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}

// MARK: - Alarm polling

@MainActor
@Suite struct AlarmPollingTests {
  @Test func noOverlappingPolls() async {
    let api = TestAPI()
    // The first request hangs until released.
    let gate = AsyncStream<Void>.makeStream()
    api.alarmHandler = {
      for await _ in gate.stream { break }
      return try decodeAlarm(#"{"alarm": false}"#)
    }
    let monitor = makeMonitor(api: api, effects: RecordingEffects(), defaults: freshDefaults())

    let first = Task { await monitor.pollOnce() }
    await waitUntil { api.alarmCalls == 1 }
    // A tick while the first is still in flight is skipped, not queued.
    await monitor.pollOnce()
    await monitor.pollOnce()
    #expect(api.alarmCalls == 1)
    #expect(monitor.pollsStarted == 1)

    gate.continuation.yield()
    gate.continuation.finish()
    await first.value
    await monitor.pollOnce()
    #expect(api.alarmCalls == 2)
  }

  @Test func threeFailuresSayMonitoringLostOnce() async {
    let api = TestAPI()
    api.alarmHandler = { throw URLError(.timedOut) }
    let effects = RecordingEffects()
    let monitor = makeMonitor(api: api, effects: effects, defaults: freshDefaults())

    await monitor.pollOnce()
    await monitor.pollOnce()
    #expect(!monitor.monitoringLost)
    for _ in 0..<5 { await monitor.pollOnce() }
    await waitUntil { !effects.spoken.isEmpty }

    #expect(monitor.monitoringLost)
    #expect(effects.spoken.filter { $0 == "Monitoring lost" }.count == 1)
    // Backoff: 8 s right after losing contact, then capped at 15 s.
    #expect(monitor.nextPollDelay == .seconds(15))
  }

  @Test func recoverySaysRestoredOnce() async {
    let api = TestAPI()
    api.alarmHandler = { throw URLError(.notConnectedToInternet) }
    let effects = RecordingEffects()
    let monitor = makeMonitor(api: api, effects: effects, defaults: freshDefaults())
    for _ in 0..<3 { await monitor.pollOnce() }
    #expect(monitor.monitoringLost)
    #expect(monitor.nextPollDelay == .seconds(8))

    api.alarmHandler = { try decodeAlarm(#"{"alarm": false}"#) }
    await monitor.pollOnce()
    await monitor.pollOnce()
    await waitUntil { effects.spoken.contains("Monitoring restored") }

    #expect(!monitor.monitoringLost)
    #expect(monitor.lastSuccess != nil)
    #expect(monitor.nextPollDelay == .seconds(4))
    #expect(effects.spoken.filter { $0 == "Monitoring restored" }.count == 1)
    #expect(effects.spoken.filter { $0 == "Monitoring lost" }.count == 1)
  }
}

// MARK: - Alarm lifecycle

@MainActor
@Suite struct AlarmLifecycleTests {
  @Test func acknowledgementSurvivesRelaunch() async {
    let defaults = freshDefaults()
    let api = TestAPI()
    api.alarmHandler = { try decodeAlarm(sampleAlarm) }

    let effects = RecordingEffects()
    let first = makeMonitor(api: api, effects: effects, defaults: defaults)
    await first.pollOnce()
    #expect(first.active != nil)
    #expect(effects.starts == 1)
    first.acknowledge()
    #expect(first.active == nil)

    // "Relaunch": a new monitor with the same stored defaults sees the same alarm.
    let relaunchedEffects = RecordingEffects()
    let relaunched = makeMonitor(api: api, effects: relaunchedEffects, defaults: defaults)
    await relaunched.pollOnce()
    #expect(relaunched.active == nil)
    #expect(relaunchedEffects.starts == 0)
    #expect(relaunched.isBackendAlarmAcknowledged)

    // A different alarm_id always alarms.
    api.alarmHandler = { try decodeAlarm(sampleAlarm.replacingOccurrences(of: "pump", with: "leak")) }
    await relaunched.pollOnce()
    #expect(relaunched.active != nil)
    #expect(relaunchedEffects.starts == 1)
  }

  @Test func escalationTiming() async {
    let api = TestAPI()
    api.alarmHandler = { try decodeAlarm(sampleAlarm) }
    let effects = RecordingEffects()
    let clock = TestClock()
    let monitor = makeMonitor(api: api, effects: effects, clock: clock, defaults: freshDefaults())
    let start = clock.now

    await monitor.pollOnce()
    #expect(effects.nudges == [1])

    monitor.escalationTick(now: start.addingTimeInterval(59))
    #expect(effects.nudges == [1])
    monitor.escalationTick(now: start.addingTimeInterval(60))
    #expect(effects.nudges == [1, 2])
    monitor.escalationTick(now: start.addingTimeInterval(119))
    #expect(effects.nudges == [1, 2])
    monitor.escalationTick(now: start.addingTimeInterval(120))
    #expect(effects.nudges == [1, 2, 3])
    monitor.escalationTick(now: start.addingTimeInterval(600))
    #expect(effects.nudges == [1, 2, 3])

    // Acknowledge stops escalation immediately.
    monitor.acknowledge()
    #expect(effects.stops >= 1)
    monitor.escalationTick(now: start.addingTimeInterval(1_000))
    #expect(effects.nudges == [1, 2, 3])
  }

  @Test func sameAlarmDoesNotRestartWhileActive() async {
    let api = TestAPI()
    api.alarmHandler = { try decodeAlarm(sampleAlarm) }
    let effects = RecordingEffects()
    let monitor = makeMonitor(api: api, effects: effects, defaults: freshDefaults())
    await monitor.pollOnce()
    await monitor.pollOnce()
    await monitor.pollOnce()
    #expect(effects.starts == 1)
  }
}

// MARK: - Decoding

@Suite struct DecodingTests {
  @Test func alarmWithoutNewFields() throws {
    let alarm = try decodeAlarm(#"{"alarm": true, "facility_ids": ["F1"], "level": "red"}"#)
    #expect(alarm.alarm)
    #expect(alarm.alarmId == nil)
    #expect(alarm.severity == nil)
    #expect(alarm.mode == nil)
    #expect(alarm.severityKey == "red")
    // Old backends: identity falls back to facility id + level.
    #expect(AlarmMonitor.identity(of: alarm) == "F1:red")
  }

  @Test func alarmAlmostEmpty() throws {
    let alarm = try decodeAlarm("{}")
    #expect(!alarm.alarm)
    #expect(alarm.reasons.isEmpty)
    #expect(AlarmMonitor.identity(of: alarm) == "unknown:unknown")
  }

  @Test func alarmNewFields() throws {
    let alarm = try decodeAlarm(#"{"alarm": true, "alarm_id": "ds:F1:e", "severity": "HIGH", "mode": "Replay", "note": "Check gauge", "level": "red"}"#)
    #expect(alarm.severityKey == "high")
    #expect(alarm.mode == "replay")
    #expect(alarm.note == "Check gauge")
    #expect(AlarmMonitor.identity(of: alarm) == "ds:F1:e")
  }

  @Test func mapFacilitySeverityFallsBackToLevel() throws {
    let json = #"{"facilities": [{"id": "F1", "level": "medium"}, {"id": "F2", "level": "low", "severity": "high"}, {"name": "no id"}]}"#
    let map = try JSONCoding.decoder.decode(FacilityMap.self, from: Data(json.utf8))
    #expect(map.facilities.count == 2)
    #expect(map.facilities[0].severityKey == "medium")
    #expect(map.facilities[1].severityKey == "high")
  }

  @Test func clockShapes() throws {
    let empty = try JSONCoding.decoder.decode(ServerClock.self, from: Data("{}".utf8))
    #expect(empty.mode == nil)
    #expect(!empty.isReplay)
    let replay = try JSONCoding.decoder.decode(ServerClock.self, from: Data(#"{"dataset": "full_week", "now": 1791419400, "mode": "REPLAY"}"#.utf8))
    #expect(replay.isReplay)
    #expect(replay.nowDate == Date(timeIntervalSince1970: 1_791_419_400))
  }
}

// MARK: - Reports

@MainActor
@Suite struct ReportQueueTests {
  private func tempOutbox() -> URL {
    URL.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func sampleReport() -> ShiftReport {
    ShiftReport(
      shiftId: UUID(),
      clientId: nil,
      date: "2026-11-08",
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      endedAt: Date(timeIntervalSince1970: 1_800_003_600),
      flags: [],
      notes: [],
      generatedAt: Date()
    )
  }

  @Test func retryKeepsTheSameClientID() async {
    let api = TestAPI()
    // First attempt: server error. Second: accepted.
    api.reportHandler = { attempt in
      if attempt == 1 { throw NightShiftAPIError.badStatus(500, path: "report") }
    }
    let queue = UploadQueue(api: api, outbox: tempOutbox(), isOnline: { true }, observeNetwork: false)
    queue.enqueue(sampleReport())
    await waitUntil { queue.entries.first?.state.isFailed == true }
    #expect(queue.pendingCount == 1)

    await queue.drain()
    #expect(api.reports.count == 2)
    let ids = api.reports.map(\.clientId)
    #expect(ids[0] != nil)
    #expect(ids[0] == ids[1])
    #expect(queue.pendingCount == 0)
    if case .sent = queue.entries.first?.state {} else {
      Issue.record("Expected Sent, got \(String(describing: queue.entries.first?.state))")
    }
  }

  @Test func queueSurvivesRelaunchWhileOffline() async {
    let outbox = tempOutbox()
    let api = TestAPI()
    let report = sampleReport()

    let queue = UploadQueue(api: api, outbox: outbox, isOnline: { false }, observeNetwork: false)
    queue.enqueue(report)
    await waitUntil { queue.entries.first?.state == .queued }
    #expect(api.reports.isEmpty)

    // "Relaunch": a new queue on the same folder still has the report, queued.
    let relaunched = UploadQueue(api: api, outbox: outbox, isOnline: { false }, observeNetwork: false)
    #expect(relaunched.pendingCount == 1)
    #expect(relaunched.entries.first?.id == report.shiftId)
    #expect(relaunched.entries.first?.state == .queued)
  }

  @Test func offlineErrorIsQueuedNotFailed() {
    #expect(UploadQueue.isOffline(URLError(.notConnectedToInternet)))
    #expect(!UploadQueue.isOffline(URLError(.timedOut)))
    #expect(!UploadQueue.isOffline(NightShiftAPIError.badStatus(500, path: "report")))
  }
}

// MARK: - Transport (mocked URLSession seam)

@Suite struct TransportTests {
  @Test func reportCarriesClientIDAndNgrokHeader() async throws {
    let transport = MockTransport()
    let api = RealAPI(transport: transport)
    let clientID = UUID()
    let report = ShiftReport(shiftId: UUID(), clientId: clientID, date: nil, startedAt: Date(), endedAt: nil, flags: [], notes: [], generatedAt: Date())

    try await api.submitReport(report, progress: nil)

    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path().hasSuffix("/report") == true)
    #expect(request.value(forHTTPHeaderField: "ngrok-skip-browser-warning") == "true")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["client_id"] as? String == clientID.uuidString)
  }

  @Test func alarmDecodesThroughTransport() async throws {
    let transport = MockTransport(body: #"{"alarm": true, "level": "red", "facility_ids": ["F9"]}"#)
    let alarm = try await RealAPI(transport: transport).fetchAlarm()
    #expect(alarm.alarm)
    #expect(AlarmMonitor.identity(of: alarm) == "F9:red")
    #expect(transport.requests.first?.timeoutInterval == Config.pollRequestTimeout)
  }

  /// ngrok's "endpoint offline" page (what the phone saw when monitoring was lost).
  @Test func ngrokOfflineIsTunnelOffline() async {
    let transport = MockTransport(status: 404, body: "<html>offline</html>", headers: ["ngrok-error-code": "ERR_NGROK_3200"])
    do {
      _ = try await RealAPI(transport: transport).fetchAlarm()
      Issue.record("Expected an error")
    } catch {
      #expect(NightShiftAPIError.isBackendUnreachable(error))
      #expect(NightShiftAPIError.describe(error).contains("Tunnel offline"))
    }
  }

  @Test func unauthorizedHasAHumanMessage() {
    let text = NightShiftAPIError.describe(NightShiftAPIError.badStatus(401, path: "flag/x/prioritize"))
    #expect(text.contains("API key"))
    let missing = NightShiftAPIError.describe(NightShiftAPIError.badStatus(404, path: "flag/x/prioritize"))
    #expect(missing.contains("isn't on the server"))
  }
}

// MARK: - City map

/// The phone draws the same city as the dashboard (frontend/lib/city.ts). Expected
/// values were produced by running city.ts on data/full_week system S1.
@Suite struct CityMapTests {
  private func s1() -> (CityMap.Layout, CityMap.City) {
    let facilities: [(id: String, at: CityMap.LatLon)] = [
      ("S1_FACILITY_A", .init(lat: 31.912, lon: -102.34)),
      ("S1_FACILITY_B", .init(lat: 31.835, lon: -102.36)),
      ("S1_FACILITY_C", .init(lat: 31.79, lon: -102.25)),
    ]
    let layout = CityMap.layout(
      facilities: facilities, disposal: .init(lat: 31.87, lon: -102.295), truckYard: .init(lat: 31.65, lon: -102.6))
    return (layout, CityMap.buildCity(systemID: "S1", layout: layout))
  }

  @Test func layoutMatchesDashboard() throws {
    let (layout, _) = s1()
    let a = try #require(layout.pos["S1_FACILITY_A"])
    #expect(abs(a.x - 42.628528) < 1e-5 && abs(a.y - 10.756967) < 1e-5)
    #expect(abs(layout.disp.x - 52.106135) < 1e-5 && abs(layout.disp.y - 23.413934) < 1e-5)
    let yard = try #require(layout.yard)
    #expect(abs(yard.x - 23.748205) < 1e-5 && abs(yard.y - 51.25) < 1e-5)
  }

  @Test func cityMatchesDashboard() throws {
    let (_, city) = s1()
    #expect(city.blocks.count == 1683)
    #expect(city.streets.count == 1685)
    #expect(city.lights.count == 140)
    #expect(city.district == "NEON FLATS")
    #expect(city.landmarks.map(\.name) == ["Owlsaka Tower", "Brinetechnica", "Pumpitech", "Tank Tao", "Megatank H10", "Hootsuka Works"])
    let first = try #require(city.landmarks.first)
    #expect(abs(first.rect.x - 12.0556) < 1e-5 && abs(first.rect.y - 29.923991) < 1e-5)
  }
}
