//
// AlarmMonitor.swift
//
// Polls GET /alarm every `Config.alarmPollInterval`. A new alarm (alarm == true with an
// alarm_id not yet acknowledged) flashes the whole screen red, vibrates, loops a siren
// on the current output (the glasses when connected), and speaks spoken_text every
// `Config.alarmRepeatInterval`, until the person taps. Tapping saves the alarm_id so it
// never flashes again; a different alarm_id starts a new flash. If the backend clears
// the alarm by itself, everything stops too.
//

import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class AlarmMonitor {
  /// The alarm currently flashing; nil when quiet.
  private(set) var active: AlarmStatus?

  @ObservationIgnored private let api: any NightShiftAPI
  @ObservationIgnored private let siren = AlarmSiren()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var hapticTask: Task<Void, Never>?
  @ObservationIgnored private var speechTask: Task<Void, Never>?
  @ObservationIgnored private var window: UIWindow?

  private static let acknowledgedKey = "NightShift.acknowledgedAlarmID"

  /// The last alarm_id the person acknowledged (persists across launches).
  private var acknowledgedID: String? {
    get { UserDefaults.standard.string(forKey: Self.acknowledgedKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.acknowledgedKey) }
  }

  init(api: any NightShiftAPI) {
    self.api = api
  }

  // MARK: - Polling

  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        try? await Task.sleep(for: Config.alarmPollInterval)
      }
    }
  }

  private func poll() async {
    // A failed poll changes nothing: keep flashing (or stay quiet) until we know more.
    guard let status = try? await api.fetchAlarm() else { return }
    guard status.alarm else {
      stop()
      return
    }
    let id = Self.identity(of: status)
    if id == acknowledgedID {
      stop()
    } else if active.map(Self.identity(of:)) != id {
      begin(status)
    } else {
      // Same alarm still on: keep the newest wording on screen.
      active = status
    }
  }

  /// alarm_id, or the headline if the backend didn't send one.
  private static func identity(of status: AlarmStatus) -> String {
    status.alarmId ?? status.headline ?? "alarm"
  }

  // MARK: - Acknowledge

  /// "I saw this" or a tap anywhere: never flash this alarm_id again, and stop the
  /// flash, siren and speech on phone and glasses.
  func acknowledge() {
    if let active {
      acknowledgedID = Self.identity(of: active)
    }
    stop()
  }

  // MARK: - Start / stop

  private func begin(_ status: AlarmStatus) {
    stop()
    active = status
    Speaker.shared.stopAll()
    Speaker.isAlarmMode = true
    siren.start()
    showWindow()

    hapticTask = Task { @MainActor in
      let haptics = UINotificationFeedbackGenerator()
      while !Task.isCancelled {
        haptics.notificationOccurred(.error)
        try? await Task.sleep(for: .seconds(2))
      }
    }
    speechTask = Task { @MainActor [weak self] in
      // Let the siren sound first, then speak, then repeat until acknowledged.
      try? await Task.sleep(for: .seconds(2))
      while !Task.isCancelled {
        guard let self, let text = self.active?.spokenText else { return }
        self.siren.setDucked(true)
        await Speaker.shared.speak(text)
        self.siren.setDucked(false)
        try? await Task.sleep(for: Config.alarmRepeatInterval)
      }
    }
  }

  private func stop() {
    guard active != nil else { return }
    active = nil
    hapticTask?.cancel()
    speechTask?.cancel()
    hapticTask = nil
    speechTask = nil
    siren.stop()
    Speaker.shared.stopAll()
    // Back to the normal session so voice commands resume (their watchdog restarts them).
    Speaker.isAlarmMode = false
    hideWindow()
  }

  // MARK: - Window

  /// A window above everything (including the Shift sheet) so the flash covers the
  /// whole screen wherever the person is in the app.
  private func showWindow() {
    guard window == nil else { return }
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard let scene else { return }
    let window = UIWindow(windowScene: scene)
    window.windowLevel = .alert + 1
    let host = UIHostingController(rootView: AlarmOverlayView(monitor: self))
    host.view.backgroundColor = .clear
    window.rootViewController = host
    window.isHidden = false
    self.window = window
  }

  private func hideWindow() {
    window?.isHidden = true
    window = nil
  }
}

/// Full-screen red flash with the headline and a big "I saw this" button. Tapping
/// anywhere acknowledges.
private struct AlarmOverlayView: View {
  var monitor: AlarmMonitor
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation) { context in
      ZStack {
        background(at: context.date)
          .ignoresSafeArea()
        content
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { monitor.acknowledge() }
    .accessibilityAddTraits(.isModal)
  }

  /// Pulses between dark and bright red about once a second (slowly with Reduce Motion).
  private func background(at date: Date) -> Color {
    let period = reduceMotion ? 4.0 : 1.0
    let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    let mix = (1 - cos(2 * .pi * t)) / 2
    return Color(red: 0.35 + 0.65 * mix, green: 0.0 + 0.08 * mix, blue: 0.0 + 0.08 * mix)
  }

  private var content: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 72))
      Text("ALARM")
        .font(.largeTitle.weight(.black))
      Text(monitor.active?.headline ?? "Something needs checking now")
        .font(.title.bold())
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
      ForEach(Array((monitor.active?.reasons ?? []).prefix(3).enumerated()), id: \.offset) { _, reason in
        Text(reason)
          .font(.body)
          .multilineTextAlignment(.center)
      }
      Spacer()
      Button {
        monitor.acknowledge()
      } label: {
        Text("I saw this")
          .font(.title.bold())
          .frame(maxWidth: .infinity, minHeight: 72)
      }
      .buttonStyle(.borderedProminent)
      .tint(.white)
      .foregroundStyle(.red)
      Label("Keep the volume up", systemImage: "speaker.wave.3.fill")
        .font(.footnote.bold())
    }
    .foregroundStyle(.white)
    .padding(28)
  }
}
