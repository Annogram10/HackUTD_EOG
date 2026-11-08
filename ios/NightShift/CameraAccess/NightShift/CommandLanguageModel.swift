//
// CommandLanguageModel.swift
//
// An on-device custom language model for the voice commands (SFCustomLanguageModelData,
// iOS 17+). General dictation hears "flag" as "black" on the glasses' narrowband mic;
// training the recognizer on the command phrases (and this dataset's facility names)
// makes it expect them. Built once in Caches and rebuilt only when the phrases change
// (e.g. new facility names). Anything that fails leaves plain dictation in place.
//

import Foundation
import Speech

enum CommandLanguageModel {
  /// Bump when the phrases below change shape, so the cached model is rebuilt.
  private static let version = "1"
  private static let locale = Locale(identifier: "en-US")

  private static var directory: URL {
    URL.cachesDirectory.appending(path: "NightShiftSpeech", directoryHint: .isDirectory)
  }

  /// Builds (or reuses) the model and returns its configuration for
  /// `SFSpeechRecognitionRequest.customizedLanguageModel`, or nil if it couldn't be built.
  static func prepare(facilityNames: [String]) async -> SFSpeechLanguageModel.Configuration? {
    let directory = directory
    let asset = directory.appending(path: "commands.bin")
    let configuration = SFSpeechLanguageModel.Configuration(
      languageModel: directory.appending(path: "commands.lm"),
      vocabulary: directory.appending(path: "commands.vocab")
    )
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try await trainingData(facilityNames: facilityNames).export(to: asset)
      // Recompiles only if the exported phrases differ from the cached model's.
      try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: configuration, ignoresCache: false)
      return configuration
    } catch {
      NSLog("[NightShift] Custom speech model unavailable, using plain dictation: \(error)")
      return nil
    }
  }

  private static func trainingData(facilityNames: [String]) -> SFCustomLanguageModelData {
    let data = SFCustomLanguageModelData(locale: locale, identifier: "com.kavin.nightshift.commands", version: version)

    // Whole commands, weighted by how often they're said.
    let phrases: [(String, Int)] = [
      ("flag", 400), ("flag leak", 1000), ("flag smoke", 800), ("flag damage", 800),
      ("flag a leak", 300), ("flag a possible leak", 300), ("flag possible smoke", 200), ("flag possible damage", 200),
      ("note", 600), ("add a note", 300), ("take a note", 300),
      ("confirm", 800), ("dismiss", 800), ("prioritize", 800), ("acknowledge", 600), ("stop", 400),
      ("repeat", 400), ("status", 600), ("next alert", 600), ("next", 300), ("cancel", 300),
      ("what's the issue", 800), ("what is the issue", 300), ("what's wrong", 300),
    ]
    for (phrase, count) in phrases {
      data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: count))
    }

    // Commands with slots.
    let generator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
    generator.define(className: "type", values: ["leak", "smoke", "damage"])
    generator.insert(template: "flag <type> at the pump", count: 100)
    generator.insert(template: "flag <type> at the tank", count: 100)
    generator.insert(template: "note the <type> is getting worse", count: 50)
    let names = Array(Set(facilityNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    if !names.isEmpty {
      generator.define(className: "facility", values: names)
      generator.insert(template: "flag <type> at <facility>", count: 400)
      generator.insert(template: "status of <facility>", count: 400)
      generator.insert(template: "status <facility>", count: 100)
    }
    data.insert(phraseCountGenerator: generator)
    return data
  }
}
