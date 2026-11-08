//
// PicoNudge.swift
//
// Fire-and-forget wake-up for the Pico buzzer on the local network:
// GET http://<PICO_IP>/wake?level=N with a 1 s timeout. Never blocks the UI; every
// failure (no address, unreachable, timeout) is ignored.
//

import Foundation

enum PicoNudge {
  /// Short-timeout session so a missing Pico never holds anything up.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 1
    config.timeoutIntervalForResource = 1
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  /// Sends level 1, 2 or 3 to the Pico at `Config.picoAddress`, if one is set.
  static func wake(level: Int) {
    guard let address = Config.picoAddress,
      let url = URL(string: "http://\(address)/wake?level=\(level)")
    else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    Task.detached(priority: .utility) {
      _ = try? await session.data(for: request)
    }
  }
}
