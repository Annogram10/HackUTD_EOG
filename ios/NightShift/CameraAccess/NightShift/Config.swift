//
// Config.swift
//
// NightShift backend configuration. No secrets or API keys belong here.
//

import Foundation

enum Config {
  /// `true` serves bundled mock JSON (MockAPI); `false` talks to `baseURL` (RealAPI).
  static let useMock = false

  /// Backend base URL (HTTPS via Cloudflare tunnel, so no ATS exception is needed).
  static let baseURL = URL(string: "https://fri-favourite-ids-bool.trycloudflare.com")!

  /// Request timeout, kept short so offline fallbacks to the cache kick in quickly.
  static let requestTimeout: TimeInterval = 10

  /// How often a streaming frame is sent to /vision/check.
  static let visionCheckInterval: Duration = .seconds(4)

  static func makeAPI() -> any NightShiftAPI {
    useMock ? MockAPI() : RealAPI(baseURL: baseURL)
  }
}
