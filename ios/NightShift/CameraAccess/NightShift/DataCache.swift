//
// DataCache.swift
//
// Keeps the last successful backend responses on the phone so the app works offline.
// Stored in Application Support (not Caches, which iOS may purge).
//

import Foundation

struct DataCache: Sendable {
  let directory: URL

  init(directory: URL = URL.applicationSupportDirectory.appending(path: "NightShiftCache", directoryHint: .isDirectory)) {
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func save<T: Encodable>(_ value: T, as name: String) {
    do {
      let data = try JSONCoding.encoder.encode(value)
      try data.write(to: url(for: name), options: .atomic)
    } catch {
      NSLog("[NightShift] Cache write failed for \(name): \(error)")
    }
  }

  func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
    guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
    return try? JSONCoding.decoder.decode(T.self, from: data)
  }

  private func url(for name: String) -> URL {
    directory.appending(path: "\(name).json")
  }
}
