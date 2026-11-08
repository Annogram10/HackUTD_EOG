//
// UploadQueue.swift
//
// Persistent outbox for shift reports (Documents/NightShift/outbox/<shift id>.json).
// Every report has a client_id saved in its outbox file before the first attempt, so
// retries send the same id and the server never stores a report twice. Uploads via
// POST /report when online; retries on reconnect, when GET /clock succeeds, and every
// minute after a failure. Each report shows Sending / Sent / Queued / Failed.
//

import Foundation
import Observation

@Observable
@MainActor
final class UploadQueue {
  /// What the operator sees for one report.
  enum State: Equatable, Sendable {
    /// Uploading; 0...1 when the body's progress is known.
    case sending(progress: Double?)
    case sent(at: Date)
    /// Waiting for a connection; sends by itself when online.
    case queued
    /// The server or the upload failed; retried automatically and by tapping.
    case failed(message: String)
  }

  struct Entry: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var state: State
  }

  /// Reports saved but not yet accepted by the backend.
  private(set) var pendingCount = 0
  /// Newest first: pending reports plus those sent during this launch.
  private(set) var entries: [Entry] = []

  @ObservationIgnored private let api: any NightShiftAPI
  @ObservationIgnored private let outbox: URL
  @ObservationIgnored private let isOnline: @MainActor () -> Bool
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var isDraining = false

  /// Called after each report the backend accepts (e.g. to refresh the map ranking).
  @ObservationIgnored var onUploaded: (@MainActor () async -> Void)?

  private static let retryInterval: Duration = .seconds(60)

  init(
    api: any NightShiftAPI,
    outbox: URL = URL.documentsDirectory.appending(path: "NightShift/outbox", directoryHint: .isDirectory),
    isOnline: @escaping @MainActor () -> Bool = { NetworkMonitor.shared.isConnected },
    observeNetwork: Bool = true
  ) {
    self.api = api
    self.outbox = outbox
    self.isOnline = isOnline
    try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    refreshPending(defaultState: .queued)

    if observeNetwork {
      NetworkMonitor.shared.addObserver { [weak self] connected in
        guard connected else { return }
        Task { await self?.drain() }
      }
    }
    if pendingCount > 0 {
      Task { await drain() }
    }
  }

  /// Saves the report to the outbox (with a client_id), then tries to upload.
  func enqueue(_ report: ShiftReport) {
    var report = report
    if report.clientId == nil {
      report.clientId = UUID()
    }
    do {
      let data = try JSONCoding.encoder.encode(report)
      try data.write(to: fileURL(for: report.shiftId), options: .atomic)
    } catch {
      NSLog("[NightShift] Couldn't save report: \(error)")
      return
    }
    setState(.queued, for: report.shiftId, startedAt: report.startedAt)
    pendingCount = pendingFiles().count
    Task { await drain() }
  }

  /// Uploads pending reports one at a time, oldest first. Offline: they stay Queued
  /// until a reconnect or a successful GET /clock. Failure: retried in a minute.
  func drain() async {
    guard !isDraining else { return }
    isDraining = true
    defer {
      isDraining = false
      pendingCount = pendingFiles().count
    }
    retryTask?.cancel()

    for file in pendingFiles() {
      let data: Data
      var report: ShiftReport
      do {
        data = try Data(contentsOf: file)
        report = try JSONCoding.decoder.decode(ShiftReport.self, from: data)
      } catch {
        // A corrupt outbox file would block the queue forever; drop it.
        NSLog("[NightShift] Dropping unreadable report \(file.lastPathComponent)")
        try? FileManager.default.removeItem(at: file)
        continue
      }
      // Reports queued by older builds get their client_id now, saved before sending.
      if report.clientId == nil {
        report.clientId = UUID()
        try? JSONCoding.encoder.encode(report).write(to: file, options: .atomic)
      }
      let sentData = (try? Data(contentsOf: file)) ?? data

      guard isOnline() else {
        setState(.queued, for: report.shiftId, startedAt: report.startedAt)
        continue
      }
      setState(.sending(progress: nil), for: report.shiftId, startedAt: report.startedAt)
      do {
        let shiftID = report.shiftId
        try await api.submitReport(report) { [weak self] fraction in
          Task { @MainActor in
            guard let self, case .sending = self.entries.first(where: { $0.id == shiftID })?.state else { return }
            self.setState(.sending(progress: fraction), for: shiftID, startedAt: nil)
          }
        }
        // If the shift was re-enqueued during the upload, the file holds a newer
        // report: keep it so the next pass sends it.
        if (try? Data(contentsOf: file)) == sentData {
          try? FileManager.default.removeItem(at: file)
        }
        setState(.sent(at: Date()), for: report.shiftId, startedAt: report.startedAt)
        await sendPriorities(of: report)
        await onUploaded?()
      } catch {
        NSLog("[NightShift] Report upload failed, retrying later: \(error)")
        setState(Self.isOffline(error) ? .queued : .failed(message: NightShiftAPIError.describe(error)),
                 for: report.shiftId, startedAt: report.startedAt)
        scheduleRetry()
      }
    }
  }

  /// The backend's report format has no priority field, but it stores each flag under
  /// the phone's flag id, so prioritized flags are marked with POST /flag/{id}/prioritize
  /// (which puts the facility at the top of the next-shift list). Best effort: the
  /// report itself is already saved.
  private func sendPriorities(of report: ShiftReport) async {
    for flag in report.flags where flag.priority == true && flag.status != .dismissed {
      do {
        _ = try await api.decideFlag(id: flag.id.uuidString, action: .prioritize)
      } catch {
        NSLog("[NightShift] Couldn't mark flag \(flag.id) a priority: \(error)")
      }
    }
  }

  /// "Tap to retry" on a failed report.
  func retry(_ id: UUID) {
    guard let index = entries.firstIndex(where: { $0.id == id }), case .failed = entries[index].state else { return }
    entries[index].state = .queued
    Task { await drain() }
  }

  // MARK: - Helpers

  /// No connection at all: Queued (sends by itself). Anything else is Failed.
  static func isOffline(_ error: any Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]
      .contains(urlError.code)
  }

  private func setState(_ state: State, for id: UUID, startedAt: Date?) {
    if let index = entries.firstIndex(where: { $0.id == id }) {
      entries[index].state = state
    } else {
      entries.insert(Entry(id: id, startedAt: startedAt ?? Date(), state: state), at: 0)
    }
  }

  private func refreshPending(defaultState: State) {
    for file in pendingFiles() {
      guard let report = try? JSONCoding.decoder.decode(ShiftReport.self, from: Data(contentsOf: file)) else { continue }
      if !entries.contains(where: { $0.id == report.shiftId }) {
        entries.append(Entry(id: report.shiftId, startedAt: report.startedAt, state: defaultState))
      }
    }
    pendingCount = pendingFiles().count
  }

  private func scheduleRetry() {
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.retryInterval)
      guard !Task.isCancelled else { return }
      await self?.drain()
    }
  }

  private func fileURL(for shiftID: UUID) -> URL {
    outbox.appending(path: "\(shiftID).json")
  }

  /// Outbox files, oldest first (FIFO upload order).
  private func pendingFiles() -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: outbox,
      includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    return files
      .filter { $0.pathExtension == "json" }
      .sorted { lhs, rhs in
        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return l < r
      }
  }
}
