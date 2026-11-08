//
// VoiceCommand.swift
//
// Keyword matching for spoken commands. No language model: the earliest trigger
// word in the utterance decides the command.
//

import Foundation

enum VoiceCommand: Equatable, Sendable {
  case next
  case status(facility: String)
  case confirm
  case dismiss
  case note(text: String)
  case flag(type: String)

  /// Types an operator can raise by voice: "flag leak", "flag smoke", "flag damage".
  static let flagTypes = ["leak", "smoke", "damage"]

  private enum Trigger {
    case next, status, confirm, dismiss, note, flag
  }

  private static let triggers: [String: Trigger] = [
    "next": .next,
    "status": .status,
    "confirm": .confirm, "confirmed": .confirm,
    "dismiss": .dismiss, "dismissed": .dismiss,
    "note": .note,
    "flag": .flag, "flags": .flag, "flagged": .flag,
  ]

  /// Filler words skipped between "flag" and the type ("flag a leak").
  private static let flagFillers: Set<String> = ["a", "an", "the", "some", "of", "for", "possible"]

  /// Common mishearings of "leak" by speech recognition.
  private static let leakSoundalikes: Set<String> = ["lead", "leek", "leeks", "lee", "leake", "lake"]

  /// The flag type a single (normalized) word stands for, if any. Accepts word forms
  /// such as "leaking", "smoky", "damaged" and soundalikes such as "leek".
  static func flagType(for word: String) -> String? {
    if word.hasPrefix("leak") || leakSoundalikes.contains(word) { return "leak" }
    if word.hasPrefix("smok") { return "smoke" }
    if word.hasPrefix("damag") { return "damage" }
    return nil
  }

  /// Filler words skipped between "status" and the facility name.
  private static let statusFillers: Set<String> = ["of", "for", "at", "on", "the"]

  /// Parses an utterance such as "what's next", "status of pad 7", "confirm",
  /// "dismiss", or "note valve V-14 is weeping". Returns nil if no trigger word is heard.
  static func parse(_ transcript: String) -> VoiceCommand? {
    let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
    let normalized = words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }

    guard let index = normalized.firstIndex(where: { triggers[$0] != nil }),
      let trigger = triggers[normalized[index]]
    else { return nil }

    // "confirm or dismiss" (e.g. the app's own prompt picked up by the mic) is ambiguous.
    let decisions = Set(normalized.compactMap { triggers[$0] }.filter { $0 == .confirm || $0 == .dismiss })
    if decisions.count > 1 { return nil }

    let rest = words[(index + 1)...]
    switch trigger {
    case .next:
      return .next
    case .confirm:
      return .confirm
    case .dismiss:
      return .dismiss
    case .status:
      let name = rest.drop { statusFillers.contains($0.lowercased()) }.joined(separator: " ")
      return .status(facility: name)
    case .note:
      let text = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : .note(text: text)
    case .flag:
      // The first type word after "flag" (skipping fillers) picks the type: "flag leak",
      // "flag a leak". Otherwise the word just before it: "leak flag".
      let after = normalized[(index + 1)...].drop { flagFillers.contains($0) }
      if let word = after.first, let type = flagType(for: word) {
        return .flag(type: type)
      }
      if index > 0, let type = flagType(for: normalized[index - 1]) {
        return .flag(type: type)
      }
      return nil
    }
  }

  var summary: String {
    switch self {
    case .next: return "next"
    case .status(let facility): return "status of \(facility)"
    case .confirm: return "confirm"
    case .dismiss: return "dismiss"
    case .note(let text): return "note: \(text)"
    case .flag(let type): return "flag \(type)"
    }
  }
}
