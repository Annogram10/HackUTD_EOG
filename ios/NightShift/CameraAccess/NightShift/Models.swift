//
// Models.swift
//
// Backend response types. Decoding is tolerant: unknown fields are ignored, missing
// or mistyped optional fields become nil, ids may be strings or numbers. The app
// never computes anything from these; it displays and speaks them as received.
//

import Foundation

enum JSONCoding {
  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
}

/// GET /alerts element. `severity` is display-only (number or word).
struct ShiftAlert: Codable, Identifiable, Hashable, Sendable {
  let id: String
  /// Facility id, e.g. "S5_FACILITY_C".
  let facility: String?
  /// Facility name for display, e.g. "S5 Facility C".
  let facilityName: String?
  let system: String?
  let type: String?
  let severity: String?
  let spokenText: String?

  private enum CodingKeys: String, CodingKey {
    case id, facility, facilityName, system, type, severity, spokenText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenientString(.id) ?? UUID().uuidString
    facility = c.lenientString(.facility).flatMap { $0.isEmpty ? nil : $0 }
    facilityName = c.lenientString(.facilityName)
    system = c.lenientString(.system)
    type = c.lenientString(.type)
    severity = c.lenientString(.severity)
    spokenText = c.lenientString(.spokenText)
  }
}

/// GET /facility/{id}
struct FacilityStatus: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String?
  let status: String?
  let spokenText: String?

  var displayName: String { name ?? id }

  private enum CodingKeys: String, CodingKey {
    case id, name, status, spokenText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenientString(.id) ?? ""
    name = c.lenientString(.name)
    status = c.lenientString(.status)
    spokenText = c.lenientString(.spokenText)
  }
}

/// GET /handoff
struct Handoff: Codable, Hashable, Sendable {
  let text: String?
  let spokenText: String?

  private enum CodingKeys: String, CodingKey {
    case text, spokenText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    text = c.lenientString(.text)
    spokenText = c.lenientString(.spokenText)
  }
}

/// POST /vision/check response. Only `flag`, `type`, `available` and `description` are
/// used; `confidence` and `httpStatus` are kept for display (Check now) only.
struct VisionResult: Codable, Hashable, Sendable {
  /// The only types that count as a camera flag (exact, lowercase).
  static let flagTypes: Set<String> = ["leak", "smoke", "damage"]

  let flag: Bool
  let type: String?
  /// nil (missing) is treated as available.
  let available: Bool?
  let description: String?
  /// Display only; never used to decide anything.
  let confidence: Double?
  /// HTTP status of the response (set by RealAPI, not decoded).
  var httpStatus: Int?

  private enum CodingKeys: String, CodingKey {
    case flag, type, available, description, confidence
  }

  init(flag: Bool, type: String?, available: Bool? = true, description: String? = nil, confidence: Double? = nil) {
    self.flag = flag
    self.type = type
    self.available = available
    self.description = description
    self.confidence = confidence
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    flag = (try? c.decodeIfPresent(Bool.self, forKey: .flag)) ?? false
    type = c.lenientString(.type)
    available = try? c.decodeIfPresent(Bool.self, forKey: .available)
    description = c.lenientString(.description).flatMap { $0.isEmpty ? nil : $0 }
    confidence = c.lenientString(.confidence).flatMap(Double.init)
  }

  /// The flag type if this is a real flag: flag == true, available, and type is
  /// exactly "leak", "smoke" or "damage". Otherwise nil (skip silently).
  var flaggedType: String? {
    guard flag, available != false, let type, Self.flagTypes.contains(type) else { return nil }
    return type
  }
}

/// Decodes an array, skipping elements that fail instead of failing the whole response.
struct LossyArray<Element: Decodable>: Decodable {
  let elements: [Element]

  /// Accepts any JSON value, so decoding it always advances the container.
  private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
  }

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var elements: [Element] = []
    while !container.isAtEnd {
      if let element = try? container.decode(Element.self) {
        elements.append(element)
      } else {
        // Advance past the bad element.
        _ = try? container.decode(Skip.self)
      }
    }
    self.elements = elements
  }
}

extension KeyedDecodingContainer {
  /// A string, or a number as a string. nil if missing, null, or another type.
  func lenientString(_ key: Key) -> String? {
    if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
    return nil
  }
}

// MARK: - GET /map

/// GET /map: every facility with its pin position, already ranked by importance
/// (rank 1 = check first). Shown in the order received; never re-sorted.
struct FacilityMap: Codable, Hashable, Sendable {
  let dataset: String?
  let asOf: String?
  let systems: [MapSystem]
  let facilities: [MapFacility]

  private enum CodingKeys: String, CodingKey {
    case dataset, asOf, systems, facilities
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    dataset = c.lenientString(.dataset)
    asOf = c.lenientString(.asOf)
    systems = (try? c.decodeIfPresent(LossyArray<MapSystem>.self, forKey: .systems))?.elements ?? []
    facilities = (try? c.decodeIfPresent(LossyArray<MapFacility>.self, forKey: .facilities))?.elements ?? []
  }
}

struct MapSystem: Codable, Hashable, Sendable, Identifiable {
  struct DisposalSite: Codable, Hashable, Sendable {
    let id: String?
    let lat: Double?
    let lon: Double?
    let pressurePsi: Double?

    private enum CodingKeys: String, CodingKey {
      case id, lat, lon, pressurePsi
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = c.lenientString(.id)
      lat = c.lenientDouble(.lat)
      lon = c.lenientDouble(.lon)
      pressurePsi = c.lenientDouble(.pressurePsi)
    }
  }

