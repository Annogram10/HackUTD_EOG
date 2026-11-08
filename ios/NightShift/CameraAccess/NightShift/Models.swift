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
/// used; confidence is ignored.
struct VisionResult: Codable, Hashable, Sendable {
  /// The only types that count as a camera flag (exact, lowercase).
  static let flagTypes: Set<String> = ["leak", "smoke", "damage"]

  let flag: Bool
  let type: String?
  /// nil (missing) is treated as available.
  let available: Bool?
  let description: String?

  private enum CodingKeys: String, CodingKey {
    case flag, type, available, description
  }

  init(flag: Bool, type: String?, available: Bool? = true, description: String? = nil) {
    self.flag = flag
    self.type = type
    self.available = available
    self.description = description
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    flag = (try? c.decodeIfPresent(Bool.self, forKey: .flag)) ?? false
    type = c.lenientString(.type)
    available = try? c.decodeIfPresent(Bool.self, forKey: .available)
    description = c.lenientString(.description).flatMap { $0.isEmpty ? nil : $0 }
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
