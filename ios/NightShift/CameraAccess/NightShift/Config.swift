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
  /// True for private IPv4 (10/8, 172.16/12, 192.168/16, 127/8), link-local and *.local.
  static func isLocalHost(_ host: String) -> Bool {
    if host.hasSuffix(".local") { return true }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    switch (parts[0], parts[1]) {
    case (10, _), (127, _), (192, 168), (169, 254): return true
    case (172, 16...31): return true
    default: return false
    }
  }

  static func normalizedBaseURL(from input: String) -> URL? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if !text.contains("://") {
      text = "https://" + text
    }
    guard
      var components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
    else { return nil }
    // Plain http only reaches local addresses (ATS allows local networking only).
    if scheme == "http" && !isLocalHost(host.lowercased()) { return nil }
    components.scheme = scheme
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
  /// POST /vision/check: the backend gives the vision model up to 15 s, plus the frame
  /// upload through the tunnel, so this waits longer than other requests.
  static let visionRequestTimeout: TimeInterval = 25
  /// GET /alarm and other reads: per-request and whole-resource limits.
  static let pollRequestTimeout: TimeInterval = 5
  static let pollResourceTimeout: TimeInterval = 8
  /// Writes (reports with photos): give up after this long and offer a retry.
  static let uploadTimeout: TimeInterval = 20

  /// Shows the "Simulate camera flag" test button on the Shift screen.
  /// Turn off before a real demo.
  static let showTestTools = true

  // MARK: - On-phone settings (Settings tab), stored in UserDefaults

  /// Optional shared key for backend writes (X-API-Key), kept in the Keychain.
  static var apiKey: String? {
    Keychain.string(for: Keys.apiKeyAccount).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Validates "a.b.c.d" or "a.b.c.d:port" (each part 0–255, port 1–65535). Trims
  /// whitespace, a leading http:// and trailing slashes. nil if it doesn't parse.
  static func normalizedPicoAddress(_ input: String) -> String? {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.lowercased().hasPrefix("http://") { text.removeFirst(7) }
    while text.hasSuffix("/") { text.removeLast() }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else { return nil }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.allSatisfy({ part in
      !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
    }) else { return nil }
    if parts.count == 2 {
      guard let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
    }
    return text
  }

  enum Keys {
    static let apiKeyAccount = "backendAPIKey"
    /// Shown on the SHIFT tab only (not sent in reports).
    static let operatorName = "NightShift.operatorName"
    /// Text-to-speech rate (AVSpeechUtterance.rate), set in Settings.
    static let voiceRate = "NightShift.voiceRate"
    static let supervisorPhone = "NightShift.supervisorPhone"
    static let picoAddress = "NightShift.picoAddress"
    static let defaultSystem = "NightShift.defaultSystem"
  }

  /// Pico buzzer address (PICO_IP, optionally with :port), or nil if not set.
  static var picoAddress: String? {
    let raw = UserDefaults.standard.string(forKey: Keys.picoAddress)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "http://", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return raw?.isEmpty == false ? raw : nil
  }

  /// System the map starts on (nil = the system of the top-ranked facility).
  static var defaultSystem: String? {
    UserDefaults.standard.string(forKey: Keys.defaultSystem).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// How often GET /alarm is polled while the app is open.
  static let alarmPollInterval: Duration = .seconds(4)
  /// How often an unacknowledged alarm's spoken_text is repeated.
  static let alarmRepeatInterval: Duration = .seconds(15)
  /// How often GET /clock is read (also on launch and after an address change).
  static let clockRefreshInterval: Duration = .seconds(60)

  /// How often GET /map is reloaded while the app is open.
  static let mapRefreshInterval: Duration = .seconds(10)

  /// How often a streaming frame is sent to /vision/check.
  static let visionCheckInterval: Duration = .seconds(6)

  static func makeAPI() -> any NightShiftAPI {
    useMock ? MockAPI() : RealAPI()
  }
}
