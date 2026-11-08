//
// ShiftView.swift
//
// The NightShift shift screen, shown as a sheet over the camera screen so the
// preview (and the vision checks that read from it) keep running.
//

import SwiftUI
import UIKit

struct ShiftView: View {
  var controller: NightShiftController
  var network = NetworkMonitor.shared
  var backend = BackendStatus.shared
  @State private var confirmEndShift = false
  @State private var addressText = ""
  @State private var addressError: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          if let since = controller.unfinishedShiftStart {
            Label(
              "Shift in progress since \(since.formatted(date: .abbreviated, time: .shortened))",
              systemImage: "clock.badge.exclamationmark"
            )
            .foregroundStyle(.orange)
            Button("Resume", systemImage: "play") {
              Task { await controller.resumeShift() }
            }
            Button("End Shift", systemImage: "moon.zzz", role: .destructive) {
              confirmEndShift = true
            }
          } else if controller.isOnShift {
            Button("End Shift", systemImage: "moon.zzz", role: .destructive) {
              confirmEndShift = true
            }
          } else {
            Button("Start Shift", systemImage: "sunset") {
              Task { await controller.startShift() }
            }
          }
          Button("Next alert", systemImage: "forward") {
            Task { await controller.speakNextAlert() }
          }
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await controller.refresh() }
          }
          .disabled(controller.isRefreshing)
        }

        facilitySection

        voiceSection

        Section("Flags") {
          if let shift = controller.store.current, !shift.flags.isEmpty || !shift.notes.isEmpty {
            ForEach(shift.flags.reversed()) { flag in
              FlagRow(
                flag: flag,
                photoURL: controller.store.photoURL(for: flag, in: shift),
                facilityName: facilityName(for: flag.facility)
              )
            }
            ForEach(shift.notes) { note in
              Label(note.text, systemImage: "quote.bubble")
                .font(.subheadline)
            }
          } else {
            Text("No flags yet.")
              .foregroundStyle(.secondary)
          }
        }

        statusSection
      }
      .navigationTitle("Shift")
      .navigationBarTitleDisplayMode(.inline)
      .confirmationDialog("End shift?", isPresented: $confirmEndShift, titleVisibility: .visible) {
        Button("End Shift and Upload", role: .destructive) {
          Task { await controller.endShift() }
        }
      }
    }
    .task {
      addressText = controller.backendURL.absoluteString
      await controller.testConnection()
    }
    // Keep the field showing the address in use after Save, Paste or Reset.
    .onChange(of: controller.backendURL) { addressText = controller.backendURL.absoluteString }
  }

  private var statusSection: some View {
    Section("Status") {
      Label(
        "\(network.isConnected ? "Online" : "Offline") · \(controller.uploads.pendingCount) pending upload\(controller.uploads.pendingCount == 1 ? "" : "s")",
        systemImage: network.isConnected ? "wifi" : "wifi.slash"
      )
      if case .unavailable(let reason) = controller.voice.status {
        Label(reason, systemImage: "mic.slash")
          .foregroundStyle(.red)
      }
      if backend.isUnreachable && !Config.useMock {
        Label("Backend unreachable. Ask for the new tunnel address and paste it here.", systemImage: "exclamationmark.triangle")
          .font(.subheadline)
          .foregroundStyle(.red)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(Config.useMock ? "Mock data (offline demo)" : backendHostText)
          .font(.caption.monospaced())
          .textSelection(.enabled)
        if controller.isTestingConnection {
          Text("Testing…")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let result = controller.connectionTestResult {
          Text(result.text)
            .font(.caption)
            .foregroundStyle(result.ok ? .green : .red)
        }
      }
      addressEditor
      Button("Test connection", systemImage: "network") {
        Task { await controller.testConnection() }
      }
      .disabled(controller.isTestingConnection)
    }
  }

  private var facilitySection: some View {
    Section("Facility") {
      Picker("I'm at", selection: Binding(
        get: { controller.currentFacilityID },
        set: { controller.setCurrentFacility($0) }
      )) {
        if controller.currentFacilityID == nil {
          Text("Pick a facility").tag(String?.none)
        }
        ForEach(controller.facilityChoices, id: \.id) { choice in
          Text("\(choice.name) (\(choice.id))").tag(Optional(choice.id))
        }
      }
      if controller.currentFacilityID == nil {
        Label(
          controller.facilityChoices.isEmpty
            ? "Pick a facility: no alerts loaded yet, tap Refresh. Camera and voice flags are paused."
            : "Pick a facility. Camera and voice flags are paused until you choose one.",
          systemImage: "mappin.slash"
        )
        .font(.subheadline)
        .foregroundStyle(.red)
      }
      Label(visionStatusText, systemImage: "eye")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var voiceSection: some View {
    Section("Voice") {
      // Reflects the recognizer's real state; works with or without a shift.
      Toggle("Voice commands", isOn: Binding(
        get: { controller.voice.isRunning },
        set: { enabled in Task { await controller.setVoiceEnabled(enabled) } }
      ))
      Label(
        controller.voice.isRunning ? "Listening: on" : "Listening: off",
        systemImage: controller.voice.isRunning ? "mic.fill" : "mic.slash"
      )
      .foregroundStyle(controller.voice.isRunning ? .green : .secondary)
      Text("Heard: \(controller.voice.lastHeard ?? "nothing yet")")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let feedback = controller.voiceFeedback {
        Text(feedback.text)
          .font(.subheadline)
          .foregroundStyle(feedback.ok ? .green : .red)
      }
    }
  }

  private var visionStatusText: String {
    let sent = "\(controller.vision.checksSent) check\(controller.vision.checksSent == 1 ? "" : "s") sent"
    guard let last = controller.vision.lastCheck else { return "Last check: none yet · \(sent)" }
    return "Last check: \(last.outcome.rawValue) at \(last.at.formatted(date: .omitted, time: .standard)) · \(sent)"
  }

  private var backendHostText: String {
    let host = controller.backendURL.host() ?? controller.backendURL.absoluteString
    return controller.isUsingDefaultBackend ? "\(host) (default)" : host
  }

  /// Field and buttons for changing the backend tunnel address without a rebuild.
  private var addressEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("New tunnel address", text: $addressText)
        .font(.callout.monospaced())
        .keyboardType(.URL)
        .textContentType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .onSubmit { saveAddress() }
        .onChange(of: addressText) { addressError = nil }
      if let addressError {
        Text(addressError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      // Borderless styles keep each button separately tappable inside a List row.
      HStack(spacing: 16) {
        Button("Paste") { pasteAddress() }
          .buttonStyle(.borderless)
        Button("Save") { saveAddress() }
          .buttonStyle(.borderless)
          .disabled(addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Spacer()
        Button("Reset to default", role: .destructive) {
          addressText = Config.defaultBaseURL.absoluteString
          addressError = nil
          Task { await controller.resetBackendAddress() }
        }
        .buttonStyle(.borderless)
        .disabled(controller.isUsingDefaultBackend)
      }
      .font(.callout)
    }
  }

  /// Normalizes and saves the typed address, then tests it; shows a red message if invalid.
  private func saveAddress() {
    guard let url = Config.normalizedBaseURL(from: addressText) else {
      addressError = "Not a valid https address."
      return
    }
    save(url)
  }

  /// Reads the clipboard (text first, then a copied link), shows the cleaned address
  /// in the field, then saves and tests it.
  private func pasteAddress() {
    let pasteboard = UIPasteboard.general
    let pasted = pasteboard.string ?? pasteboard.url?.absoluteString
    guard let pasted, let url = Config.normalizedBaseURL(from: pasted) else {
      addressError = "Clipboard has no address"
      return
    }
    save(url)
  }

  /// Shows the normalized address in the field, then saves it and runs Test connection.
  private func save(_ url: URL) {
    addressText = url.absoluteString
    addressError = nil
    Task { _ = await controller.saveBackendAddress(url.absoluteString) }
  }

  private func facilityName(for id: String?) -> String? {
    guard let id else { return nil }
    return controller.facilities.first { $0.id == id }?.displayName ?? id
  }
}
