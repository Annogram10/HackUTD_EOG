//
// NightShiftAPI.swift
//
// The single boundary to the NightShift backend. `RealAPI` talks HTTP; `MockAPI` is a
// small offline demo fallback. Pick one with `Config.useMock`.
//

import Foundation
import Observation

protocol NightShiftAPI: Sendable {
  func fetchAlerts() async throws -> [ShiftAlert]
  func fetchFacility(id: String) async throws -> FacilityStatus
  func fetchHandoff() async throws -> Handoff
  /// Sends one JPEG frame for the given facility; the backend says whether it shows a problem.
  func checkVision(jpeg: Data, facility: String?) async throws -> VisionResult
  func submitReport(_ report: ShiftReport) async throws
}

enum NightShiftAPIError: LocalizedError {
  /// Non-2xx response. `path` is the request path, e.g. "alerts".
  case badStatus(Int, path: String)
  /// Cloudflare error page (e.g. 1033: the tunnel behind this address is gone).
  case cloudflare(Int)
  case missingMockResource(String)
  case unknownFacility(String)

  var errorDescription: String? {
    switch self {
    case .badStatus(404, let path): return "Not found (HTTP 404 on /\(path))."
    case .badStatus(let code, _): return "Server returned HTTP \(code)."
    case .cloudflare(let code): return "Cloudflare error \(code): tunnel is offline."
    case .missingMockResource(let name): return "Mock resource \(name) is missing from the app bundle."
    case .unknownFacility(let id): return "No facility with id \(id)."
    }
  }

  /// True for errors meaning the tunnel address is dead or wrong: connection failures,
  /// Cloudflare 530/1033/502, or 404 on /alerts. Phone-offline is not included.
  static func isBackendUnreachable(_ error: any Error) -> Bool {
    switch error {
    case NightShiftAPIError.badStatus(let code, let path):
      return code == 530 || code == 502 || (code == 404 && path == "alerts")
    case NightShiftAPIError.cloudflare:
      return true
    case let urlError as URLError:
      return [
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
        .networkConnectionLost, .badServerResponse, .secureConnectionFailed,
        .badURL, .unsupportedURL,
      ].contains(urlError.code)
    default:
      return false
    }
  }

  /// Short, specific text for the Test connection result.
  static func describe(_ error: any Error) -> String {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut: return "Timed out: no answer from the backend."
      case .notConnectedToInternet: return "No internet: the phone is offline."
      case .cannotFindHost, .dnsLookupFailed: return "Host not found: tunnel address is wrong or expired."
      case .cannotConnectToHost: return "Cannot connect to the backend."
      case .networkConnectionLost: return "Connection lost."
      case .badURL, .unsupportedURL: return "Bad address."
      case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
           .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
        return "Secure connection failed."
      default: return urlError.localizedDescription
      }
    }
    if error is DecodingError {
      return "Unexpected response: not alert data."
    }
    return error.localizedDescription
  }
}

/// Whether the last real backend request showed the tunnel address is dead.
@Observable
@MainActor
final class BackendStatus {
  static let shared = BackendStatus()

  private(set) var isUnreachable = false

  /// Records a request outcome: nil error means success.
  func record(_ error: (any Error)?) {
    if let error {
      if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
      if NightShiftAPIError.isBackendUnreachable(error) {
        isUnreachable = true
      }
    } else {
      isUnreachable = false
    }
  }

  /// Called when the address changes, so the old address's failure isn't shown.
  func reset() {
    isUnreachable = false
  }
}

// MARK: - Real

struct RealAPI: NightShiftAPI {
  /// Read on every request so a newly saved address applies immediately.
  private var baseURL: URL { Config.baseURL }

  func fetchAlerts() async throws -> [ShiftAlert] {
    let request = makeRequest("alerts")
    return try JSONCoding.decoder.decode(LossyArray<ShiftAlert>.self, from: try await send(request, path: "alerts")).elements
  }

