//
// ShiftStore.swift
//
// Offline storage for the current shift, in Documents/NightShift:
//   current_shift.json          the shift in progress (survives app restarts)
//   shifts/<id>.json            ended shifts
//   photos/<shift id>/<flag id>.jpg
//

import Foundation
import Observation

@Observable
@MainActor
final class ShiftStore {
  private(set) var current: ShiftRecord?

  @ObservationIgnored private let root: URL
  @ObservationIgnored private var currentFileURL: URL { root.appending(path: "current_shift.json") }
  @ObservationIgnored private var shiftsDirectory: URL { root.appending(path: "shifts", directoryHint: .isDirectory) }

  init(root: URL = URL.documentsDirectory.appending(path: "NightShift", directoryHint: .isDirectory)) {
    self.root = root
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: root.appending(path: "current_shift.json")) {
      current = try? JSONCoding.decoder.decode(ShiftRecord.self, from: data)
    }
  }

  // MARK: - Shift lifecycle

  /// Starts a new shift unless one is already in progress.
  @discardableResult
  func startShift() -> ShiftRecord {
    if let current { return current }
    let shift = ShiftRecord()
    current = shift
    save()
    return shift
  }

  /// Marks the shift ended, archives it to shifts/<id>.json, and clears `current`.
  func endShift() -> ShiftRecord? {
    guard var shift = current else { return nil }
    shift.endedAt = Date()
    do {
      try FileManager.default.createDirectory(at: shiftsDirectory, withIntermediateDirectories: true)
      try JSONCoding.encoder.encode(shift).write(to: shiftsDirectory.appending(path: "\(shift.id).json"), options: .atomic)
      try? FileManager.default.removeItem(at: currentFileURL)
    } catch {
      NSLog("[NightShift] Couldn't archive shift: \(error)")
    }
    current = nil
    return shift
  }

  // MARK: - Flags

  /// The newest pending flag. Voice confirm/dismiss act on this one only.
  var currentFlag: Flag? {
    current?.flags.last { $0.status == .pending }
  }

  /// Saves a flag and, if given, its evidence photo (JPEG, already scaled). Returns nil
  /// (saving nothing) if no shift is open: only Start Shift opens one.
  @discardableResult
  func addFlag(
    type: String,
    source: String,
    status: FlagStatus,
    photo: Data?,
    facility: String?,
    description: String? = nil
  ) -> Flag? {
    guard let shift = current else { return nil }
    let id = UUID()
    var flag = Flag(
      id: id,
      createdAt: Date(),
      facility: facility,
      source: source,
      type: type,
      description: description,
      status: status,
      decidedAt: status == .pending ? nil : Date(),
      photoFilename: nil,
      notes: []
    )
    if let jpeg = photo {
      let filename = "\(id).jpg"
      let directory = photosDirectory(for: shift.id)
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: directory.appending(path: filename), options: .atomic)
        flag.photoFilename = filename
      } catch {
        NSLog("[NightShift] Couldn't save flag photo: \(error)")
      }
    }
    current?.flags.append(flag)
    save()
    return flag
  }

  /// Marks a flag as a priority (on-screen Prioritize); also confirms it.
  func setPriority(for flagID: Flag.ID) {
    guard let index = current?.flags.firstIndex(where: { $0.id == flagID }) else { return }
    current?.flags[index].priority = true
    current?.flags[index].status = .confirmed
    current?.flags[index].decidedAt = Date()
    save()
  }

  func setStatus(_ status: FlagStatus, for flagID: Flag.ID) {
    guard let index = current?.flags.firstIndex(where: { $0.id == flagID }) else { return }
    current?.flags[index].status = status
    current?.flags[index].decidedAt = Date()
    save()
  }

  // MARK: - Notes

  /// Attaches the note to `flagID` if given, otherwise to the shift. Returns false
  /// (saving nothing) if no shift is open.
  @discardableResult
  func addNote(_ text: String, to flagID: Flag.ID?) -> Bool {
    guard current != nil else { return false }
    let note = VoiceNote(text: text)
    if let flagID, let index = current?.flags.firstIndex(where: { $0.id == flagID }) {
      current?.flags[index].notes.append(note)
    } else {
      current?.notes.append(note)
    }
    save()
    return true
  }

  // MARK: - Photos

  func photoURL(for flag: Flag, in shift: ShiftRecord) -> URL? {
    flag.photoFilename.map { photosDirectory(for: shift.id).appending(path: $0) }
  }

  private func photosDirectory(for shiftID: UUID) -> URL {
    root.appending(path: "photos/\(shiftID)", directoryHint: .isDirectory)
  }

  // MARK: - Report

  /// Builds the POST /report body, reading each flag's photo from disk.
  func makeReport(for shift: ShiftRecord) -> ShiftReport {
    let flags = shift.flags.map { flag in
      let photo = photoURL(for: flag, in: shift).flatMap { try? Data(contentsOf: $0) }
      return ShiftReport.ReportFlag(
        id: flag.id,
        createdAt: flag.createdAt,
        timestamp: flag.createdAt,
        facility: flag.facility,
        trigger: flag.source,
        type: flag.type,
        description: flag.description,
        priority: flag.priority,
        status: flag.status,
        decidedAt: flag.decidedAt,
        notes: flag.notes,
        photoJpegBase64: photo?.base64EncodedString()
      )
    }
    return ShiftReport(
      shiftId: shift.id,
      clientId: UUID(),
      date: Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(shift.startedAt),
      startedAt: shift.startedAt,
      endedAt: shift.endedAt,
      flags: flags,
      notes: shift.notes,
      generatedAt: Date()
    )
  }

  // MARK: - Persistence

  private func save() {
    guard let current else { return }
    do {
      try JSONCoding.encoder.encode(current).write(to: currentFileURL, options: .atomic)
    } catch {
      NSLog("[NightShift] Couldn't save shift: \(error)")
    }
  }
}
