//
// DangerBanner.swift
//
// Danger alert on every screen while GET /alarm reports an alarm: a filled red banner
// "// ALERT · <facility> · SHUTDOWN IN <h>" with the server's cheapest plan underneath.
// One strong haptic when it appears; its border pulses three times (not with Reduce
// Motion). Tap for the detail sheet (countdown, plan, cost, ACKNOWLEDGE). Once
// acknowledged it collapses to a slim red strip until the alert clears.
//

import SwiftUI
import UIKit

struct DangerBanner: View {
  var controller: NightShiftController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showDetail = false
  @State private var pulse = false
  @State private var announcedID: String?

  private var alarm: AlarmStatus? {
    guard let status = controller.alarm.backendStatus, status.alarm else { return nil }
    return status
  }

  var body: some View {
    if let alarm {
      let info = DangerInfo(alarm: alarm, controller: controller)
      Group {
        if controller.alarm.isBackendAlarmAcknowledged {
          slimStrip(info)
        } else {
          fullBanner(info)
        }
      }
      .onAppear { announce(alarm) }
      .onChange(of: alarm.alarmId) { announce(alarm) }
      .sheet(isPresented: $showDetail) {
        DangerDetailSheet(controller: controller, info: info)
          .presentationDetents([.medium, .large])
      }
    }
  }

  private func fullBanner(_ info: DangerInfo) -> some View {
    Button {
      Haptics.tap()
      showDetail = true
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(info.headline)
          .font(.nsDisplay(.title3))
          .foregroundStyle(NS.onFill)
          .lineLimit(2)
          .minimumScaleFactor(0.8)
        if let plan = info.planLine {
          Text(plan)
            .font(.ns(.subheadline, .bold))
            .foregroundStyle(NS.onFill)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: NS.tap, alignment: .leading)
      .background(NS.red)
      .overlay(Rectangle().strokeBorder(NS.textPrimary.opacity(pulse ? 0.9 : 0), lineWidth: 3))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Alert. \(info.spokenHeadline). \(info.planLine ?? "")")
    .accessibilityHint("Shows the countdown and Acknowledge")
  }

  private func slimStrip(_ info: DangerInfo) -> some View {
    Button {
      showDetail = true
    } label: {
      Text("// ALERT ACKNOWLEDGED · \(info.facilityName.uppercased())")
        .font(.nsMono(.caption2, .bold))
        .foregroundStyle(NS.onFill)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(NS.red)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Alert acknowledged at \(info.facilityName). Still active. Shows details.")
  }

  /// Strong haptic once per alarm, and three border pulses.
  private func announce(_ alarm: AlarmStatus) {
    let id = AlarmMonitor.identity(of: alarm)
    guard announcedID != id else { return }
    announcedID = id
    guard !controller.alarm.isBackendAlarmAcknowledged else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.error)
    guard !reduceMotion else { return }
    Task {
      for _ in 0..<3 {
        withAnimation(.easeInOut(duration: 0.3)) { pulse = true }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.easeInOut(duration: 0.3)) { pulse = false }
        try? await Task.sleep(for: .milliseconds(350))
      }
    }
  }
}

/// What the banner and sheet show, from /alarm plus /map and /alerts (all as received).
struct DangerInfo {
  let facilityName: String
  let hours: Double?
  let plan: String?
  let cost: Double?
  let alarm: AlarmStatus

  @MainActor
  init(alarm: AlarmStatus, controller: NightShiftController) {
    self.alarm = alarm
    let ids = alarm.facilityIds
    let facilities = controller.map?.facilities.filter { ids.contains($0.id) } ?? []
    let first = ids.first
    facilityName = facilities.first?.displayName
      ?? first.flatMap { id in controller.alerts.first { $0.facility == id }?.facilityName }
      ?? first ?? "Facility"
    hours = facilities.compactMap(\.hoursToShutdown).min()
      ?? controller.alerts.filter { ids.contains($0.facility ?? "") }.compactMap(\.hoursToShutdown).min()
    let alert = controller.alerts.first { $0.facility.map(ids.contains) == true && $0.bestPlan != nil }
    plan = alert?.bestPlan
    cost = alert?.cost
  }

  var hoursText: String? {
    hours.map { "\($0.formatted(.number.precision(.fractionLength(1)))) H" }
  }

  var headline: String {
    var text = "// ALERT · \(facilityName.uppercased())"
    if let hoursText { text += " · SHUTDOWN IN \(hoursText)" }
    return text
  }

  var spokenHeadline: String {
    var text = facilityName
    if let hours { text += ", shutdown in \(hours.formatted(.number.precision(.fractionLength(1)))) hours" }
    return text
  }

  var costText: String? {
    cost.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
  }

  /// "Cheapest fix: <plan> · $905", or the first server reason when there's no plan.
  var planLine: String? {
    if let plan {
      return "Cheapest fix: \(plan)" + (costText.map { " · \($0)" } ?? "")
    }
    return alarm.reasons.first
  }
}

/// Countdown, plan and cost, and ACKNOWLEDGE.
private struct DangerDetailSheet: View {
  var controller: NightShiftController
  let info: DangerInfo
  @Environment(\.dismiss) private var dismiss
  /// When this sheet opened; the countdown runs from the server's hours at that moment.
  @State private var openedAt = Date()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("// ALERT")
          .font(.nsDisplay(.largeTitle))
          .foregroundStyle(NS.redText)
          .accessibilityAddTraits(.isHeader)
        SysCard(label: "SYS//ALERT", key: true) {
          Text(info.facilityName)
            .font(.ns(.title2, .bold))
            .foregroundStyle(NS.textPrimary)
          if let hours = info.hours {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              let remaining = max(0, hours * 3600 - context.date.timeIntervalSince(openedAt))
              let seconds = Int(remaining)
              Text(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
                .font(.nsMono(.largeTitle, .bold))
                .foregroundStyle(NS.redText)
                .accessibilityLabel("Shutdown in \(seconds / 3600) hours \(seconds / 60 % 60) minutes")
            }
            Text("UNTIL SHUTDOWN")
              .font(.nsMono(.caption, .semibold))
              .foregroundStyle(NS.textMuted)
          }
          if let headline = info.alarm.headline {
            Text(headline).font(.ns(.body, .semibold)).foregroundStyle(NS.textPrimary)
          }
          ForEach(Array(info.alarm.reasons.enumerated()), id: \.offset) { _, reason in
            Text(reason).font(.ns(.body)).foregroundStyle(NS.textMuted)
          }
        }
        if info.plan != nil || info.cost != nil {
          SysCard(label: "SYS//PLAN") {
            if let plan = info.plan {
              Text("Cheapest fix: \(plan)")
                .font(.ns(.body, .semibold))
                .foregroundStyle(NS.textPrimary)
            }
            if let costText = info.costText {
              Text(costText)
                .font(.nsMono(.title2, .bold))
                .foregroundStyle(NS.textPrimary)
            }
          }
        }
        if controller.alarm.isBackendAlarmAcknowledged {
          Label("Acknowledged. The red strip stays until the alert clears.", systemImage: "checkmark.circle.fill")
            .font(.ns(.body, .semibold))
            .foregroundStyle(NS.green)
        } else {
          FlatButton(title: "Acknowledge", icon: "checkmark.shield.fill", kind: .primary,
                     accessibilityLabel: "Acknowledge the alert at \(info.facilityName)") {
            controller.alarm.acknowledgeBackendAlarm()
            dismiss()
          }
        }
        FlatButton(title: "Close", kind: .secondary) { dismiss() }
      }
      .padding(16)
    }
    .background(NS.background)
  }
}
