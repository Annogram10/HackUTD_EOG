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

import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Time source for AlarmMonitor, injectable so tests don't sleep for real.
@MainActor
protocol AlarmClock: AnyObject {
  var now: Date { get }
  func sleep(for duration: Duration) async
}

@MainActor
final class SystemAlarmClock: AlarmClock {
  var now: Date { Date() }
  func sleep(for duration: Duration) async { try? await Task.sleep(for: duration) }
}

/// Everything the alarm does to the outside world. Each channel is best effort and
/// independent: a missing Pico, absent glasses or failed speech never blocks the rest.
@MainActor
protocol AlarmEffects: AnyObject {
  /// Siren, full-screen red overlay, haptics, alarm audio mode.
  func startAlarm(monitor: AlarmMonitor)
  /// Stops siren, overlay, haptics and speech; restores the normal audio mode.
  func stopAlarm()
  /// Stops the siren only (the red overlay stays).
  func silenceSiren()
  func setSirenDucked(_ ducked: Bool)
  /// Speaks and returns when done (or when speech fails or times out).
  func speak(_ text: String) async
  func stopSpeech()
  func nudge(level: Int)
}

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
  /// History hooks for the Alerts tab (display only; they don't change alarm behavior).
  @ObservationIgnored var onAcknowledged: (@MainActor (AlarmStatus) -> Void)?
  @ObservationIgnored var onFlagDecision: (@MainActor (FlagAction, BackendFlag, IssueReport) -> Void)?

  /// The last GET /alarm answer, flashing or not (for the tabs' alarm border and cards).
  private(set) var backendStatus: AlarmStatus?

  /// True if the backend's current alarm was already acknowledged on this phone.
  var isBackendAlarmAcknowledged: Bool {
    guard let backendStatus, backendStatus.alarm else { return false }
    return isAcknowledged(Self.identity(of: backendStatus))
  }

  /// Saves the backend's current alarm as acknowledged (after an on-screen decision
  /// from the Alerts or To-do tab) and stops any flash, siren and speech.
  func acknowledgeBackendAlarm() {
    if active != nil {
      acknowledge()
    } else if let backendStatus, backendStatus.alarm {
      markAcknowledged(Self.identity(of: backendStatus))
    }
  }

  // MARK: - Escalation

  /// Pico level by seconds since the alarm started, while unacknowledged.
  static let escalation: [(level: Int, after: TimeInterval)] = [(1, 0), (2, 60), (3, 120)]
  @ObservationIgnored private(set) var alarmStartedAt: Date?
  @ObservationIgnored private(set) var nudgedLevels: Set<Int> = []
  @ObservationIgnored private var escalationTask: Task<Void, Never>?

  /// Sends any escalation nudge that is due. Driven every second while an alarm is
  /// active; callable directly with a fake time in tests.
  func escalationTick(now: Date) {
    guard active != nil, let start = alarmStartedAt else { return }
    let elapsed = now.timeIntervalSince(start)
    for step in Self.escalation where elapsed >= step.after && !nudgedLevels.contains(step.level) {
      nudgedLevels.insert(step.level)
      effects.nudge(level: step.level)
    }
  }

  // MARK: - Monitoring health

  /// When GET /alarm last succeeded.
  private(set) var lastSuccess: Date?
  /// True after `failuresBeforeLost` failed polls in a row, until one succeeds.
  private(set) var monitoringLost = false
  @ObservationIgnored private(set) var consecutiveFailures = 0
  /// Number of GET /alarm requests started (for tests and diagnostics).
  @ObservationIgnored private(set) var pollsStarted = 0
  @ObservationIgnored private var isPolling = false

  static let failuresBeforeLost = 3

  /// Delay before the next poll: every 4 s normally, then 8 s and 15 s (cap) while
  /// monitoring is lost.
  var nextPollDelay: Duration {
    guard monitoringLost else { return Config.alarmPollInterval }
    let extra = consecutiveFailures - Self.failuresBeforeLost
    return extra <= 0 ? .seconds(8) : .seconds(15)
  }

  @ObservationIgnored private let api: any NightShiftAPI
  @ObservationIgnored let effects: any AlarmEffects
  @ObservationIgnored let clock: any AlarmClock
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var speechTask: Task<Void, Never>?
  @ObservationIgnored private var listenTimeoutTask: Task<Void, Never>?
  @ObservationIgnored private var issueExpiryTask: Task<Void, Never>?
  /// True if the alarm turned the listener on (so it turns it back off after).
  @ObservationIgnored private var startedVoice = false

  /// How long the alarm keeps the listener on, and an /issue answer stays actionable.
  private static let listenWindow: Duration = .seconds(180)

  /// Older builds saved only the last acknowledged id here.
  private static let legacyAcknowledgedKey = "NightShift.acknowledgedAlarmID"
  static let acknowledgedKey = "NightShift.acknowledgedAlarmIDs"
  /// Enough history for weeks of alarms; oldest ids drop off first.
  private static let acknowledgedLimit = 500

  @ObservationIgnored private let defaults: UserDefaults
  /// Off in tests so they never ask for microphone or speech permission.
  @ObservationIgnored private let listensDuringAlarm: Bool

  /// Every alarm id acknowledged on this phone (survives relaunch).
  private var acknowledgedIDs: [String] {
    get {
      var ids = defaults.stringArray(forKey: Self.acknowledgedKey) ?? []
      if let legacy = defaults.string(forKey: Self.legacyAcknowledgedKey), !ids.contains(legacy) {
        ids.append(legacy)
      }
      return ids
    }
    set { defaults.set(Array(newValue.suffix(Self.acknowledgedLimit)), forKey: Self.acknowledgedKey) }
  }

  func isAcknowledged(_ id: String) -> Bool {
    acknowledgedIDs.contains(id)
  }

  private func markAcknowledged(_ id: String) {
    guard !isAcknowledged(id) else { return }
    acknowledgedIDs.append(id)
  }

  init(
    api: any NightShiftAPI,
    voice: VoiceCommandListener,
    effects: (any AlarmEffects)? = nil,
    clock: any AlarmClock = SystemAlarmClock(),
    defaults: UserDefaults = .standard,
    listensDuringAlarm: Bool = true
  ) {
    self.api = api
    self.voice = voice
    self.effects = effects ?? LiveAlarmEffects()
    self.clock = clock
    self.defaults = defaults
    self.listensDuringAlarm = listensDuringAlarm
  }

  // MARK: - Polling

  /// One cancellable loop: poll, wait, repeat. Never more than one request in flight.
  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.pollOnce()
        await self.clock.sleep(for: self.nextPollDelay)
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  /// Fetches GET /alarm once. Skipped if the previous request is still in flight.
  func pollOnce() async {
    guard !isPolling else { return }
    isPolling = true
    defer { isPolling = false }
    pollsStarted += 1

    let status: AlarmStatus
    do {
      status = try await api.fetchAlarm()
    } catch {
      recordFailure()
      // A failed poll changes nothing else: keep flashing (or stay quiet).
      return
    }
    recordSuccess()
    backendStatus = status
    guard status.alarm else {
      stop()
      return
    }
    let id = Self.identity(of: status)
    if isAcknowledged(id) {
      stop()
    } else if active.map(Self.identity(of:)) != id {
      begin(status)
    } else {
      // Same alarm still on: keep the newest wording on screen.
      active = status
    }
  }

  private func recordFailure() {
    consecutiveFailures += 1
    guard consecutiveFailures >= Self.failuresBeforeLost, !monitoringLost else { return }
    monitoringLost = true
    Task { await effects.speak("Monitoring lost") }
  }

  private func recordSuccess() {
    lastSuccess = clock.now
    consecutiveFailures = 0
    guard monitoringLost else { return }
    monitoringLost = false
    Task { await effects.speak("Monitoring restored") }
  }

  /// alarm_id ("<dataset>:<facility>:<event>"); older backends without it fall back to
  /// facility id + level.
  nonisolated static func identity(of status: AlarmStatus) -> String {
    if let id = status.alarmId { return id }
    return "\(status.facilityIds.first ?? "unknown"):\(status.level ?? "unknown")"
  }

  // MARK: - Acknowledge

  /// "I saw this" or a tap anywhere: never flash this alarm_id again, and stop the
  /// flash, siren and speech on phone and glasses.
  func acknowledge() {
    if let active {
      markAcknowledged(Self.identity(of: active))
      onAcknowledged?(active)
    }
    stop()
  }

  // MARK: - Start / stop

  private func begin(_ status: AlarmStatus) {
    stop()
    active = status
    effects.startAlarm(monitor: self)
    // Escalation: Pico level 1 now, 2 at 60 s, 3 at 120 s while unacknowledged.
    alarmStartedAt = clock.now
    nudgedLevels = []
    escalationTick(now: clock.now)
    escalationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.clock.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        self.escalationTick(now: self.clock.now)
      }
    }
    if listensDuringAlarm {
      Task { await startListening() }
    }

    speechTask = Task { @MainActor [weak self] in
      // Let the siren sound first, then speak (siren ducked), and repeat until
      // acknowledged.
      try? await Task.sleep(for: .seconds(2))
      while !Task.isCancelled {
        guard let self, let text = self.active?.spokenText else { return }
        self.effects.setSirenDucked(true)
        await self.effects.speak(text)
        self.effects.setSirenDucked(false)
        try? await Task.sleep(for: Config.alarmRepeatInterval)
      }
    }
  }

  private func stop() {
    guard active != nil else { return }
    active = nil
    statusLine = nil
    clearIssue()
    speechTask?.cancel()
    speechTask = nil
    escalationTask?.cancel()
    escalationTask = nil
    alarmStartedAt = nil
    effects.stopAlarm()
    stopListeningIfStarted()
  }

  /// Silences the siren and the repeating alarm speech; the red flash stays.
  private func silence() {
    speechTask?.cancel()
    speechTask = nil
    effects.silenceSiren()
    effects.stopSpeech()
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
      await effects.speak(report.spokenText ?? "There is nothing to act on.")
    } catch {
      statusLine = ("Couldn't get the issue: \(NightShiftAPIError.describe(error))", false)
      await effects.speak("Couldn't get the issue. Try again.")
    }
  }

  /// Applies a decision to the last /issue flag. Returns false if no issue has been
  /// asked (so "dismiss" can fall back to the shift's own pending flag).
  @discardableResult
  func decide(_ action: FlagAction) async -> Bool {
    guard let issue else { return false }
    guard let flag = issue.flag else {
      statusLine = ("There is nothing to act on.", false)
      await effects.speak("There is nothing to act on.")
      return true
    }
    guard !isDeciding else { return true }
    isDeciding = true
    defer { isDeciding = false }
    do {
      let updated = try await api.decideFlag(id: flag.id, action: action)
      onFlagDecision?(action, updated, issue)
      let reply = action == .dismiss ? "Dismissed." : "Marked as priority."
      NSLog("[NightShift] Flag \(updated.id) now \(updated.status ?? "?") priority \(updated.priority)")
      // Either decision acknowledges the alarm; stop everything before confirming aloud.
      acknowledge()
      clearIssue()
      await effects.speak(reply)
      await onDecided?()
    } catch {
      statusLine = ("Couldn't send \(action.rawValue): \(NightShiftAPIError.describe(error))", false)
      await effects.speak("Couldn't reach the backend. Try again.")
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
}

/// The real alarm outputs: siren, full-screen overlay window, haptics, speech, Pico.
@MainActor
final class LiveAlarmEffects: AlarmEffects {
  private let siren = AlarmSiren()
  private var window: UIWindow?
  private var hapticTask: Task<Void, Never>?

  /// Longest a single phrase may take before speech is treated as failed.
  private static let speechTimeout: Duration = .seconds(45)

  /// True from startAlarm until silenceSiren/stopAlarm; an interruption (phone call,
  /// Siri) stops the siren's engine, and this says whether to restart it after.
  private var sirenWanted = false
  private var interruptionTask: Task<Void, Never>?
  private var routeTask: Task<Void, Never>?

  func startAlarm(monitor: AlarmMonitor) {
    Speaker.shared.stopAll()
    Speaker.isAlarmMode = true
    sirenWanted = true
    siren.start()
    showWindow(monitor: monitor)
    watchInterruptions()
    hapticTask?.cancel()
    hapticTask = Task { @MainActor in
      let haptics = UINotificationFeedbackGenerator()
      while !Task.isCancelled {
        haptics.notificationOccurred(.error)
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func stopAlarm() {
    sirenWanted = false
    interruptionTask?.cancel()
    interruptionTask = nil
    routeTask?.cancel()
    routeTask = nil
    hapticTask?.cancel()
    hapticTask = nil
    siren.stop()
    Speaker.shared.stopAll()
    // Back to the normal session (no ducking).
    Speaker.isAlarmMode = false
    hideWindow()
  }

  func silenceSiren() {
    sirenWanted = false
    siren.stop()
  }

  /// After a phone call or Siri ends, reactivate the session and restart the siren
  /// (if it should still be sounding). Route changes (glasses connect/disconnect)
  /// restart it too, so it follows the new output.
  private func watchInterruptions() {
    interruptionTask?.cancel()
    routeTask?.cancel()
    interruptionTask = Task { @MainActor [weak self] in
      for await note in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        if raw == AVAudioSession.InterruptionType.ended.rawValue {
          self?.restartSirenIfWanted()
        }
      }
    }
    routeTask = Task { @MainActor [weak self] in
      for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
        self?.restartSirenIfWanted()
      }
    }
  }

  /// Restarts only a siren that should be sounding but whose engine was stopped, so
  /// ordinary route changes (the listener picking the glasses mic) don't make it stutter.
  private func restartSirenIfWanted() {
    guard sirenWanted, !siren.isPlaying else { return }
    Speaker.activateAudioSession()
    siren.stop()
    siren.start()
  }

  func setSirenDucked(_ ducked: Bool) {
    siren.setDucked(ducked)
  }

  /// Speaks, but never waits longer than `speechTimeout`: if the synthesizer stalls,
  /// it's stopped so the alarm loop keeps going.
  func speak(_ text: String) async {
    // Stopping the synthesizer ends the stuck phrase, which returns speak().
    let watchdog = Task { @MainActor in
      try? await Task.sleep(for: Self.speechTimeout)
      if !Task.isCancelled {
        Speaker.shared.stopAll()
      }
    }
    await Speaker.shared.speak(text)
    watchdog.cancel()
  }

  func stopSpeech() {
    Speaker.shared.stopAll()
  }

  func nudge(level: Int) {
    PicoNudge.wake(level: level)
  }

  /// A window above everything (including sheets) so the flash covers the whole
  /// screen wherever the person is in the app.
  private func showWindow(monitor: AlarmMonitor) {
    guard window == nil else { return }
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard let scene else { return }
    let window = UIWindow(windowScene: scene)
    window.windowLevel = .alert + 1
    let host = UIHostingController(rootView: AlarmOverlayView(monitor: monitor))
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
        // Scrolls instead of clipping at the largest text sizes.
        ViewThatFits(in: .vertical) {
          content
          ScrollView { content }
        }
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
          .font(.ns(.headline))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(.black.opacity(0.35), in: Capsule())
      } else {
        Button {
          Task { await monitor.startListening() }
        } label: {
          Label("Listen", systemImage: "mic")
            .font(.ns(.headline))
            .frame(maxWidth: .infinity, minHeight: NS.tap)
        }
        .buttonStyle(.bordered)
        .tint(.white)
      }
      if monitor.issue == nil {
        Button {
          Task { await monitor.askIssue() }
        } label: {
          Label(monitor.isLoadingIssue ? "Asking…" : "What's the issue?", systemImage: "questionmark.bubble")
            .font(.ns(.headline))
            .frame(maxWidth: .infinity, minHeight: NS.tap)
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
        .font(.ns(.title3, .semibold))
        .multilineTextAlignment(.center)
        .padding(12)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
      if issue.flag != nil {
        AdaptiveStack(spacing: 12) {
          Button {
            Task { await monitor.decide(.dismiss) }
          } label: {
            Text("Dismiss")
              .font(.ns(.title2, .bold))
              .frame(maxWidth: .infinity, minHeight: 64)
          }
          .buttonStyle(.borderedProminent)
          .tint(.gray)
          Button {
            Task { await monitor.decide(.prioritize) }
          } label: {
            Text("Prioritize")
              .font(.ns(.title2, .bold))
              .frame(maxWidth: .infinity, minHeight: 64)
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
        .disabled(monitor.isDeciding)
      } else {
        Text("There is nothing to act on.")
          .font(.ns(.headline))
      }
    }
  }

  private var content: some View {
    VStack(spacing: 24) {
      Spacer()
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 72))
      Text("ALARM")
        .font(.ns(.largeTitle, .black))
      Text(monitor.active?.headline ?? "Something needs checking now")
        .font(.ns(.title, .bold))
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.6)
      if let issue = monitor.issue {
        issueSection(issue)
      } else {
        ForEach(Array((monitor.active?.reasons ?? []).prefix(3).enumerated()), id: \.offset) { _, reason in
          Text(reason)
            .font(.ns(.body))
            .multilineTextAlignment(.center)
        }
      }
      if let line = monitor.statusLine {
        Text(line.text)
          .font(.ns(.callout, .bold))
          .padding(8)
          .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      }
      Spacer()
      listeningRow
      Button {
        monitor.acknowledge()
      } label: {
        Text("I saw this")
          .font(.ns(.title, .bold))
          .frame(maxWidth: .infinity, minHeight: 72)
      }
      .buttonStyle(.borderedProminent)
      .tint(.white)
      .foregroundStyle(.red)
      Label("Keep the volume up", systemImage: "speaker.wave.3.fill")
        .font(.ns(.footnote, .bold))
    }
    .foregroundStyle(.white)
    .padding(28)
  }
}
