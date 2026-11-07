//
// ShiftView.swift
//
// The NightShift shift screen, shown as a sheet over the camera screen so the
// preview (and the vision checks that read from it) keep running.
//

import SwiftUI

struct ShiftView: View {
  var controller: NightShiftController
  var network = NetworkMonitor.shared
  @State private var confirmEndShift = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          if controller.isOnShift {
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
      VStack(alignment: .leading, spacing: 4) {
        Text(Config.useMock ? "Mock data (offline demo)" : Config.baseURL.absoluteString)
          .font(.caption.monospaced())
          .textSelection(.enabled)
        if let result = controller.connectionTestResult {
          Text(result)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Button("Test connection", systemImage: "network") {
        Task { await controller.testConnection() }
      }
      .disabled(controller.isTestingConnection)
    }
  }

  private func facilityName(for id: String?) -> String? {
    guard let id else { return nil }
    return controller.facilities.first { $0.id == id }?.displayName ?? id
  }
}
