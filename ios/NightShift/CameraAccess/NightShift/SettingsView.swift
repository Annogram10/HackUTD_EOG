//
// SettingsView.swift
//
// Settings tab: glasses, voice, default map system, backend address and uploads,
// supervisor phone, Pico buzzer. A collapsed Developer section holds the camera
// preview, "I'm at" picker, Check now, Simulate, demo map layers and all flags.
//

import SwiftUI
import UIKit

struct SettingsView: View {
  var controller: NightShiftController
  var wearablesVM: WearablesViewModel
  var cameraVM: CameraViewModel
  let alarmActive: Bool
  @State private var showCamera = false
  @State private var showDeveloper = false
  var network = NetworkMonitor.shared
  var backend = BackendStatus.shared
  @State private var noteFlagID: Flag.ID?
  @State private var noteText = ""
  @State private var addressText = ""
  @State private var addressError: String?
  @AppStorage(Config.Keys.supervisorPhone) private var supervisorPhone = ""
  @AppStorage(Config.Keys.picoAddress) private var picoAddress = ""
  @State private var picoText = ""
  @State private var testingLevel: Int?
  @State private var testResult: PicoStatus.Result?
  @State private var picoError: String?
  @State private var apiKeyText = ""
  @State private var apiKeySaved: String?
  @AppStorage(Config.Keys.defaultSystem) private var defaultSystem = ""
  @AppStorage(Config.Keys.showDemoMapLayers) private var showDemoLayers = true

