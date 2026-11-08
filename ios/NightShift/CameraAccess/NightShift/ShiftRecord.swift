//
// ShiftRecord.swift
//
// What a shift collects on the phone: flags (with photos), voice notes, and
// confirm/dismiss decisions. Also the POST /report payload built from it.
//

import Foundation

/// Camera flags start `.pending`; voice flags are saved `.confirmed` (the operator's
/// own call). Only confirm/dismiss (voice or on-screen) changes a pending flag.
enum FlagStatus: String, Codable, Sendable {
  case pending
  case confirmed
  case dismissed

  /// "waiting" (older saved data) and unknown values decode as `.pending`.
  init(from decoder: Decoder) throws {
    let raw = try? decoder.singleValueContainer().decode(String.self)
    self = raw.flatMap(FlagStatus.init(rawValue:)) ?? .pending
  }
}

struct VoiceNote: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let text: String
  let createdAt: Date

  init(text: String, createdAt: Date = Date()) {
    self.id = UUID()
    self.text = text
    self.createdAt = createdAt
  }
}

struct Flag: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  let createdAt: Date
  /// Facility id the operator was at when the flag was raised, if known.
  let facility: String?
  /// "camera" (vision check) or "voice" ("flag leak" etc.).
  let source: String
  let type: String
  /// What the vision check saw; nil for voice flags and flags saved before this field.
  var description: String? = nil
  /// Set by the on-screen Prioritize button (local only; there is no backend endpoint
  /// for phone flags). nil for older saved flags.
  var priority: Bool? = nil
  var status: FlagStatus
  var decidedAt: Date?
  /// File name of the saved frame inside the shift's photo folder.
  var photoFilename: String?
  var notes: [VoiceNote]
}

struct ShiftRecord: Codable, Identifiable, Sendable {
  let id: UUID
  let startedAt: Date
  var endedAt: Date?
  var flags: [Flag]
  /// Notes not attached to a flag.
  var notes: [VoiceNote]

  init(startedAt: Date = Date()) {
    self.id = UUID()
    self.startedAt = startedAt
    self.endedAt = nil
    self.flags = []
    self.notes = []
  }
}

/// POST /report body: one JSON document, photos inline as base64 JPEG.
struct ShiftReport: Codable, Sendable {
  struct ReportFlag: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    /// When the flag was raised (ISO 8601). Same as `createdAt`; the backend reads
    /// `timestamp`. Optional only so reports queued by older builds still decode.
    let timestamp: Date?
    let facility: String?
    /// "camera" or "voice", as stored in `Flag.source`.
    let trigger: String
    let type: String
    /// Omitted from the JSON when nil.
    let description: String?
    /// true if the operator prioritized it on screen; omitted when nil.
    let priority: Bool?
    let status: FlagStatus
    let decidedAt: Date?
    let notes: [VoiceNote]
    let photoJpegBase64: String?
  }

  let shiftId: UUID
  /// Shift date, "yyyy-MM-dd" in the phone's time zone, from `startedAt`. Optional only
  /// so reports queued by older builds still decode.
  let date: String?
  let startedAt: Date
  let endedAt: Date?
  let flags: [ReportFlag]
  let notes: [VoiceNote]
  let generatedAt: Date
}
