//
// LiveView.swift
//
// LIVE tab (glasses): the glasses camera preview in a crimson frame with corner
// brackets, a "CAM · AUDIO · <facility>" overlay and a SCAN dot that blinks on every
// vision check, the "I'm at" facility card, and a voice status bar (LISTENING /
// SPEAKING / command hint). Also the header link chip and its connection sheet.
// Visual layer only: it calls the existing camera, voice and facility APIs.
//

import SwiftUI

struct LiveView: View {
  var controller: NightShiftController
  @Bindable var cameraVM: CameraViewModel
  var wearablesVM: WearablesViewModel

  var body: some View {
    VStack(spacing: 12) {
      CameraPreviewFrame(controller: controller, cameraVM: cameraVM, wearablesVM: wearablesVM)
        .frame(maxHeight: .infinity)
      FacilityPickerCard(controller: controller)
      VoiceStatusBar(controller: controller)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(NS.background)
    .flagCardOverlay(controller: controller)
    // The camera's own prompts, also needed when the preview starts from here.
    .alert("Allow camera access", isPresented: $cameraVM.showCameraPermissionRedirectConfirm) {
      Button("Continue") { Task { await cameraVM.confirmCameraPermissionRedirect() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("To see your glasses camera, you'll go to the Meta AI app to allow access, then come back here.")
    }
    .alert("Something went wrong", isPresented: $cameraVM.showError) {
      Button("OK") { cameraVM.dismissError() }
    } message: {
      Text(cameraVM.errorMessage)
    }
  }
}

// MARK: - Link chip

/// Header chip: OPTICS ONLINE (green) / CONNECTING... (orange) / OPTICS OFFLINE (orange).
/// Tapping opens the connection details.
struct LinkStatusChip: View {
  var cameraVM: CameraViewModel
  var wearablesVM: WearablesViewModel
  let action: () -> Void

  enum LinkState { case online, connecting, offline }

  private var state: LinkState {
    if cameraVM.hasActiveDevice && (cameraVM.isSessionActive || cameraVM.isStreaming) { return .online }
    if wearablesVM.registrationState == .registering || cameraVM.isSessionStarting { return .connecting }
    if cameraVM.hasActiveDevice { return .online }
    return .offline
  }

  var body: some View {
    let (text, color): (String, Color) = switch state {
    case .online: ("OPTICS ONLINE", NS.green)
    case .connecting: ("CONNECTING...", NS.amber)
    case .offline: ("OPTICS OFFLINE", NS.amber)
    }
    Button {
      Haptics.tap()
      action()
    } label: {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(text)
          .font(.nsMono(.caption2, .semibold))
          .foregroundStyle(color)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .padding(.horizontal, 10)
      .frame(minHeight: 44)
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6), lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Glasses: \(text.lowercased()). Shows connection details.")
  }
}

/// Connection details: glasses link, camera session and stream, full camera controls.
struct ConnectionSheet: View {
  var controller: NightShiftController
  @Bindable var cameraVM: CameraViewModel
  var wearablesVM: WearablesViewModel
  @State private var showCamera = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("LINK")
          .font(.nsDisplay(.title2))
          .foregroundStyle(NS.textPrimary)
          .accessibilityAddTraits(.isHeader)
        SysCard(label: "SYS//LINK", key: true) {
          row("Glasses", cameraVM.hasActiveDevice ? "Connected" : "Not connected", ok: cameraVM.hasActiveDevice)
          row("Meta AI link", registrationText, ok: wearablesVM.registrationState == .registered)
          row("Camera session", cameraVM.sessionStateText.capitalized, ok: cameraVM.isSessionActive)
          row("Camera stream", cameraVM.streamStateText.capitalized, ok: cameraVM.isStreaming)
          row("Voice", controller.voice.isRunning ? "Listening" : "Off", ok: controller.voice.isRunning)
          if wearablesVM.requiresFirmwareUpdate {
            Text("Your glasses need a software update before the camera can start.")
              .font(.ns(.body))
              .foregroundStyle(NS.amber)
          }
        }
        if wearablesVM.registrationState == .registered {
          FlatButton(title: "Open camera controls", icon: "video", kind: .secondary) { showCamera = true }
          FlatButton(title: "Disconnect glasses", icon: "xmark.circle", kind: .danger) { wearablesVM.disconnectGlasses() }
        } else {
          FlatButton(title: wearablesVM.registrationState == .registering ? "Connecting…" : "Connect my glasses",
                     icon: "link", kind: .primary) { wearablesVM.connectGlasses() }
            .disabled(wearablesVM.registrationState == .registering)
          Text("You'll go to the Meta AI app to approve, then come back here.")
            .font(.ns(.subheadline))
            .foregroundStyle(NS.textMuted)
        }
        FlatButton(title: "Close", kind: .secondary) { dismiss() }
      }
      .padding(16)
    }
    .background(NS.background)
    .fullScreenCover(isPresented: $showCamera) {
      CameraView(viewModel: cameraVM, wearablesVM: wearablesVM)
    }
  }

