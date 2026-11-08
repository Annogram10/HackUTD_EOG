//
// AlertsView.swift
//
// Alerts tab. Active: the current backend alarm (red-tinted card) and pending flags,
// each with Dismiss and Prioritize; "What's the issue?" calls GET /issue and speaks the
// result. History: past alarms and flags decided on this phone, with outcome and time.
// "Call supervisor" dials the number saved in Settings.
//

import SwiftUI

struct AlertsView: View {
  var controller: NightShiftController
  let alarmActive: Bool
  @AppStorage(Config.Keys.supervisorPhone) private var supervisorPhone = ""
  @Environment(\.openURL) private var openURL
  @State private var segment = Segment.active
  @State private var alarmError: String?
  @State private var isDeciding = false

  enum Segment: Hashable { case active, history }

  private var pendingFlags: [Flag] {
    (controller.store.current?.flags ?? []).filter { $0.status == .pending }.reversed()
  }

  private var currentAlarm: AlarmStatus? {
    guard let status = controller.alarm.backendStatus, status.alarm else { return nil }
    return status
  }

  /// Shortest hours to shutdown among the alarm's facilities (from /map).
  private var alarmHoursLeft: Double? {
    guard let ids = currentAlarm?.facilityIds else { return nil }
    return controller.map?.facilities
      .filter { ids.contains($0.id) }
      .compactMap(\.hoursToShutdown)
      .min()
  }

