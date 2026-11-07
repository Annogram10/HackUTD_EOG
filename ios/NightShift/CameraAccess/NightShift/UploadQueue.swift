//
// UploadQueue.swift
//
// Persistent outbox for shift reports (Documents/NightShift/outbox/<shift id>.json).
// Uploads via POST /report when the phone is online, retries on reconnect and every
// minute after a failure. Re-enqueueing the same shift replaces its pending report.
//

import Foundation
import Observation

@Observable
@MainActor
final class UploadQueue {
  /// Reports saved but not yet accepted by the backend.
  private(set) var pendingCount = 0

  @ObservationIgnored private let api: any NightShiftAPI
  @ObservationIgnored private let outbox: URL
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var isDraining = false

  private static let retryInterval: Duration = .seconds(60)

  init(
    api: any NightShiftAPI,
    outbox: URL = URL.documentsDirectory.appending(path: "NightShift/outbox", directoryHint: .isDirectory)
  ) {
    self.api = api
    self.outbox = outbox
    try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    pendingCount = pendingFiles().count

    NetworkMonitor.shared.addObserver { [weak self] connected in
      guard connected else { return }
      Task { await self?.drain() }
    }
    if pendingCount > 0 {
      Task { await drain() }
    }
  }

  /// Saves the report to the outbox, then tries to upload everything pending.
  func enqueue(_ report: ShiftReport) {
    do {
      let data = try JSONCoding.encoder.encode(report)
      try data.write(to: outbox.appending(path: "\(report.shiftId).json"), options: .atomic)
    } catch {
      NSLog("[NightShift] Couldn't save report: \(error)")
      return
    }
    pendingCount = pendingFiles().count
    Task { await drain() }
  }

  /// Uploads pending reports one at a time, oldest first. Offline: waits for the
  /// reconnect observer. Failure: retries in a minute.
  func drain() async {
    guard !isDraining else { return }
    isDraining = true
    defer {
      isDraining = false
      pendingCount = pendingFiles().count
    }
    retryTask?.cancel()

    while let file = pendingFiles().first {
      guard NetworkMonitor.shared.isConnected else { return }
      do {
        let data = try Data(contentsOf: file)
        let report = try JSONCoding.decoder.decode(ShiftReport.self, from: data)
        try await api.submitReport(report)
        // If the shift was re-enqueued during the upload, the file now holds a newer
        // report: keep it so the next loop pass sends it.
        if (try? Data(contentsOf: file)) == data {
          try? FileManager.default.removeItem(at: file)
        }
      } catch is DecodingError {
        // A corrupt outbox file would block the queue forever; drop it.
        NSLog("[NightShift] Dropping unreadable report \(file.lastPathComponent)")
        try? FileManager.default.removeItem(at: file)
      } catch {
        NSLog("[NightShift] Report upload failed, retrying later: \(error)")
        scheduleRetry()
        return
      }
    }
  }

  private func scheduleRetry() {
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.retryInterval)
      guard !Task.isCancelled else { return }
      await self?.drain()
    }
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