  func fetchFacility(id: String) async throws -> FacilityStatus {
    try JSONCoding.decoder.decode(FacilityStatus.self, from: try await send(makeRequest("facility/\(id)"), path: "facility/\(id)"))
  }

  func fetchHandoff() async throws -> Handoff {
    try JSONCoding.decoder.decode(Handoff.self, from: try await send(makeRequest("handoff"), path: "handoff"))
  }

  /// Raw JPEG body (Content-Type: image/jpeg), facility as `?facility=<id>`.
  func checkVision(jpeg: Data, facility: String?) async throws -> VisionResult {
    let path = "vision/check"
    var url = baseURL.appending(path: path)
    if let facility {
      url = url.appending(queryItems: [URLQueryItem(name: "facility", value: facility)])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Config.requestTimeout
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = jpeg
    return try JSONCoding.decoder.decode(VisionResult.self, from: try await send(request, path: path))
  }

  func submitReport(_ report: ShiftReport) async throws {
    var request = makeRequest("report")
    request.httpMethod = "POST"
    // Reports carry photos, so allow longer than the default timeout.
    request.timeoutInterval = Config.requestTimeout * 6
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONCoding.encoder.encode(report)
    _ = try await send(request, path: "report")
  }

  private func makeRequest(_ path: String) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.timeoutInterval = Config.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  /// Sends the request and records the outcome in `BackendStatus`.
  private func send(_ request: URLRequest, path: String) async throws -> Data {
    var request = request
    // Stops ngrok's browser-warning HTML page from replacing the JSON response.
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        // Cloudflare's tunnel errors carry their code in the body, e.g. "error code: 1033".
        let body = String(decoding: data.prefix(2048), as: UTF8.self)
        if body.contains("1033") {
          throw NightShiftAPIError.cloudflare(1033)
        }
        throw NightShiftAPIError.badStatus(http.statusCode, path: path)
      }
      await BackendStatus.shared.record(nil)
      return data
    } catch {
      await BackendStatus.shared.record(error)
      throw error
    }
  }
}

// MARK: - Mock

/// Offline demo: serves the bundled `mock_*.json` files and flags about one frame in
/// eight. Fails like a real request when the phone is offline.
struct MockAPI: NightShiftAPI {
  func fetchAlerts() async throws -> [ShiftAlert] {
    try await load(LossyArray<ShiftAlert>.self, "mock_alerts").elements
  }

  func fetchFacility(id: String) async throws -> FacilityStatus {
    let all = try await load(LossyArray<FacilityStatus>.self, "mock_facilities").elements
    guard let facility = all.first(where: { $0.id == id }) else {
      throw NightShiftAPIError.unknownFacility(id)
    }
    return facility
  }

  func fetchHandoff() async throws -> Handoff {
    try await load(Handoff.self, "mock_handoff")
  }

  func checkVision(jpeg: Data, facility: String?) async throws -> VisionResult {
    try await simulateNetwork()
    guard Double.random(in: 0..<1) < 0.125 else {
      return VisionResult(flag: false, type: nil)
    }
    let types = ["leak", "smoke", "damage"]
    return VisionResult(flag: true, type: types[Int.random(in: 0..<types.count)])
  }

  func submitReport(_ report: ShiftReport) async throws {
    try await simulateNetwork()
    NSLog("[NightShift] MockAPI received report \(report.shiftId): \(report.flags.count) flags, \(report.notes.count) notes")
  }

  private func simulateNetwork() async throws {
    try await Task.sleep(for: .milliseconds(300))
    guard await NetworkMonitor.shared.isConnected else {
      throw URLError(.notConnectedToInternet)
    }
  }

  private func load<T: Decodable>(_ type: T.Type, _ name: String) async throws -> T {
    try await simulateNetwork()
    guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
      throw NightShiftAPIError.missingMockResource("\(name).json")
    }
    return try JSONCoding.decoder.decode(T.self, from: Data(contentsOf: url))
  }
}
