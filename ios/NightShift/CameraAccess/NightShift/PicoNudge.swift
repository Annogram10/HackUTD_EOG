//
// PicoNudge.swift
//
// Wake-up for the Pico servo/buzzer on the local network:
// GET http://<PICO_IP>/wake?level=N (N = 1, 2 or 3) with a 1 s timeout.
// During alarms it's fire-and-forget: it never blocks, delays or crashes the alarm.
// Every result is recorded so Settings can show "Last nudge: ok 01:42".
//

import Foundation
import Observation

/// The last nudge result, for Settings.
@Observable
@MainActor
final class PicoStatus {
  static let shared = PicoStatus()

  struct Result: Equatable, Sendable {
    let level: Int
    let ok: Bool
    /// "HTTP 200", "timed out", "no Pico address", …
    let detail: String
    let at: Date
  }

  private(set) var last: Result?

  func record(_ result: Result) {
    last = result
  }
}

enum PicoNudge {
  /// Short-timeout session so a missing Pico never holds anything up.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 1
    config.timeoutIntervalForResource = 1
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  /// Alarm path: sends the level in the background and records the result. Returns
  /// immediately.
  static func wake(level: Int) {
    Task.detached(priority: .utility) {
      _ = await send(level: level)
    }
  }

  /// Settings "Test nudge": waits for the answer (at most ~1 s) and returns it.
  static func test(level: Int) async -> PicoStatus.Result {
    await send(level: level)
  }

  /// One GET /wake?level=N; never throws. Records the result on the main actor.
  @discardableResult
  private static func send(level: Int) async -> PicoStatus.Result {
    let result: PicoStatus.Result
    if let address = Config.picoAddress,
      let url = URL(string: "http://\(address)/wake?level=\(level)")
    {
      var request = URLRequest(url: url)
      request.timeoutInterval = 1
      do {
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        result = PicoStatus.Result(level: level, ok: (200..<300).contains(code), detail: "HTTP \(code)", at: Date())
      } catch let error as URLError where error.code == .timedOut {
        result = PicoStatus.Result(level: level, ok: false, detail: "timed out", at: Date())
      } catch {
        result = PicoStatus.Result(level: level, ok: false, detail: "unreachable", at: Date())
      }
    } else {
      result = PicoStatus.Result(level: level, ok: false, detail: "no Pico address", at: Date())
    }
    await MainActor.run { PicoStatus.shared.record(result) }
    return result
  }
}