  let id: String
  /// [lat, lon]
  let center: [Double]?
  /// [lat, lon]
  let truckYard: [Double]?
  let disposalSite: DisposalSite?

  private enum CodingKeys: String, CodingKey {
    case id, center, truckYard, disposalSite
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = c.lenientString(.id) ?? UUID().uuidString
    center = try? c.decodeIfPresent([Double].self, forKey: .center)
    truckYard = try? c.decodeIfPresent([Double].self, forKey: .truckYard)
    disposalSite = try? c.decodeIfPresent(DisposalSite.self, forKey: .disposalSite)
  }
}

struct MapFacility: Codable, Hashable, Sendable, Identifiable {
  let id: String
  let rank: Int?
  let name: String?
  let system: String?
  let lat: Double?
  let lon: Double?
  /// Higher is more urgent; 0 means nothing wrong. Display only.
  let importance: Double?
  /// "high", "medium", "low" or "none": used for the pin color.
  let level: String?
  /// Live sensor state: "failure", "tripped", "leak", "worn" or "ok".
  let status: String?
  /// Only for pump failures still running; otherwise nil.
  let hoursToShutdown: Double?
  /// Plain sentences for the detail card; empty when nothing is wrong.
  let reasons: [String]
  /// Ready to read on the glasses; nil when there's no problem.
  let spokenText: String?

  var displayName: String { name ?? id }

  private enum CodingKeys: String, CodingKey {
    case id, rank, name, system, lat, lon, importance, level, status, hoursToShutdown, reasons, spokenText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // No id means it can't be pinned or picked; LossyArray skips it.
    guard let id = c.lenientString(.id), !id.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Facility without id")
    }
    self.id = id
    rank = c.lenientDouble(.rank).map { Int($0) }
    name = c.lenientString(.name)
    system = c.lenientString(.system)
    lat = c.lenientDouble(.lat)
    lon = c.lenientDouble(.lon)
    importance = c.lenientDouble(.importance)
    level = c.lenientString(.level)
    status = c.lenientString(.status)
    hoursToShutdown = c.lenientDouble(.hoursToShutdown)
    reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
    spokenText = c.lenientString(.spokenText).flatMap { $0.isEmpty ? nil : $0 }
  }
}

extension KeyedDecodingContainer {
  /// A number, or a numeric string. nil if missing, null, or not a number.
  func lenientDouble(_ key: Key) -> Double? {
    if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
    if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
    return nil
  }
}

// MARK: - GET /alarm

/// GET /alarm: whether something needs a person's attention right now. Each distinct
/// situation has its own `alarmId`, so an acknowledged one never flashes again.
struct AlarmStatus: Codable, Hashable, Sendable {
  let alarm: Bool
  let alarmId: String?
  let level: String?
  let headline: String?
  /// Written for speech (numbers spelled out); spoken as received.
  let spokenText: String?
  let reasons: [String]
  let facilityIds: [String]

  private enum CodingKeys: String, CodingKey {
    case alarm, alarmId, level, headline, spokenText, reasons, facilityIds
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    alarm = (try? c.decodeIfPresent(Bool.self, forKey: .alarm)) ?? false
    alarmId = c.lenientString(.alarmId).flatMap { $0.isEmpty ? nil : $0 }
    level = c.lenientString(.level)
    headline = c.lenientString(.headline)
    spokenText = c.lenientString(.spokenText).flatMap { $0.isEmpty ? nil : $0 }
    reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
    facilityIds = (try? c.decodeIfPresent([String].self, forKey: .facilityIds)) ?? []
  }
}

// MARK: - GET /issue, POST /flag/{id}/dismiss|prioritize

/// A backend flag the operator can act on (dismiss or prioritize).
struct BackendFlag: Codable, Hashable, Sendable {
  let id: String
  let type: String?
  let status: String?
  /// The backend sends a number (0/1) or a bool.
  let priority: Bool
  let reason: String?
  let equipmentId: String?
  let timestamp: String?

  private enum CodingKeys: String, CodingKey {
    case id, type, status, priority, reason, equipmentId, timestamp
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard let id = c.lenientString(.id), !id.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Flag without id")
    }
    self.id = id
    type = c.lenientString(.type)
    status = c.lenientString(.status)
    if let value = try? c.decodeIfPresent(Bool.self, forKey: .priority) {
      priority = value
    } else {
      priority = (c.lenientDouble(.priority) ?? 0) > 0
    }
    reason = c.lenientString(.reason)
    equipmentId = c.lenientString(.equipmentId)
    timestamp = c.lenientString(.timestamp)
  }
}

/// GET /issue: what's wrong at a facility, written for speech, plus the flag to act on.
struct IssueReport: Codable, Hashable, Sendable {
  let facilityId: String?
  let name: String?
  /// false when the facility has nothing wrong (spoken_text then says so).
  let problem: Bool
  let level: String?
  /// Spoken as received; ends with "Say dismiss, or prioritize." when there is a flag.
  let spokenText: String?
  /// nil when there is nothing to act on.
  let flag: BackendFlag?
  let options: [String]

  private enum CodingKeys: String, CodingKey {
    case facilityId, name, problem, level, spokenText, flag, options
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    facilityId = c.lenientString(.facilityId)
    name = c.lenientString(.name)
    problem = (try? c.decodeIfPresent(Bool.self, forKey: .problem)) ?? false
    level = c.lenientString(.level)
    spokenText = c.lenientString(.spokenText).flatMap { $0.isEmpty ? nil : $0 }
    flag = try? c.decodeIfPresent(BackendFlag.self, forKey: .flag)
    options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
  }
}