  var body: some View {
    VStack(spacing: 0) {
      HeaderStrip(alarmActive: alarmActive) {
        HStack {
          Text("Alerts")
            .font(.ns(.title2, .bold))
            .foregroundStyle(NS.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Spacer()
        }
        .frame(minHeight: 40)
      }
      UnderlineSegments(options: [(Segment.active, "Active"), (Segment.history, "History")], selection: $segment)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          switch segment {
          case .active: activeList
          case .history: historyList
          }
          callSupervisor
            .padding(.top, 8)
        }
        .padding(16)
      }
    }
    .background(NS.background)
  }

  // MARK: - Active

  @ViewBuilder
  private var activeList: some View {
    if controller.alarm.monitoringLost {
      StateCard(
        title: "Can't check for alarms right now",
        detail: "Showing the last known state. Retrying by itself.",
        icon: "exclamationmark.triangle.fill",
        tone: .red
      )
    } else if controller.alarm.lastSuccess == nil {
      StateCard(title: "Checking for alarms…", detail: nil, icon: "hourglass", tone: .grey)
    }
    if currentAlarm == nil && pendingFlags.isEmpty && controller.alarm.lastSuccess != nil {
      StateCard(title: "No problems in progress", detail: nil, icon: "checkmark.circle", tone: .green)
    }
    if let alarm = currentAlarm {
      alarmCard(alarm)
    }
    ForEach(pendingFlags) { flag in
      flagCard(flag)
    }
  }

  private func alarmCard(_ alarm: AlarmStatus) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        LevelBadge(level: alarm.severityKey)
        if controller.alarm.isBackendAlarmAcknowledged {
          Badge(text: "Acknowledged", tone: .grey)
        }
        Spacer()
        if let asOf = alarm.asOf {
          Text(asOf)
            .font(.nsMono(.footnote))
            .foregroundStyle(NS.textSecondary)
        }
      }
      Text(alarm.headline ?? "Alarm")
        .font(.ns(.title3, .semibold))
        .foregroundStyle(NS.textPrimary)
      if let note = alarm.note {
        Text(note)
          .font(.ns(.body))
          .foregroundStyle(NS.textBody)
      }
      ForEach(Array(alarm.reasons.enumerated()), id: \.offset) { _, reason in
        Text(reason)
          .font(.ns(.body))
          .foregroundStyle(NS.textBody)
      }
      if let hours = alarmHoursLeft {
        Text(hoursLeftText(hours))
          .font(.nsMono(.headline))
          .foregroundStyle(NS.redText)
      }
      if let alarmError {
        Text(alarmError).font(.ns(.subheadline)).foregroundStyle(NS.redText)
      }
      AdaptiveStack(spacing: 10) {
        FlatButton(title: "Dismiss", icon: "xmark", accessibilityLabel: "Dismiss the alarm") {
          decide(.dismiss)
        }
        FlatButton(title: "Prioritize", icon: "exclamationmark.2", kind: .warning, accessibilityLabel: "Prioritize the alarm") {
          decide(.prioritize)
        }
      }
      .disabled(isDeciding)
      FlatButton(title: controller.alarm.isLoadingIssue ? "Asking…" : "What's the issue?",
                 icon: "questionmark.bubble", kind: .primary,
                 accessibilityLabel: "Ask what's the issue and hear the answer") {
        Task { await controller.alarm.askIssue() }
      }
      .disabled(controller.alarm.isLoadingIssue)
      if let spoken = controller.alarm.issue?.spokenText {
        Text(spoken)
          .font(.ns(.body))
          .foregroundStyle(NS.textBody)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .flatCard(fill: NS.raised)
      }
    }
    .padding(12)
    .flatCard(fill: NS.red.opacity(0.12), stroke: NS.red.opacity(0.5))
  }

  private func decide(_ action: FlagAction) {
    isDeciding = true
    Task {
      // After "What's the issue?", act on that answer exactly like the voice command.
      if controller.alarm.isAwaitingDecision {
        await controller.alarm.decide(action)
        alarmError = nil
      } else {
        alarmError = await controller.decideCurrentAlarm(action)
      }
      isDeciding = false
    }
  }

  private func flagCard(_ flag: Flag) -> some View {
    let place = flag.facility.flatMap { id in controller.map?.facilities.first { $0.id == id }?.displayName } ?? flag.facility ?? "Unknown place"
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Badge(text: "NEEDS REVIEW", tone: .amber, icon: "exclamationmark.triangle.fill")
        Badge(text: flag.source == "voice" ? "Voice" : "Camera", tone: .grey)
        Spacer()
        Text(flag.createdAt.formatted(date: .omitted, time: .shortened))
          .font(.nsMono(.footnote))
          .foregroundStyle(NS.textSecondary)
      }
      Text("Possible \(flag.type) at \(place)")
        .font(.ns(.title3, .semibold))
        .foregroundStyle(NS.textPrimary)
      if let description = flag.description {
        Text(description).font(.ns(.body)).foregroundStyle(NS.textBody)
      }
      AdaptiveStack(spacing: 10) {
        FlatButton(title: "Dismiss", icon: "xmark", accessibilityLabel: "Dismiss possible \(flag.type) at \(place)") {
          controller.decide(flag.id, as: .dismissed)
        }
        FlatButton(title: "Prioritize", icon: "exclamationmark.2", kind: .warning,
                   accessibilityLabel: "Prioritize possible \(flag.type) at \(place)") {
          controller.prioritize(flag.id)
        }
      }
    }
    .padding(12)
    .flatCard()
  }

  // MARK: - History

  @ViewBuilder
  private var historyList: some View {
    if controller.history.isEmpty {
      Text("Nothing here yet. Decisions you make show up here.")
        .font(.ns(.body))
        .foregroundStyle(NS.textBody)
        .frame(maxWidth: .infinity, minHeight: 100)
        .flatCard()
    }
    ForEach(controller.history) { entry in
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: entry.kind == .alarm ? "bell.fill" : "flag.fill")
          .foregroundStyle(NS.textMuted)
          .frame(width: 24)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text(entry.title)
            .font(.ns(.body, .semibold))
            .foregroundStyle(NS.textPrimary)
          Text(entry.at.formatted(date: .abbreviated, time: .shortened))
            .font(.nsMono(.subheadline))
            .foregroundStyle(NS.textSecondary)
        }
        Spacer()
        Badge(text: entry.outcome.rawValue, tone: outcomeTone(entry.outcome))
      }
      .padding(12)
      .frame(minHeight: NS.tap)
      .flatCard()
      .accessibilityElement(children: .combine)
    }
  }

  private func outcomeTone(_ outcome: NightShiftController.AlertHistoryEntry.Outcome) -> Tone {
    switch outcome {
    case .confirmed: return .red
    case .prioritized: return .amber
    case .dismissed, .acknowledged: return .grey
    }
  }

  // MARK: - Supervisor

  private var callSupervisor: some View {
    let digits = supervisorPhone.filter { $0.isNumber || $0 == "+" }
    return VStack(alignment: .leading, spacing: 6) {
      FlatButton(title: "Call supervisor", icon: "phone.fill",
                 accessibilityLabel: digits.isEmpty ? "Call supervisor. No number saved yet." : "Call supervisor") {
        if let url = URL(string: "tel:\(digits)") {
          openURL(url)
        }
      }
      .disabled(digits.isEmpty)
      if digits.isEmpty {
        Text("Add the supervisor's number in Settings.")
          .font(.ns(.subheadline))
          .foregroundStyle(NS.textSecondary)
      }
    }
  }
}