  private var registrationText: String {
    switch wearablesVM.registrationState {
    case .registered: return "Linked"
    case .registering: return "Linking…"
    default: return "Not linked"
    }
  }

  private func row(_ label: String, _ value: String, ok: Bool) -> some View {
    HStack {
      Text(label).font(.ns(.body)).foregroundStyle(NS.textMuted)
      Spacer()
      Label(value, systemImage: ok ? "checkmark.circle.fill" : "minus.circle")
        .font(.ns(.body, .semibold))
        .foregroundStyle(ok ? NS.green : NS.amber)
    }
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Camera preview

/// The glasses camera in a thin crimson frame with corner brackets.
private struct CameraPreviewFrame: View {
  var controller: NightShiftController
  var cameraVM: CameraViewModel
  var wearablesVM: WearablesViewModel

  private var facilityText: String {
    guard let id = controller.currentFacilityID else { return "NO FACILITY SET" }
    let name = controller.map?.facilities.first { $0.id == id }?.displayName ?? id
    return name.uppercased()
  }

  var body: some View {
    ZStack {
      Rectangle().fill(Color.black)
      if cameraVM.isStreaming, let frame = cameraVM.currentVideoFrame {
        Image(uiImage: frame)
          .resizable()
          .scaledToFill()
          .accessibilityLabel("Glasses camera view")
      } else {
        startControls
      }
    }
    .clipShape(Rectangle())
    .overlay(Rectangle().strokeBorder(NS.borderStrong, lineWidth: 1))
    .overlay { CornerBrackets().stroke(NS.borderStrong, lineWidth: 2).padding(6).accessibilityHidden(true) }
    .overlay(alignment: .bottomLeading) {
      Text("\(cameraVM.isStreaming ? "CAM" : "CAM OFF") · \(controller.voice.isRunning ? "AUDIO" : "AUDIO OFF") · \(facilityText)")
        .font(.nsMono(.caption, .semibold))
        .foregroundStyle(NS.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(NS.background.opacity(0.75))
        .padding(12)
        .accessibilityLabel("Camera \(cameraVM.isStreaming ? "on" : "off"), audio \(controller.voice.isRunning ? "on" : "off"), facility \(facilityText.lowercased())")
    }
    .overlay(alignment: .topTrailing) {
      ScanIndicator(controller: controller)
        .padding(12)
    }
  }

  /// Not streaming: the next step to get the camera going.
  @ViewBuilder
  private var startControls: some View {
    VStack(spacing: 12) {
      Image(systemName: "eyeglasses")
        .font(.system(size: 44))
        .foregroundStyle(NS.textMuted)
        .accessibilityHidden(true)
      if wearablesVM.registrationState != .registered {
        Text("Glasses not linked")
          .font(.ns(.title3, .semibold))
          .foregroundStyle(NS.textPrimary)
        FlatButton(title: "Connect my glasses", icon: "link", kind: .primary) { wearablesVM.connectGlasses() }
      } else if !cameraVM.isSessionActive {
        Text(cameraVM.isSessionStarting ? "Starting session…" : "Camera off")
          .font(.ns(.title3, .semibold))
          .foregroundStyle(NS.textPrimary)
        FlatButton(title: "Start session", icon: "power", kind: .primary) { cameraVM.startSession() }
          .disabled(cameraVM.isSessionStarting || !cameraVM.hasActiveDevice)
        if !cameraVM.hasActiveDevice {
          Text("Waiting for the glasses…")
            .font(.ns(.subheadline))
            .foregroundStyle(NS.textMuted)
        }
      } else {
        Text(cameraVM.hasStream ? "Starting camera…" : "Session ready")
          .font(.ns(.title3, .semibold))
          .foregroundStyle(NS.textPrimary)
        FlatButton(title: "Start camera", icon: "video.fill", kind: .primary) {
          Task { await cameraVM.startStreaming() }
        }
        .disabled(cameraVM.hasStream)
      }
    }
    .padding(24)
  }
}

/// Four L-shaped corner brackets.
private struct CornerBrackets: Shape {
  var length: CGFloat = 18

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let l = min(length, rect.width / 4, rect.height / 4)
    // Top left
    p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
    // Top right
    p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
    // Bottom right
    p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
    // Bottom left
    p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
    return p
  }
}

/// "SCAN" dot that blinks each time a frame is sent; "VISION OFFLINE" when the backend
/// can't be reached. No blinking with Reduce Motion.
private struct ScanIndicator: View {
  var controller: NightShiftController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var flash = false

  private var offline: Bool {
    controller.isBackendReachable == false || BackendStatus.shared.isUnreachable
  }

  var body: some View {
    HStack(spacing: 6) {
      if offline {
        Text("VISION OFFLINE")
          .font(.nsMono(.caption2, .bold))
          .foregroundStyle(NS.amber)
      } else {
        Circle()
          .fill(flash ? NS.highlight : NS.green.opacity(0.5))
          .frame(width: 8, height: 8)
        Text("SCAN")
          .font(.nsMono(.caption2, .bold))
          .foregroundStyle(NS.textPrimary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(NS.background.opacity(0.75))
    .onChange(of: controller.vision.checksSent) {
      guard !reduceMotion else { return }
      flash = true
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        flash = false
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(offline ? "Vision offline" : "Vision scanning, \(controller.vision.checksSent) frames sent")
  }
}

// MARK: - "I'm at" facility

/// The current facility, big; tap to choose from the real facility list.
private struct FacilityPickerCard: View {
  var controller: NightShiftController

  /// Map facilities (backend order) plus any alert facility not on the map.
  private var choices: [(id: String, name: String)] {
    var seen = Set<String>()
    let fromMap = (controller.map?.facilities ?? []).map { ($0.id, $0.displayName) }
    return (fromMap + controller.facilityChoices.map { ($0.id, $0.name) })
      .filter { seen.insert($0.0).inserted }
      .map { (id: $0.0, name: $0.1) }
  }

  private var currentName: String? {
    guard let id = controller.currentFacilityID else { return nil }
    return choices.first { $0.id == id }?.name ?? id
  }

  var body: some View {
    SysCard(label: "SYS//LOCATION") {
      Menu {
        ForEach(choices, id: \.id) { choice in
          Button(choice.name) {
            Haptics.tap()
            controller.setCurrentFacility(choice.id)
          }
        }
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("I'M AT")
              .font(.ns(.footnote, .bold))
              .foregroundStyle(NS.textSecondary)
            if let currentName {
              Text(currentName)
                .font(.ns(.title2, .bold))
                .foregroundStyle(NS.textPrimary)
            } else {
              Text("Pick the facility you're at so flags land in the right place.")
                .font(.ns(.body, .semibold))
                .foregroundStyle(NS.amber)
                .multilineTextAlignment(.leading)
            }
          }
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .foregroundStyle(NS.accent)
            .accessibilityHidden(true)
        }
        .frame(minHeight: NS.tap)
        .contentShape(Rectangle())
      }
      .disabled(choices.isEmpty)
      .accessibilityLabel(currentName.map { "I'm at \($0). Change facility." } ?? "No facility set. Choose the facility you're at.")
    }
  }
}

// MARK: - Voice status

/// LISTENING (blinking yellow cursor), SPEAKING (level meter), or the command hint.
private struct VoiceStatusBar: View {
  var controller: NightShiftController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The real whitelisted commands.
  private static let hint = "SAY 'WHAT'S THE ISSUE', 'STATUS', 'NEXT', 'CONFIRM', 'DISMISS', 'REPEAT'"

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { context in
      let speaking = Speaker.shared.isBusy
      let listening = controller.voice.isRunning
      let blinkOn = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
      HStack(spacing: 10) {
        if speaking {
          Text("SPEAKING")
            .font(.nsMono(.subheadline, .bold))
            .foregroundStyle(NS.primary)
          LevelMeter(phase: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
        } else if listening {
          Text("LISTENING")
            .font(.nsMono(.subheadline, .bold))
            .foregroundStyle(NS.green)
          Rectangle()
            .fill(NS.highlight)
            .frame(width: 9, height: 18)
            .opacity(blinkOn ? 1 : 0)
          if !controller.voice.heardText.isEmpty {
            Text(controller.voice.heardText)
              .font(.ns(.subheadline))
              .foregroundStyle(NS.textMuted)
              .lineLimit(1)
              .truncationMode(.head)
          }
        } else {
          Image(systemName: "mic.slash")
            .foregroundStyle(NS.textMuted)
            .accessibilityHidden(true)
          Text("VOICE OFF · TAP TO LISTEN")
            .font(.nsMono(.caption, .semibold))
            .foregroundStyle(NS.textMuted)
        }
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(speaking ? "Speaking" : (listening ? "Listening" : "Voice off. Double tap to listen."))
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: .infinity, minHeight: NS.tap)
    .flatCard()
    .overlay(alignment: .bottom) {
      if controller.voice.isRunning && !Speaker.shared.isBusy && controller.voice.heardText.isEmpty {
        Text(Self.hint)
          .font(.nsMono(.caption2))
          .foregroundStyle(NS.textSecondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 8)
          .offset(y: 22)
          .accessibilityHidden(true)
      }
    }
    .padding(.bottom, controller.voice.isRunning ? 22 : 0)
    .onTapGesture {
      guard !controller.voice.isRunning else { return }
      Haptics.tap()
      Task { await controller.setVoiceEnabled(true) }
    }
    .accessibilityAddTraits(.isButton)
  }
}

/// A simple five-bar meter that moves while the app speaks.
private struct LevelMeter: View {
  let phase: TimeInterval

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(0..<5, id: \.self) { i in
        let height = phase == 0 ? 10 : 6 + 12 * abs(sin(phase * 6 + Double(i) * 0.9))
        Rectangle()
          .fill(NS.primary)
          .frame(width: 4, height: height)
      }
    }
    .frame(height: 20)
    .accessibilityHidden(true)
  }
}
