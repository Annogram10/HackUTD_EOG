//
// VoiceCommand.swift
//
// Keyword matching for the whitelisted spoken commands only. No language model.
// Anything else is "not understood" and has no network side effects.
//
//   "what's the issue" (and close variants)  GET /issue, speak it
//   "confirm"                                 confirm the newest pending camera flag
//   "dismiss" / "prioritize"                 decide the issue's flag (or the camera flag)
//   "acknowledge" / "stop"                    acknowledge the alarm, stop speech
//   "repeat"                                  say the last message again
//   "status" [of <facility>]                  read a facility's status
//   "next alert"                              read the next alert
//   "flag" [leak|smoke|damage] [at <facility>] photo from the glasses, saved as a flag
//   "note" [<text>]                           note on the flag just made (or the shift);
//                                             "note" alone takes the next sentence
//
// "flag" and "note" only count as the first word (after "add a" / "take a" etc.), and
// everything after them is kept as said, so "note the pump stopped" is a note, not "stop".
//

import Foundation

enum VoiceCommand: Equatable, Sendable {
  /// "what's the issue": ask the backend what's wrong (GET /issue).
  case issue
  /// Confirms the newest pending camera flag.
  case confirm
  case dismiss
  /// "prioritize" / "priority" / "escalate": mark the issue's flag as a priority.
  case prioritize
  case acknowledge
  case stop
  case repeatLast
  /// "status" alone (empty) or "status of <name>".
  case status(facility: String)
  case next
  /// "flag leak at Pad 7": type is "leak", "smoke", "damage", or nil when not said.
  case flag(type: String?, facility: String)
  /// "note <text>"; empty text means "take the next sentence as the note".
  case note(text: String)

  private enum Trigger {
    case confirm, dismiss, prioritize, acknowledge, stop, repeatLast, status, next
  }

  /// Phrases (normalized: lowercase letters, digits and single spaces) that ask what's
  /// wrong. Matched anywhere in the utterance, before single trigger words.
  private static let issuePhrases = [
    "whats the issue", "what is the issue", "whats the problem", "what is the problem",
    "whats wrong", "what is wrong", "whats going on", "what is going on",
  ]

  private static let triggers: [String: Trigger] = [
    "confirm": .confirm, "confirmed": .confirm,
    "dismiss": .dismiss, "dismissed": .dismiss,
    "prioritize": .prioritize, "prioritise": .prioritize, "prioritized": .prioritize,
    "prioritised": .prioritize, "priority": .prioritize, "escalate": .prioritize,
    "acknowledge": .acknowledge, "acknowledged": .acknowledge,
    "stop": .stop,
    "repeat": .repeatLast,
    "status": .status,
    "next": .next,
  ]

  /// Spoken words for each flag type the backend knows.
  private static let flagTypes: [String: String] = [
    "leak": "leak", "leaks": "leak", "leaking": "leak", "spill": "leak", "drip": "leak", "dripping": "leak",
    "smoke": "smoke", "smoking": "smoke", "fire": "smoke", "vapor": "smoke", "vapour": "smoke", "steam": "smoke",
    "damage": "damage", "damaged": "damage", "broken": "damage", "crack": "damage", "cracked": "damage", "dent": "damage",
  ]

  /// What the on-device recognizer often hears instead of a command word (narrowband
  /// glasses mic). Only applied to the first word, where a command word is expected.
  private static let commandSoundsLike: [String: String] = [
    "black": "flag", "flack": "flag", "flak": "flag", "flagg": "flag", "flags": "flag", "blag": "flag",
    "plaque": "flag", "flog": "flag", "slag": "flag", "frag": "flag", "lag": "flag", "flagged": "flag",
    "nodes": "note", "noted": "note", "knot": "note", "nope": "note", "vote": "note", "boat": "note", "nolte": "note",
    "conform": "confirm", "affirm": "confirm", "conferm": "confirm",
    "dismissal": "dismiss", "dismissive": "dismiss",
    "stasis": "status", "statue": "status", "statues": "status", "stats": "status",
    "nest": "next", "necks": "next",
    "knowledge": "acknowledge",
    "prioritizes": "prioritize", "priorities": "prioritize", "prioritizing": "prioritize",
  ]
  /// Mishearings of the flag type, only right after the flag word.
  private static let typeSoundsLike: [String: String] = [
    "lake": "leak", "leek": "leak", "lick": "leak", "league": "leak", "leaked": "leak",
    "smoked": "smoke", "spoke": "smoke", "smog": "smoke",
    "image": "damage", "damages": "damage", "dammit": "damage",
  ]

