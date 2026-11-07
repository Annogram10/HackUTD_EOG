//
// NightShiftAPI.swift
//
// The single boundary to the NightShift backend. `RealAPI` talks HTTP; `MockAPI` is a
// small offline demo fallback. Pick one with `Config.useMock`.
//

import Foundation

protocol NightShiftAPI: Sendable {
  func fetchAlerts() async throws -> [ShiftAlert]
  func fetchFacility(id: String) async throws -> FacilityStatus
  func fetchHandoff() async throws -> Handoff
  /// Sends one JPEG frame for the given facility; the backend says whether it shows a problem.
  func checkVision(jpeg: Data, facility: String?) async throws -> VisionResult
  func submitReport(_ report: ShiftReport) async throws
}

enum NightShiftAPIError: LocalizedError {
  case badStatus(Int)
  case missingMockResource(String)
  case unknownFacility(String)

  var errorDescription: String? {
    switch self {
    case .badStatus(let code): return "Server returned status \(code)."
    case .missingMockResource(let name): return "Mock resource \(name) is missing from the app bundle."
    case .unknownFacility(let id): return "No facility with id \(id)."
    }
  }
}

// MARK: - Real

struct RealAPI: NightShiftAPI {
  let baseURL: URL

  func fetchAlerts() async throws -> [ShiftAlert] {
    let request = makeRequest("alerts")
    return try JSONCoding.decoder.decode(LossyArray<ShiftAlert>.self, from: try await send(request)).elements
  }

  func fetchFacility(id: String) async throws -> FacilityStatus {
    try JSONCoding.decoder.decode(FacilityStatus.self, from: try await send(makeRequest("facility/\(id)")))
  }

  func fetchHandoff() async throws -> Handoff {
    try JSONCoding.decoder.decode(Handoff.self, from: try await send(makeRequest("handoff")))
  }

  /// Raw JPEG body (Content-Type: image/jpeg), facility as `?facility=<id>`.
  func checkVision(jpeg: Data, facility: String?) async throws -> VisionResult {
    var url = baseURL.appending(path: "vision/check")
    if let facility {
      url = url.appending(queryItems: [URLQueryItem(name: "facility", value: facility)])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Config.requestTimeout
    request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = jpeg
    return try JSONCoding.decoder.decode(VisionResult.self, from: try await send(request))
  }

  func submitReport(_ report: ShiftReport) async throws {
    var request = makeRequest("report")
    request.httpMethod = "POST"
    // Reports carry photos, so allow longer than the default timeout.
    request.timeoutInterval = Config.requestTimeout * 6
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONCoding.encoder.encode(report)
    _ = try await send(request)
  }

  private func makeRequest(_ path: String) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.timeoutInterval = Config.requestTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw NightShiftAPIError.badStatus(http.statusCode)
    }
    return data
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
