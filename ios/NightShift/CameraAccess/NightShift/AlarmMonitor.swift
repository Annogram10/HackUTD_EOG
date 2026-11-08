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
// Voice flow: the listener starts with the alarm (for up to 3 minutes). "What's the
// issue" stops the siren (the flash stays), fetches GET /issue and speaks its
// spoken_text; "dismiss" or "prioritize" (or the on-screen buttons) then POSTs the
// decision for the issue's flag, which also acknowledges the alarm and reloads /map.
//

import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class AlarmMonitor {
  /// The alarm currently flashing; nil when quiet.
  private(set) var active: AlarmStatus?
  /// Last GET /issue answer, kept until a decision, acknowledgement, or 3 minutes.
  private(set) var issue: IssueReport?
  private(set) var isLoadingIssue = false
  private(set) var isDeciding = false
  /// Last error or result line for the alarm screen.
  private(set) var statusLine: (text: String, ok: Bool)?

  let voice: VoiceCommandListener
  /// Called after a dismiss/prioritize succeeds (reloads /map so the route updates).
  @ObservationIgnored var onDecided: (@MainActor () async -> Void)?

  @ObservationIgnored private let api: any NightShiftAPI
  @ObservationIgnored private let siren = AlarmSiren()
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var hapticTask: Task<Void, Never>?
  @ObservationIgnored private var speechTask: Task<Void, Never>?
  @ObservationIgnored private var window: UIWindow?
  @ObservationIgnored private var listenTimeoutTask: Task<Void, Never>?
  @ObservationIgnored private var issueExpiryTask: Task<Void, Never>?
  /// True if the alarm turned the listener on (so it turns it back off after).
  @ObservationIgnored private var startedVoice = false

  /// How long the alarm keeps the listener on, and an /issue answer stays actionable.
  private static let listenWindow: Duration = .seconds(180)

  private static let acknowledgedKey = "NightShift.acknowledgedAlarmID"

  /// The last alarm_id the person acknowledged (persists across launches).
  private var acknowledgedID: String? {
    get { UserDefaults.standard.string(forKey: Self.acknowledgedKey) }
    set { UserDefaults.standard.set(newValue, forKey: Self.acknowledgedKey) }
  }

  init(api: any NightShiftAPI, voice: VoiceCommandListener) {
    self.api = api
    self.voice = voice
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
    Task { await startListening() }

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
    statusLine = nil
    clearIssue()
    hapticTask?.cancel()
    speechTask?.cancel()
    hapticTask = nil
    speechTask = nil
    siren.stop()
    Speaker.shared.stopAll()
    // Back to the normal session (no ducking).
    Speaker.isAlarmMode = false
    stopListeningIfStarted()
    hideWindow()
  }

  /// Silences the siren and the repeating alarm speech; the red flash stays.
  private func silence() {
    speechTask?.cancel()
    speechTask = nil
    siren.stop()
    Speaker.shared.stopAll()
  }

  // MARK: - Listening

  /// Turns the voice listener on for up to `listenWindow` (the "Listen" button too).
  func startListening() async {
    listenTimeoutTask?.cancel()
    if !voice.isListening {
      await voice.start()
      startedVoice = voice.isListening
    }
    listenTimeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.listenWindow)
      guard !Task.isCancelled else { return }
      self?.stopListeningIfStarted()
    }
  }

  private func stopListeningIfStarted() {
    listenTimeoutTask?.cancel()
    listenTimeoutTask = nil
    if startedVoice {
      startedVoice = false
      voice.stop()
    }
  }

  // MARK: - Issue and decisions

  /// "What's the issue": stop the siren (keep the flash), GET /issue, show and speak it.
  func askIssue() async {
    guard !isLoadingIssue else { return }
    silence()
    isLoadingIssue = true
    defer { isLoadingIssue = false }
    do {
      let report = try await api.fetchIssue(facility: nil)
      issue = report
      statusLine = nil
      issueExpiryTask?.cancel()
      issueExpiryTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.listenWindow)
        guard !Task.isCancelled else { return }
        self?.issue = nil
      }
      await Speaker.shared.speak(report.spokenText ?? "There is nothing to act on.")
    } catch {
      statusLine = ("Couldn't get the issue: \(NightShiftAPIError.describe(error))", false)
      await Speaker.shared.speak("Couldn't get the issue. Try again.")
    }
  }

  /// Applies a decision to the last /issue flag. Returns false if no issue has been
  /// asked (so "dismiss" can fall back to the shift's own pending flag).
  @discardableResult
  func decide(_ action: FlagAction) async -> Bool {
    guard let issue else { return false }
    guard let flag = issue.flag else {
      statusLine = ("There is nothing to act on.", false)
      await Speaker.shared.speak("There is nothing to act on.")
      return true
    }
    guard !isDeciding else { return true }
    isDeciding = true
    defer { isDeciding = false }
    do {
      let updated = try await api.decideFlag(id: flag.id, action: action)
      let reply = action == .dismiss ? "Dismissed." : "Marked as priority."
      NSLog("[NightShift] Flag \(updated.id) now \(updated.status ?? "?") priority \(updated.priority)")
      // Either decision acknowledges the alarm; stop everything before confirming aloud.
      acknowledge()
      clearIssue()
      await Speaker.shared.speak(reply)
      await onDecided?()
    } catch {
      statusLine = ("Couldn't send \(action.rawValue): \(NightShiftAPIError.describe(error))", false)
      await Speaker.shared.speak("Couldn't reach the backend. Try again.")
    }
    return true
  }

  /// True while an /issue answer is waiting for a decision.
  var isAwaitingDecision: Bool { issue != nil }

  private func clearIssue() {
    issueExpiryTask?.cancel()
    issueExpiryTask = nil
    issue = nil
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

  /// Listening state plus how to start: say "What's the issue" or tap.
  private var listeningRow: some View {
    VStack(spacing: 10) {
      if monitor.voice.isRunning {
        Label("Listening: say \"What's the issue\"", systemImage: "mic.fill")
          .font(.headline)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(.black.opacity(0.35), in: Capsule())
      } else {
        Button {
          Task { await monitor.startListening() }
        } label: {
          Label("Listen", systemImage: "mic")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(.white)
      }
      if monitor.issue == nil {
        Button {
          Task { await monitor.askIssue() }
        } label: {
          Label(monitor.isLoadingIssue ? "Asking…" : "What's the issue?", systemImage: "questionmark.bubble")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(monitor.isLoadingIssue)
      }
    }
  }

  /// The /issue answer as text, with Dismiss and Prioritize when there is a flag.
  private func issueSection(_ issue: IssueReport) -> some View {
    VStack(spacing: 14) {
      Text(issue.spokenText ?? "There is nothing to act on.")
        .font(.title3.weight(.semibold))
        .multilineTextAlignment(.center)
        .padding(12)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
      if issue.flag != nil {
        HStack(spacing: 12) {
          Button {
            Task { await monitor.decide(.dismiss) }
          } label: {
            Text("Dismiss")
              .font(.title2.bold())
              .frame(maxWidth: .infinity, minHeight: 64)
          }
          .buttonStyle(.borderedProminent)
          .tint(.gray)
          Button {
            Task { await monitor.decide(.prioritize) }
          } label: {
            Text("Prioritize")
              .font(.title2.bold())
              .frame(maxWidth: .infinity, minHeight: 64)
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
        .disabled(monitor.isDeciding)
      } else {
        Text("There is nothing to act on.")
          .font(.headline)
      }
    }
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
      if let issue = monitor.issue {
        issueSection(issue)
      } else {
        ForEach(Array((monitor.active?.reasons ?? []).prefix(3).enumerated()), id: \.offset) { _, reason in
          Text(reason)
            .font(.body)
            .multilineTextAlignment(.center)
        }
      }
      if let line = monitor.statusLine {
        Text(line.text)
          .font(.callout.bold())
          .padding(8)
          .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      }
      Spacer()
      listeningRow
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