  /// Phrases the recognizer is biased toward (SFSpeechRecognitionRequest.contextualStrings).
  static let vocabulary = [
    "flag", "flag leak", "flag smoke", "flag damage", "flag a possible leak", "note", "add a note", "take a note",
    "confirm", "dismiss", "prioritize", "acknowledge", "stop", "repeat", "status", "status of", "next alert",
    "what's the issue", "what's wrong", "cancel",
  ]

  /// Words allowed before "flag" / "note" ("add a note", "take a note", "new flag").
  private static let leadIns: Set<String> = ["add", "a", "take", "new", "make", "raise", "please", "okay", "ok", "hey"]
  private static let noteWords: Set<String> = ["note", "notes", "memo"]
  private static let flagWords: Set<String> = ["flag", "flagged", "report"]
  /// Filler words skipped around the flag type and facility.
  private static let flagFillers: Set<String> = [
    "a", "an", "the", "possible", "of", "for", "there", "is", "theres", "some", "black", "white", "grey", "gray",
    "heavy", "small", "big", "bad",
  ]

  /// Filler words skipped between "status" and the facility name.
  private static let statusFillers: Set<String> = ["of", "for", "at", "on", "the"]

  /// Parses an utterance. Returns nil (not understood) for anything off the whitelist.
  static func parse(_ transcript: String) -> VoiceCommand? {
    let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
    var normalized = words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
    // A misheard command word in command position ("black leak" -> "flag leak").
    if let start = normalized.firstIndex(where: { !$0.isEmpty && !leadIns.contains($0) }),
      let fixed = commandSoundsLike[normalized[start]]
    {
      normalized[start] = fixed
    }

    // "flag ..." / "note ...": the first real word decides, and the rest is kept as said.
    if let start = normalized.firstIndex(where: { !$0.isEmpty && !leadIns.contains($0) }) {
      if noteWords.contains(normalized[start]) {
        let text = words[(start + 1)...].joined(separator: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return .note(text: text.drop { $0 == ":" }.trimmingCharacters(in: .whitespaces))
      }
      if flagWords.contains(normalized[start]) {
        return parseFlag(words: Array(words[(start + 1)...]), normalized: Array(normalized[(start + 1)...]))
      }
    }

    let phrase = " " + normalized.filter { !$0.isEmpty }.joined(separator: " ") + " "
    if issuePhrases.contains(where: { phrase.contains(" \($0) ") }) {
      return .issue
    }

    guard let index = normalized.firstIndex(where: { triggers[$0] != nil }),
      let trigger = triggers[normalized[index]]
    else { return nil }

    // "confirm or dismiss" / "dismiss, or prioritize" (e.g. the app's own prompt picked
    // up by the mic) is ambiguous.
    let decisions = Set(normalized.compactMap { triggers[$0] }.filter { [.confirm, .dismiss, .prioritize].contains($0) })
    if decisions.count > 1 { return nil }

    switch trigger {
    case .confirm: return .confirm
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

  /// "[a] [possible] leak [at|on <facility>]" after the flag word.
  private static func parseFlag(words: [String], normalized: [String]) -> VoiceCommand {
    var index = 0
    while index < normalized.count, normalized[index].isEmpty || flagFillers.contains(normalized[index]) { index += 1 }
    var type: String?
    if index < normalized.count, let spoken = flagTypes[normalized[index]] ?? typeSoundsLike[normalized[index]] {
      type = spoken
      index += 1
    }
    // The facility follows "at" / "on" / "near" / "by" (or comes straight after the type).
    while index < normalized.count, ["at", "on", "near", "by", "in", "the"].contains(normalized[index]) || normalized[index].isEmpty {
      index += 1
    }
    let facility = words[index...].joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    return .flag(type: type, facility: facility)
  }

  var summary: String {
    switch self {
    case .issue: return "what's the issue"
    case .confirm: return "confirm"
    case .dismiss: return "dismiss"
    case .prioritize: return "prioritize"
    case .acknowledge: return "acknowledge"
    case .stop: return "stop"
    case .repeatLast: return "repeat"
    case .status(let facility): return facility.isEmpty ? "status" : "status of \(facility)"
    case .next: return "next alert"
    case .flag(let type, let facility):
      return "flag" + (type.map { " \($0)" } ?? "") + (facility.isEmpty ? "" : " at \(facility)")
    case .note(let text): return text.isEmpty ? "note" : "note: \(text)"
    }
  }
}
