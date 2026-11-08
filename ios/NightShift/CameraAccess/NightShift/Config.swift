//
// Config.swift
//
// NightShift backend configuration. No secrets or API keys belong here.
//

import Foundation

enum Config {
  /// `true` serves bundled mock JSON (MockAPI); `false` talks to `baseURL` (RealAPI).
  static let useMock = false

  /// Built-in backend address (HTTPS via Cloudflare tunnel, so no ATS exception is needed).
  static let defaultBaseURL = URL(string: "https://fri-favourite-ids-bool.trycloudflare.com")!

  /// UserDefaults key for the address entered on the Shift screen.
  private static let baseURLKey = "NightShift.backendBaseURL"

  /// Backend base URL: the saved address if valid, otherwise `defaultBaseURL`. Read at
  /// request time so a new tunnel address takes effect immediately.
  static var baseURL: URL {
    savedBaseURL ?? defaultBaseURL
  }

  /// The valid address saved in the app, if any.
  static var savedBaseURL: URL? {
    UserDefaults.standard.string(forKey: baseURLKey).flatMap(normalizedBaseURL(from:))
  }

  /// Normalizes and saves a typed or pasted address. Returns nil (saving nothing) if invalid.
  @discardableResult
  static func saveBaseURL(_ input: String) -> URL? {
    guard let url = normalizedBaseURL(from: input) else { return nil }
    UserDefaults.standard.set(url.absoluteString, forKey: baseURLKey)
    return url
  }

  /// Forgets the saved address so `defaultBaseURL` is used again.
  static func resetBaseURL() {
    UserDefaults.standard.removeObject(forKey: baseURLKey)
  }

  /// Trims whitespace, adds "https://" if no scheme, drops path/query/fragment and any
  /// trailing slash. Returns nil unless the result is an https URL with a host.
  static func normalizedBaseURL(from input: String) -> URL? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") {
      text = "https://" + text
    }
    guard
      var components = URLComponents(string: text),
      components.scheme?.lowercased() == "https",
      let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
    else { return nil }
    components.scheme = "https"
    components.host = host.lowercased()
    components.user = nil
    components.password = nil
    components.path = ""
    components.query = nil
    components.fragment = nil
    return components.url
  }

  /// Request timeout, kept short so offline fallbacks to the cache kick in quickly.
  static let requestTimeout: TimeInterval = 10

  /// How often a streaming frame is sent to /vision/check.
  static let visionCheckInterval: Duration = .seconds(4)

  static func makeAPI() -> any NightShiftAPI {
    useMock ? MockAPI() : RealAPI()
  }
}