  var body: some View {
    VStack(spacing: 0) {
      HeaderStrip(alarmActive: alarmActive) {
        Text("Settings")
          .font(.title2.bold())
          .foregroundStyle(NS.textPrimary)
          .frame(minHeight: 40)
          .accessibilityAddTraits(.isHeader)
      }
      List {
        Section {
          Label("Keep this app open. A locked or backgrounded phone can miss alarms.", systemImage: "iphone.gen3")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(NS.amberText)
        }
        .listRowBackground(NS.surface)
        glassesSection.listRowBackground(NS.surface)
        voiceSection.listRowBackground(NS.surface)
        mapSection.listRowBackground(NS.surface)
        statusSection.listRowBackground(NS.surface)
        supervisorSection
        picoSection

        Section {
          Button {
            Haptics.tap()
            showDeveloper.toggle()
          } label: {
            HStack {
              Label("Developer", systemImage: "hammer")
              Spacer()
              Image(systemName: showDeveloper ? "chevron.up" : "chevron.down")
            }
            .contentShape(Rectangle())
          }
          .accessibilityLabel(showDeveloper ? "Hide developer tools" : "Show developer tools")
        }
        .listRowBackground(NS.surface)

        if showDeveloper {
          developerSection
          facilitySection.listRowBackground(NS.surface)
          flagsSection
        }
      }
      .listStyle(.grouped)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, NS.tap)
    }
    .background(NS.background)
    .tint(NS.accent)
    .fullScreenCover(isPresented: $showCamera) {
      CameraView(viewModel: cameraVM, wearablesVM: wearablesVM)
    }
    .alert("Add note", isPresented: Binding(
      get: { noteFlagID != nil },
      set: { if !$0 { noteFlagID = nil } }
    )) {
      TextField("Note", text: $noteText)
      Button("Save") {
        if let noteFlagID {
          controller.addNote(noteText, to: noteFlagID)
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .task {
      picoText = picoAddress
      addressText = controller.backendURL.absoluteString
      await controller.testConnection()
      await controller.refreshClock()
    }
    // Keep the field showing the address in use after Save, Paste or Reset.
    .onChange(of: controller.backendURL) { addressText = controller.backendURL.absoluteString }
  }

  // MARK: - New sections

  private var supervisorSection: some View {
    Section("Supervisor") {
      TextField("Supervisor phone number", text: $supervisorPhone)
        .keyboardType(.phonePad)
        .textContentType(.telephoneNumber)
        .font(.body.monospacedDigit())
        .accessibilityLabel("Supervisor phone number")
      Text("Used by Call supervisor on the Alerts tab.")
        .font(.subheadline)
        .foregroundStyle(NS.textSecondary)
    }
    .listRowBackground(NS.surface)
  }

  private var picoSection: some View {
    Section("Pico buzzer") {
      TextField("Pico address, e.g. 192.168.1.50", text: $picoText)
        .keyboardType(.numbersAndPunctuation)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.body.monospaced())
        .submitLabel(.done)
        .onSubmit { savePico() }
        .onChange(of: picoText) { picoError = nil }
        .accessibilityLabel("Pico address")
      if let picoError {
        Text(picoError).font(.subheadline).foregroundStyle(NS.redText)
      }
      FlatButton(title: "Save Pico address", icon: "checkmark") { savePico() }
        .buttonStyle(.borderless)
      HStack(spacing: 10) {
        ForEach(1...3, id: \.self) { level in
          FlatButton(title: testingLevel == level ? "Testing…" : "Level \(level)", accessibilityLabel: "Test nudge level \(level)") {
            testingLevel = level
            Task {
              testResult = await PicoNudge.test(level: level)
              testingLevel = nil
            }
          }
          .disabled(testingLevel != nil)
        }
      }
      .buttonStyle(.borderless)
      if let testResult {
        Label(
          "Test level \(testResult.level): \(testResult.ok ? "ok" : "failed") (\(testResult.detail))",
          systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(testResult.ok ? NS.green : NS.redText)
      }
      if let last = PicoStatus.shared.last {
        Text("Last nudge: \(last.ok ? "ok" : "failed") \(last.at.formatted(date: .omitted, time: .shortened)) · level \(last.level) · \(last.detail)")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(last.ok ? NS.textBody : NS.redText)
      } else {
        Text("Last nudge: none yet")
          .font(.subheadline)
          .foregroundStyle(NS.textSecondary)
      }
      Text("Alarms nudge level 1 at the start, 2 after 60 s and 3 after 120 s until acknowledged. A failed nudge never delays the alarm.")
        .font(.subheadline)
        .foregroundStyle(NS.textSecondary)
    }
    .listRowBackground(NS.surface)
  }

  private func savePico() {
    let text = picoText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      picoAddress = ""
      picoError = nil
      return
    }
    guard let address = Config.normalizedPicoAddress(text) else {
      picoError = "Not an IP address. Use four numbers like 192.168.1.50 (optionally :port)."
      return
    }
    picoAddress = address
    picoText = address
    picoError = nil
  }

  /// Optional shared key for backend writes; stored in the Keychain only.
  private var apiKeyRows: some View {
    Group {
      SecureField(Config.apiKey == nil ? "API key (optional)" : "API key saved (enter a new one to replace)", text: $apiKeyText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.body.monospaced())
        .accessibilityLabel("Backend API key")
      HStack(spacing: 10) {
        FlatButton(title: "Save key", icon: "key.fill") {
          let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
          apiKeySaved = Keychain.set(key, for: Config.Keys.apiKeyAccount)
            ? (key.isEmpty ? "Key removed." : "Key saved in the Keychain.")
            : "Couldn't save the key."
          apiKeyText = ""
        }
        FlatButton(title: "Remove key", icon: "trash") {
          apiKeySaved = Keychain.set(nil, for: Config.Keys.apiKeyAccount) ? "Key removed." : "Couldn't remove the key."
          apiKeyText = ""
        }
        .disabled(Config.apiKey == nil)
      }
      .buttonStyle(.borderless)
      Text(apiKeySaved ?? "Sent as X-API-Key on every write when the server requires it.")
        .font(.subheadline)
        .foregroundStyle(NS.textSecondary)
    }
  }

  private var developerSection: some View {
    Section("Developer") {
      if wearablesVM.registrationState == .registered {
        Button("Open glasses camera", systemImage: "video") { showCamera = true }
      } else {
        Text("Connect the glasses to open the camera.")
          .foregroundStyle(NS.textSecondary)
      }
      Toggle("Demo wells and pipelines on map", isOn: $showDemoLayers)
      Button("Next alert", systemImage: "forward") {
        Task { await controller.speakNextAlert() }
      }
      Button("Refresh all data", systemImage: "arrow.clockwise") {
        Task { await controller.refresh() }
      }
      .disabled(controller.isRefreshing)
    }
    .listRowBackground(NS.surface)
  }

  private var flagsSection: some View {
    Section("All flags this shift") {
      if let shift = controller.store.current, !shift.flags.isEmpty || !shift.notes.isEmpty {
        ForEach(shift.flags.reversed()) { flag in
          FlagRow(
            flag: flag,
            photoURL: controller.store.photoURL(for: flag, in: shift),
            facilityName: facilityName(for: flag.facility),
            onConfirm: { controller.decide(flag.id, as: .confirmed) },
            onDismiss: { controller.decide(flag.id, as: .dismissed) },
            onAddNote: {
              noteText = ""
              noteFlagID = flag.id
            }
          )
          .disabled(!controller.isOnShift)
        }
        ForEach(shift.notes) { note in
          Label(note.text, systemImage: "quote.bubble")
            .font(.subheadline)
        }
      } else {
        Text("No flags yet.")
          .foregroundStyle(NS.textSecondary)
      }
    }
    .listRowBackground(NS.surface)
  }

  /// Glasses link (Meta AI registration) and the camera screen.
  private var glassesSection: some View {
    Section("Glasses") {
      Label(
        cameraVM.hasActiveDevice ? "Glasses connected" : "Glasses not connected",
        systemImage: cameraVM.hasActiveDevice ? "eyeglasses" : "eyeglasses.slash"
      )
      .foregroundStyle(cameraVM.hasActiveDevice ? .green : .secondary)
      if wearablesVM.registrationState == .registered {
        Button("Disconnect glasses", systemImage: "xmark.circle", role: .destructive) {
          wearablesVM.disconnectGlasses()
        }
      } else {
        Button(
          wearablesVM.registrationState == .registering ? "Connecting…" : "Connect my glasses",
          systemImage: "link"
        ) {
          wearablesVM.connectGlasses()
        }
        .disabled(wearablesVM.registrationState == .registering)
        Text("You'll go to the Meta AI app to approve, then come back here.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Which system the home map shows, and a manual map refresh.
  private var mapSection: some View {
    Section("Map") {
      // Saved on the phone; the Map tab starts on this system.
      Picker("Default system", selection: Binding(
        get: { defaultSystem.isEmpty ? nil : defaultSystem },
        set: {
          defaultSystem = $0 ?? ""
          controller.mapSystemFilter = $0
        }
      )) {
        Text("All systems").tag(String?.none)
        ForEach(controller.map?.systemIDs ?? [], id: \.self) { id in
          Text(id).tag(Optional(id))
        }
      }
      Button("Refresh map", systemImage: "arrow.clockwise") {
        Task { await controller.refreshMap() }
      }
      .disabled(controller.isLoadingMap)
      if let asOf = controller.map?.asOf {
        Text("Data as of \(asOf)\(controller.map?.dataset.map { " · \($0)" } ?? "")")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let error = controller.mapError {
        Text("Map update failed: \(error)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var statusSection: some View {
    Section("Backend and uploads") {
      Label(
        "\(network.isConnected ? "Online" : "Offline") · \(controller.uploads.pendingCount) pending upload\(controller.uploads.pendingCount == 1 ? "" : "s")",
        systemImage: network.isConnected ? "wifi" : "wifi.slash"
      )
      ForEach(controller.uploads.entries) { entry in
        ReportStateRow(entry: entry) { controller.uploads.retry(entry.id) }
      }
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
        HStack(spacing: 8) {
          // Reachable dot from the last GET /clock check (text too, not color alone).
          let reachable = controller.isBackendReachable
          Rectangle()
            .fill(reachable == true ? NS.green : (reachable == false ? NS.red : NS.textMuted))
            .frame(width: 10, height: 10)
          Text(reachable == true ? "Reachable" : (reachable == false ? "Not reachable" : "Checking…"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(reachable == true ? NS.green : (reachable == false ? NS.redText : NS.textMuted))
          Text(Config.useMock ? "Mock data (offline demo)" : backendHostText)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
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
      apiKeyRows
      Button("Test connection", systemImage: "network") {
        Task { await controller.testConnection() }
      }
      .disabled(controller.isTestingConnection)
    }
  }

  private var facilitySection: some View {
    Section("Facility and camera checks") {
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
      Button("Check now", systemImage: "camera.viewfinder") {
        Task { await controller.vision.checkNow() }
      }
      .disabled(controller.vision.isCheckingNow)
      if controller.vision.isCheckingNow {
        Text("Checking…")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let report = controller.vision.lastManualCheck {
        checkReportBox(report)
      }
      // Test tool only: turn Config.showTestTools off before a real demo.
      if Config.showTestTools {
        Button("Simulate camera flag (leak) · test", systemImage: "testtube.2") {
          Task { await controller.simulateCameraFlag() }
        }
        .foregroundStyle(.purple)
        if let result = controller.simulateResult {
          Text(result.text)
            .font(.caption)
            .foregroundStyle(result.ok ? .green : .red)
        }
      }
    }
  }

  /// Raw outcome of the last Check now.
  private func checkReportBox(_ report: FrameGrabber.CheckReport) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(report.status) · \(report.at.formatted(date: .omitted, time: .standard))")
        .bold()
      if let result = report.result {
        Text("flag: \(String(result.flag))")
        Text("type: \(result.type ?? "nil")")
        Text("available: \(result.available.map { String($0) } ?? "nil")")
        Text("description: \(result.description ?? "nil")")
        Text("confidence: \(result.confidence.map { String($0) } ?? "nil") (display only)")
      }
      Text(report.createdFlag ? "Created a pending camera flag." : "No flag created.")
        .foregroundStyle(report.createdFlag ? .orange : .secondary)
    }
    .font(.caption.monospaced())
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
      // Permission off: say so plainly, with a way to fix it.
      if case .unavailable(let reason) = controller.voice.status {
        Label(reason, systemImage: "mic.slash.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(NS.redText)
        FlatButton(title: "Open iOS Settings", icon: "gear", accessibilityLabel: "Open iOS Settings to allow the microphone and speech recognition") {
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
        }
        .buttonStyle(.borderless)
      }
      // Live transcript, for checking what the recognizer hears.
      Text("Hearing: \(controller.voice.heardText.isEmpty ? "…" : controller.voice.heardText)")
        .font(.subheadline.monospaced())
        .foregroundStyle(NS.textBody)
      Text("Last phrase: \(controller.voice.lastHeard ?? "nothing yet")")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("Commands: what's the issue, dismiss, prioritize, acknowledge, stop, repeat, status, next alert.")
        .font(.caption)
        .foregroundStyle(NS.textSecondary)
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
      addressError = "Not a valid address. Use https (plain http only for a local IP)."
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
