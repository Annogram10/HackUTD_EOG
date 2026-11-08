//
// ShiftTabView.swift
//
// SHIFT tab, top to bottom: shift status (START / END SHIFT), briefing, priorities
// (ranked, with a link to the full map), alerts (current alarm, link to Alerts &
// History), flags (summary + list; tap reopens the flag card), and upload status.
// End shift shows the handover summary first, then uploads. Backend text is shown as
// received; ranking is the backend's order.
//

import SwiftUI

struct ShiftTabView: View {
  var controller: NightShiftController
  @AppStorage(Config.Keys.operatorName) private var operatorName = ""
  @State private var showEndShift = false
  @State private var selectedFacility: MapFacility?
  @State private var openFlagID: Flag.ID?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("SHIFT")
            .font(.nsDisplay(.title2))
            .foregroundStyle(NS.textPrimary)
            .accessibilityAddTraits(.isHeader)
          statusCard
          if controller.isOnShift, controller.handoff?.text != nil || controller.handoff?.spokenText != nil {
            briefingCard
          }
          prioritiesCard
          alertsCard
          flagsCard
          uploadCard
        }
        .padding(16)
      }
      .background(NS.background)
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: ShiftRoute.self) { route in
        switch route {
        case .map:
          MapTabView(controller: controller)
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
        case .alerts:
          AlertsView(controller: controller, alarmActive: controller.alarm.backendStatus?.alarm == true)
            .navigationBarTitleDisplayMode(.inline)
        }
      }
    }
    .sheet(item: $selectedFacility) { facility in
      FacilityDetailSheet(facility: facility, controller: controller)
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showEndShift) {
      EndShiftSheet(controller: controller)
        .presentationDetents([.large])
    }
    .sheet(isPresented: Binding(get: { openFlagID != nil }, set: { if !$0 { openFlagID = nil } })) {
      if let openFlagID {
        ScrollView {
          FlagCardView(controller: controller, flagID: openFlagID) { self.openFlagID = nil }
            .padding(16)
        }
        .background(NS.background)
        .presentationDetents([.medium, .large])
      }
    }
  }

  enum ShiftRoute: Hashable { case map, alerts }

  // MARK: - Status

  private var statusCard: some View {
    SysCard(label: "SYS//SHIFT", key: controller.isOnShift) {
      if controller.isOnShift, let shift = controller.store.current {
        Text("ON SHIFT · started \(shift.startText)")
          .font(.ns(.title3, .bold))
          .foregroundStyle(NS.green)
        // Elapsed time on the phone's clock.
        ShiftTimer(start: shift.startedAt)
        if controller.isPlayingBriefing {
          FlatButton(title: "Skip briefing", icon: "forward.end.fill", kind: .secondary,
                     accessibilityLabel: "Skip the briefing") {
            controller.skipBriefing()
          }
        }
      } else if controller.unfinishedShiftStart != nil, let shift = controller.store.current {
        Text("SHIFT LEFT OPEN · since \(shift.startText)")
          .font(.ns(.title3, .bold))
          .foregroundStyle(NS.amber)
      } else {
        Text("SHIFT NOT STARTED")
          .font(.ns(.title3, .bold))
          .foregroundStyle(NS.textMuted)
      }
      HStack(spacing: 6) {
        Text("OPERATOR").font(.nsMono(.caption, .semibold)).foregroundStyle(NS.textSecondary)
        Text(operatorName.isEmpty ? "Not set (Settings)" : operatorName)
          .font(.ns(.body, .semibold))
          .foregroundStyle(operatorName.isEmpty ? NS.textMuted : NS.textPrimary)
      }
      .accessibilityElement(children: .combine)
      if controller.isOnShift {
        FlatButton(title: "End shift", icon: "moon.zzz.fill", kind: .danger) { showEndShift = true }
      } else if controller.unfinishedShiftStart != nil {
        AdaptiveStack(spacing: 10) {
          FlatButton(title: "Continue shift", icon: "play.fill", kind: .primary) {
            Task { await controller.resumeShift() }
          }
          FlatButton(title: "End shift", icon: "moon.zzz.fill", kind: .danger) { showEndShift = true }
        }
      } else {
        FlatButton(title: "Start shift", icon: "sunset.fill", kind: .primary) {
          Task { await controller.startShift() }
        }
      }
    }
  }

  // MARK: - Briefing

  private var briefingCard: some View {
    SysCard(label: "SYS//BRIEFING") {
      Text(controller.handoff?.text ?? controller.handoff?.spokenText ?? "")
        .font(.ns(.body))
        .foregroundStyle(NS.textPrimary)
      FlatButton(title: "Play again", icon: "play.circle", kind: .secondary,
                 accessibilityLabel: "Play the briefing again") {
        if let text = controller.handoff?.spokenText {
          Task { await Speaker.shared.speak(text) }
        }
      }
      .disabled(controller.handoff?.spokenText == nil)
    }
  }

  // MARK: - Priorities

  private var routeFacilities: [MapFacility] {
    (controller.map?.facilities ?? []).filter(\.needsCheck)
  }

  private var prioritiesCard: some View {
    SysCard(label: "SYS//PRIORITIES") {
      if controller.map == nil {
        StateCard(
          title: controller.mapError == nil ? "Loading…" : "Can't reach the console",
          detail: controller.mapError == nil ? nil : "Everything is saved on the phone and will upload later.",
          icon: controller.mapError == nil ? "hourglass" : "wifi.slash",
          tone: controller.mapError == nil ? .grey : .amber,
          actionTitle: controller.mapError == nil ? nil : "Retry now"
        ) {
          Task { await controller.refreshMap() }
        }
      } else if routeFacilities.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("GRID STABLE")
            .font(.nsDisplay(.title2))
            .foregroundStyle(NS.green)
          Text("No problems in progress.")
            .font(.ns(.body))
            .foregroundStyle(NS.textMuted)
        }
        .accessibilityElement(children: .combine)
      } else {
        if controller.mapError != nil {
          Badge(text: "Stale — last good data", tone: .amber, icon: "clock.badge.exclamationmark")
        }
        ForEach(routeFacilities) { facility in
          priorityRow(facility)
          if facility.id != routeFacilities.last?.id {
            Rectangle().fill(NS.hud.opacity(0.4)).frame(height: 1)
          }
        }
      }
      NavigationLink(value: ShiftRoute.map) {
        Label("Open map", systemImage: "map")
          .font(.ns(.headline, .bold))
          .textCase(.uppercase)
          .foregroundStyle(NS.accent)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .accessibilityLabel("Open the full map with the route")
    }
  }

  private func priorityRow(_ facility: MapFacility) -> some View {
    Button {
      Haptics.tap()
      selectedFacility = facility
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Text(facility.rank.map(String.init) ?? "–")
          .font(.nsMono(.title, .bold))
          .foregroundStyle(NS.textMuted)
          .frame(minWidth: 40, alignment: .leading)
        VStack(alignment: .leading, spacing: 6) {
          Text(facility.displayName)
            .font(.ns(.title3, .bold))
            .foregroundStyle(NS.textPrimary)
          AdaptiveStack(spacing: 6, stackedAlignment: .leading) {
            LevelBadge(level: facility.severityKey)
            StatusBadge(status: facility.status)
            if controller.todo.done[facility.id] != nil {
              Badge(text: "Done", tone: .green, icon: "checkmark")
            }
          }
          if let reason = facility.reasons.first {
            Text(reason)
              .font(.ns(.subheadline))
              .foregroundStyle(NS.textMuted)
              .lineLimit(1)
          }
          if let hours = facility.hoursToShutdown {
            Text(hoursLeftText(hours))
              .font(.nsMono(.subheadline, .bold))
              .foregroundStyle(NS.redText)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: NS.tap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Shows details")
  }

  // MARK: - Alerts (folded in from the old Alerts tab)

  private var alertsCard: some View {
    SysCard(label: "SYS//ALERT", key: controller.alarm.backendStatus?.alarm == true) {
      if let alarm = controller.alarm.backendStatus, alarm.alarm {
        HStack(spacing: 6) {
          LevelBadge(level: alarm.severityKey)
          if controller.alarm.isBackendAlarmAcknowledged {
            Badge(text: "Acknowledged", tone: .grey)
          }
        }
        Text(alarm.headline ?? "Alarm")
          .font(.ns(.title3, .bold))
          .foregroundStyle(NS.textPrimary)
      } else if controller.alarm.monitoringLost {
        Text("Can't reach the console. Everything is saved on the phone and will upload later.")
          .font(.ns(.body, .semibold))
          .foregroundStyle(NS.amber)
      } else {
        Text("No active alerts.")
          .font(.ns(.body))
          .foregroundStyle(NS.textMuted)
      }
      NavigationLink(value: ShiftRoute.alerts) {
        Label("Alerts and history", systemImage: "bell")
          .font(.ns(.headline, .bold))
          .textCase(.uppercase)
          .foregroundStyle(NS.accent)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .accessibilityLabel("Open alerts and alert history")
    }
  }

  // MARK: - Flags

  private var flags: [Flag] { (controller.store.current?.flags ?? []).reversed() }

  private var flagSummary: String {
    let all = controller.store.current?.flags ?? []
    let confirmed = all.count(where: { $0.status == .confirmed })
    let waiting = all.count(where: { $0.status == .pending })
    let dismissed = all.count(where: { $0.status == .dismissed })
    return "\(all.count) FLAG\(all.count == 1 ? "" : "S") · \(confirmed) CONFIRMED · \(waiting) WAITING · \(dismissed) DISMISSED"
  }

  private var flagsCard: some View {
    SysCard(label: "SYS//FLAGS") {
      if flags.isEmpty {
        Text("Quiet night, choom. Flags show up here when the glasses spot something.")
          .font(.ns(.body))
          .foregroundStyle(NS.textMuted)
      } else {
        Text(flagSummary)
          .font(.nsMono(.footnote, .semibold))
          .foregroundStyle(NS.textSecondary)
        ForEach(flags) { flag in
          flagRow(flag)
        }
      }
    }
  }

  private func flagRow(_ flag: Flag) -> some View {
    let place = flag.facility.flatMap { id in controller.map?.facilities.first { $0.id == id }?.displayName } ?? flag.facility ?? "Unknown facility"
    return Button {
      Haptics.tap()
      openFlagID = flag.id
    } label: {
      HStack(alignment: .top, spacing: 12) {
        thumbnail(flag)
        VStack(alignment: .leading, spacing: 4) {
          Text("Possible \(flag.type)")
            .font(.ns(.headline, .bold))
            .foregroundStyle(NS.textPrimary)
          Text(place)
            .font(.ns(.subheadline))
            .foregroundStyle(NS.textMuted)
          AdaptiveStack(spacing: 6, stackedAlignment: .leading) {
            Badge(text: flagStatusText(flag), tone: flagTone(flag))
            Badge(text: flag.source == "voice" ? "Voice" : "Camera", tone: .blue)
            Text(flag.timeText)
              .font(.nsMono(.caption))
              .foregroundStyle(NS.textMuted)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: NS.tap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Opens the flag card")
  }

  @ViewBuilder
  private func thumbnail(_ flag: Flag) -> some View {
    if let shift = controller.store.current, let url = controller.store.photoURL(for: flag, in: shift) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Rectangle().fill(NS.raised)
      }
      .frame(width: 56, height: 56)
      .clipShape(ChamferedRect(chamfer: 6))
      .accessibilityHidden(true)
    } else {
      Image(systemName: flag.source == "voice" ? "mic.fill" : "camera.fill")
        .foregroundStyle(NS.textMuted)
        .frame(width: 56, height: 56)
        .background(NS.raised, in: ChamferedRect(chamfer: 6))
        .accessibilityHidden(true)
    }
  }

  private func flagStatusText(_ flag: Flag) -> String {
    if flag.priority == true { return "Prioritized" }
    switch flag.status {
    case .pending: return "Waiting"
    case .confirmed: return "Confirmed"
    case .dismissed: return "Dismissed"
    }
  }

  private func flagTone(_ flag: Flag) -> Tone {
    switch flag.status {
    case .pending: return .amber
    case .confirmed: return .red
    case .dismissed: return .grey
    }
  }

  // MARK: - Uploads

  private var uploadCard: some View {
    let (text, tone) = uploadState
    return SysCard(label: "SYS//UPLOAD") {
      Label(text, systemImage: tone == .green ? "checkmark.circle.fill" : (tone == .grey ? "tray" : "arrow.triangle.2.circlepath"))
        .font(.nsMono(.subheadline, .bold))
        .foregroundStyle(tone.text)
      ForEach(controller.uploads.entries.prefix(3)) { entry in
        ReportStateRow(entry: entry) { controller.uploads.retry(entry.id) }
      }
      if controller.uploads.pendingCount > 0 {
        FlatButton(title: "Retry now", icon: "arrow.clockwise", kind: .secondary) {
          Task { await controller.uploads.drain() }
        }
      }
    }
  }

  /// UPLOADED <time> (green), QUEUED · RETRYING or OFFLINE · SAVED ON PHONE (orange).
  private var uploadState: (String, Tone) {
    if controller.uploads.pendingCount > 0 {
      let offline = !NetworkMonitor.shared.isConnected || controller.isBackendReachable == false
      return (offline ? "OFFLINE · SAVED ON PHONE" : "QUEUED · RETRYING", .amber)
    }
    if let sent = controller.uploads.entries.first(where: { if case .sent = $0.state { return true } else { return false } }),
      case .sent(let at) = sent.state
    {
      return ("UPLOADED \(at.formatted(date: .omitted, time: .shortened))", .green)
    }
    return ("NOTHING TO UPLOAD YET", .grey)
  }
}

/// Elapsed shift time, monospaced so it doesn't jitter.
struct ShiftTimer: View {
  let start: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let seconds = max(0, Int(context.date.timeIntervalSince(start)))
      Text(String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
        .font(.nsMono(.title, .bold))
        .foregroundStyle(NS.textPrimary)
        .accessibilityLabel("Shift time \(seconds / 3600) hours \(seconds / 60 % 60) minutes")
    }
  }
}

/// End shift: the spoken handover summary as text, a handover note, then the existing
/// end logic (which uploads the report).
struct EndShiftSheet: View {
  var controller: NightShiftController
  @Environment(\.dismiss) private var dismiss
  @State private var note = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("END SHIFT")
          .font(.nsDisplay(.title2))
          .foregroundStyle(NS.textPrimary)
          .accessibilityAddTraits(.isHeader)
        SysCard(label: "SYS//HANDOVER", key: true) {
          Text(NightShiftController.endOfShiftSummary(for: controller.store.current?.flags ?? []))
            .font(.ns(.body))
            .foregroundStyle(NS.textPrimary)
        }
        HudLabel(text: "Handover note")
        TextField("Anything the next shift should know", text: $note, axis: .vertical)
          .lineLimit(3...6)
          .font(.ns(.body))
          .foregroundStyle(NS.textPrimary)
          .padding(12)
          .frame(minHeight: NS.tap)
          .flatCard(fill: NS.raised, stroke: NS.border)
          .accessibilityLabel("Handover note")
        FlatButton(title: "End shift and upload", icon: "paperplane.fill", kind: .primary) {
          let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty {
            controller.store.addNote("Handover: \(text)", to: nil)
          }
          dismiss()
          Task { await controller.endShift() }
        }
        FlatButton(title: "Cancel", kind: .secondary) { dismiss() }
      }
      .padding(16)
    }
    .background(NS.background)
  }
}
