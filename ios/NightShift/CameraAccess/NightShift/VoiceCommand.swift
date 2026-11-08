//
// VoiceCommand.swift
//
// Keyword matching for the whitelisted spoken commands only. No language model.
// Anything else is "not understood" and has no network side effects.
//
//   "what's the issue" (and close variants)  GET /issue, speak it
//   "dismiss" / "prioritize"                 decide the issue's flag
//   "acknowledge" / "stop"                    acknowledge the alarm, stop speech
//   "repeat"                                  say the last message again
//   "status" [of <facility>]                  read a facility's status
//   "next alert"                              read the next alert
//

import Foundation

enum VoiceCommand: Equatable, Sendable {
  /// "what's the issue": ask the backend what's wrong (GET /issue).
  case issue
  case dismiss
  /// "prioritize" / "priority" / "escalate": mark the issue's flag as a priority.
  case prioritize
  case acknowledge
  case stop
  case repeatLast
  /// "status" alone (empty) or "status of <name>".
  case status(facility: String)
  case next

  private enum Trigger {
    case dismiss, prioritize, acknowledge, stop, repeatLast, status, next
  }

  /// Phrases (normalized: lowercase letters, digits and single spaces) that ask what's
  /// wrong. Matched anywhere in the utterance, before single trigger words.
  private static let issuePhrases = [
    "whats the issue", "what is the issue", "whats the problem", "what is the problem",
    "whats wrong", "what is wrong", "whats going on", "what is going on",
  ]

  private static let triggers: [String: Trigger] = [
    "dismiss": .dismiss, "dismissed": .dismiss,
    "prioritize": .prioritize, "prioritise": .prioritize, "prioritized": .prioritize,
    "prioritised": .prioritize, "priority": .prioritize, "escalate": .prioritize,
    "acknowledge": .acknowledge, "acknowledged": .acknowledge,
    "stop": .stop,
    "repeat": .repeatLast,
    "status": .status,
    "next": .next,
  ]

  /// Filler words skipped between "status" and the facility name.
  private static let statusFillers: Set<String> = ["of", "for", "at", "on", "the"]

  /// Parses an utterance. Returns nil (not understood) for anything off the whitelist.
  static func parse(_ transcript: String) -> VoiceCommand? {
    let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
    let normalized = words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }

    let phrase = " " + normalized.filter { !$0.isEmpty }.joined(separator: " ") + " "
    if issuePhrases.contains(where: { phrase.contains(" \($0) ") }) {
      return .issue
    }

    guard let index = normalized.firstIndex(where: { triggers[$0] != nil }),
      let trigger = triggers[normalized[index]]
    else { return nil }

    // "dismiss, or prioritize" (e.g. the app's own prompt picked up by the mic) is ambiguous.
    let decisions = Set(normalized.compactMap { triggers[$0] }.filter { $0 == .dismiss || $0 == .prioritize })
    if decisions.count > 1 { return nil }

    switch trigger {
    case .dismiss: return .dismiss
    case .prioritize: return .prioritize
    case .acknowledge: return .acknowledge
    case .stop: return .stop
    case .repeatLast: return .repeatLast
    case .next: return .next
    case .status:
      let rest = words[(index + 1)...]
      let name = rest.drop { statusFillers.contains($0.lowercased()) }.joined(separator: " ")
      return .status(facility: name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
    }
  }

  var summary: String {
    switch self {
    case .issue: return "what's the issue"
    case .dismiss: return "dismiss"
    case .prioritize: return "prioritize"
    case .acknowledge: return "acknowledge"
    case .stop: return "stop"
    case .repeatLast: return "repeat"
    case .status(let facility): return facility.isEmpty ? "status" : "status of \(facility)"
    case .next: return "next alert"
    }
  }
}
