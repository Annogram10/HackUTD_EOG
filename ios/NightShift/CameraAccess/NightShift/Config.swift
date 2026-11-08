//
// Config.swift
//
// NightShift backend configuration. No secrets or API keys belong here.
//

import Foundation

enum Config {
  /// `true` serves bundled mock JSON (MockAPI); `false` talks to `baseURL` (RealAPI).
  static let useMock = false

  /// Built-in backend address: the permanent ngrok domain (HTTPS, so no ATS exception is needed).
  static let defaultBaseURL = URL(string: "https://stubble-sensitize-reset.ngrok-free.dev")!

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
  /// GET /alarm and other reads: per-request and whole-resource limits.
  static let pollRequestTimeout: TimeInterval = 5
  static let pollResourceTimeout: TimeInterval = 8
  /// Writes (reports with photos): give up after this long and offer a retry.
  static let uploadTimeout: TimeInterval = 20

  /// Shows the "Simulate camera flag" test button on the Shift screen.
  /// Turn off before a real demo.
  static let showTestTools = true

  // MARK: - On-phone settings (Settings tab), stored in UserDefaults

  enum Keys {
    static let supervisorPhone = "NightShift.supervisorPhone"
    static let picoAddress = "NightShift.picoAddress"
    static let defaultSystem = "NightShift.defaultSystem"
    static let showDemoMapLayers = "NightShift.showDemoMapLayers"
  }

  /// Pico buzzer address (PICO_IP, optionally with :port), or nil if not set.
  static var picoAddress: String? {
    let raw = UserDefaults.standard.string(forKey: Keys.picoAddress)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "http://", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return raw?.isEmpty == false ? raw : nil
  }

  /// System the map starts on (nil = all).
  static var defaultSystem: String? {
    UserDefaults.standard.string(forKey: Keys.defaultSystem).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Wells and pipelines aren't in /map yet, so the map draws placeholder ("demo")
  /// layers for them while this is on. Defaults to on.
  static var showDemoMapLayers: Bool {
    UserDefaults.standard.object(forKey: Keys.showDemoMapLayers) as? Bool ?? true
  }

  /// How often GET /alarm is polled while the app is open.
  static let alarmPollInterval: Duration = .seconds(4)
  /// How often an unacknowledged alarm's spoken_text is repeated.
  static let alarmRepeatInterval: Duration = .seconds(15)
  /// How often GET /map is reloaded while the app is open.
  static let mapRefreshInterval: Duration = .seconds(10)

  /// How often a streaming frame is sent to /vision/check.
  static let visionCheckInterval: Duration = .seconds(6)

  static func makeAPI() -> any NightShiftAPI {
    useMock ? MockAPI() : RealAPI()
  }
}
