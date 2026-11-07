//
// Config.swift
//
// NightShift backend configuration. No secrets or API keys belong here.
//

import Foundation

enum Config {
  /// `true` serves bundled mock JSON (MockAPI); `false` talks to `baseURL` (RealAPI).
  static let useMock = false

  /// Backend base URL. An IPv6 host must stay in square brackets. Plain HTTP to an IP
  /// address is allowed by NSAllowsLocalNetworking in Info.plist.
  static let baseURL = URL(string: "http://[2607:fb91:2749:83c7:1441:c3:fc57:f7bc]:8000")!

  /// Request timeout, kept short so offline fallbacks to the cache kick in quickly.
  static let requestTimeout: TimeInterval = 10

  /// How often a streaming frame is sent to /vision/check.
  static let visionCheckInterval: Duration = .seconds(4)

  static func makeAPI() -> any NightShiftAPI {
    useMock ? MockAPI() : RealAPI(baseURL: baseURL)
  }
}
