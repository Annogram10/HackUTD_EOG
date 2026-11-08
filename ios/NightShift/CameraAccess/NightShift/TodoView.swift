//
// TodoView.swift
//
// To-do tab (home): one ranked list for the shift, built from existing data only, in
// this order:
//   Do now      active alarm, rank 1 and high-level facilities, pending flags
//   Check soon  medium-level facilities, in route order
//   Routine     the other route stops with importance > 0
//   Done        facilities marked done and flags decided this shift (collapsed)
// Facility order is always the backend's rank order; nothing is re-ranked here.
//

import SwiftUI

struct TodoView: View {
  var controller: NightShiftController
  let glassesConnected: Bool
  let alarmActive: Bool
  @State private var selected: MapFacility?
  @State private var showDone = false
  @State private var showEndShift = false
  @State private var alarmError: String?
  @State private var isDecidingAlarm = false

  // MARK: - Sections

  private var routeFacilities: [MapFacility] {
    (controller.map?.facilities ?? []).filter(\.needsCheck)
  }

  private var openFacilities: [MapFacility] {
    routeFacilities.filter { controller.todo.done[$0.id] == nil }
  }

  private var doNowFacilities: [MapFacility] {
    openFacilities.filter { $0.rank == 1 || levelTone($0.severityKey) == .red }
  }

  private var checkSoonFacilities: [MapFacility] {
    let doNow = Set(doNowFacilities.map(\.id))
    return openFacilities.filter { !doNow.contains($0.id) && levelTone($0.severityKey) == .amber }
  }

  private var routineFacilities: [MapFacility] {
    let taken = Set((doNowFacilities + checkSoonFacilities).map(\.id))
    return openFacilities.filter { !taken.contains($0.id) }
  }

  private var doneFacilities: [MapFacility] {
    routeFacilities.filter { controller.todo.done[$0.id] != nil }
  }

  private var pendingFlags: [Flag] {
    (controller.store.current?.flags ?? []).filter { $0.status == .pending }.reversed()
  }

  private var decidedFlags: [Flag] {
    (controller.store.current?.flags ?? []).filter { $0.status != .pending }.reversed()
  }

  /// The backend alarm, while it's on and not yet acknowledged on this phone.
  private var openAlarm: AlarmStatus? {
    guard let status = controller.alarm.backendStatus, status.alarm, !controller.alarm.isBackendAlarmAcknowledged else { return nil }
    return status
  }

  private var isEmpty: Bool {
    openAlarm == nil && openFacilities.isEmpty && pendingFlags.isEmpty
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if isEmpty {
            Text("Nothing needs checking right now.")
              .font(.title3.weight(.semibold))
              .foregroundStyle(NS.textBody)
              .frame(maxWidth: .infinity, minHeight: 120)
              .flatCard()
          }

          if openAlarm != nil || !doNowFacilities.isEmpty || !pendingFlags.isEmpty {
            sectionHeader("Do now", tone: .red)
            if let alarm = openAlarm {
              alarmRow(alarm)
            }
            ForEach(doNowFacilities) { facilityRow($0) }
            ForEach(pendingFlags) { flagRow($0) }
          }
          if !checkSoonFacilities.isEmpty {
            sectionHeader("Check soon", tone: .amber)
            ForEach(checkSoonFacilities) { facilityRow($0) }
          }
          if !routineFacilities.isEmpty {
            sectionHeader("Routine", tone: .grey)
            ForEach(routineFacilities) { facilityRow($0) }
          }
          if !doneFacilities.isEmpty || !decidedFlags.isEmpty {
            doneSection
          }
        }
        .padding(16)
      }
    }
    .background(NS.background)
    .sheet(item: $selected) { facility in
      FacilityDetailSheet(facility: facility, controller: controller)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(0)
    }
    .sheet(isPresented: $showEndShift) {
      EndShiftSheet(controller: controller)
        .presentationDetents([.large])
        .presentationCornerRadius(0)
    }
  }

  // MARK: - Header

  private var header: some View {
    HeaderStrip(alarmActive: alarmActive) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Text("NightShift")
            .font(.title2.bold())
            .foregroundStyle(NS.textPrimary)
            .accessibilityAddTraits(.isHeader)
          HStack(spacing: 6) {
            Rectangle()
              .fill(glassesConnected ? NS.green : NS.textMuted)
              .frame(width: 10, height: 10)
            Text(glassesConnected ? "Glasses" : "No glasses")
              .font(.subheadline)
              .foregroundStyle(NS.textSecondary)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(glassesConnected ? "Glasses connected" : "Glasses not connected")
          Spacer()
          if let start = controller.store.current?.startedAt, controller.isOnShift {
            ShiftTimer(start: start)
          }
        }
        HStack(spacing: 10) {
          shiftButton
          FlatButton(title: "Read aloud", icon: "speaker.wave.2.fill",
                     accessibilityLabel: "Read aloud what to check first") {
            if let text = controller.map?.facilities.first?.spokenText {
              Task { await Speaker.shared.speak(text) }
            }
          }
          .disabled(controller.map?.facilities.first?.spokenText == nil)
        }
      }
    }
  }

  @ViewBuilder
  private var shiftButton: some View {
    if controller.isOnShift {
      FlatButton(title: "End shift", icon: "moon.zzz.fill", kind: .danger) {
        showEndShift = true
      }
    } else if controller.unfinishedShiftStart != nil {
      FlatButton(title: "Continue shift", icon: "play.fill", kind: .primary,
                 accessibilityLabel: "Continue the shift you started earlier") {
        Task { await controller.resumeShift() }
      }
    } else {
      FlatButton(title: "Start shift", icon: "sunset.fill", kind: .primary) {
        Task { await controller.startShift() }
      }
    }
  }

  // MARK: - Rows

  private func sectionHeader(_ title: String, tone: Tone) -> some View {
    HStack(spacing: 8) {
      Rectangle().fill(tone.color).frame(width: 3, height: 18)
      Text(title.uppercased())
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(NS.textSecondary)
    }
    .padding(.top, 8)
    .accessibilityAddTraits(.isHeader)
  }

  private func facilityRow(_ facility: MapFacility) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        Haptics.tap()
        selected = facility
      } label: {
        HStack(alignment: .top, spacing: 12) {
          Text(facility.rank.map(String.init) ?? "–")
            .font(.title.bold().monospacedDigit())
            .foregroundStyle(NS.textMuted)
            .frame(minWidth: 36, alignment: .leading)
          VStack(alignment: .leading, spacing: 6) {
            Text(facility.displayName)
              .font(.title3.weight(.semibold))
              .foregroundStyle(NS.textPrimary)
            HStack(spacing: 6) {
              LevelBadge(level: facility.severityKey)
              StatusBadge(status: facility.status)
              if controller.todo.here[facility.id] != nil {
                Badge(text: "Visited", tone: .blue)
              }
            }
            if let reason = facility.reasons.first {
              Text(reason)
                .font(.subheadline)
                .foregroundStyle(NS.textBody)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            }
            if let hours = facility.hoursToShutdown {
              Text(hoursLeftText(hours))
                .font(.headline.monospacedDigit())
                .foregroundStyle(NS.redText)
            }
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityHint("Shows details")

      HStack(spacing: 10) {
        FlatButton(title: "I'm here", icon: "mappin.and.ellipse",
                   accessibilityLabel: "I'm here at \(facility.displayName)") {
          controller.markHere(facility.id)
        }
        FlatButton(title: "Done", icon: "checkmark",
                   accessibilityLabel: "Mark \(facility.displayName) done") {
          controller.markDone(facility.id)
        }
      }
    }
    .padding(12)
    .flatCard()
  }

  private func flagRow(_ flag: Flag) -> some View {
    let place = flag.facility.flatMap { id in controller.map?.facilities.first { $0.id == id }?.displayName } ?? flag.facility ?? "Unknown place"
    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: flag.source == "voice" ? "mic.fill" : "camera.fill")
          .font(.title3)
          .foregroundStyle(NS.amberText)
          .frame(minWidth: 36, alignment: .leading)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          Text("Possible \(flag.type) at \(place)")
            .font(.title3.weight(.semibold))
            .foregroundStyle(NS.textPrimary)
          HStack(spacing: 6) {
            Badge(text: "NEEDS REVIEW", tone: .amber, icon: "exclamationmark.triangle.fill")
            Badge(text: flag.source == "voice" ? "Voice" : "Camera", tone: .grey)
          }
          if let description = flag.description {
            Text(description).font(.subheadline).foregroundStyle(NS.textBody)
          }
          Text(flag.createdAt.formatted(date: .omitted, time: .shortened))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(NS.textSecondary)
        }
      }
      .accessibilityElement(children: .combine)
      HStack(spacing: 10) {
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

  private func alarmRow(_ alarm: AlarmStatus) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Badge(text: "ALARM", tone: .red, icon: "exclamationmark.triangle.fill")
        LevelBadge(level: alarm.severityKey)
      }
      Text(alarm.headline ?? "Alarm")
        .font(.title3.weight(.semibold))
        .foregroundStyle(NS.textPrimary)
      if let reason = alarm.reasons.first {
        Text(reason).font(.subheadline).foregroundStyle(NS.textBody)
      }
      if let error = alarmError {
        Text(error).font(.subheadline).foregroundStyle(NS.redText)
      }
      HStack(spacing: 10) {
        FlatButton(title: "Dismiss", icon: "xmark", accessibilityLabel: "Dismiss the alarm") {
          decideAlarm(.dismiss)
        }
        FlatButton(title: "Prioritize", icon: "exclamationmark.2", kind: .warning, accessibilityLabel: "Prioritize the alarm") {
          decideAlarm(.prioritize)
        }
      }
      .disabled(isDecidingAlarm)
    }
    .padding(12)
    .flatCard(fill: NS.red.opacity(0.12), stroke: NS.red.opacity(0.5))
  }

  private func decideAlarm(_ action: FlagAction) {
    isDecidingAlarm = true
    Task {
      alarmError = await controller.decideCurrentAlarm(action)
      isDecidingAlarm = false
    }
  }

  private var doneSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        Haptics.tap()
        showDone.toggle()
      } label: {
        HStack {
          sectionHeader("Done (\(doneFacilities.count + decidedFlags.count))", tone: .green)
          Spacer()
          Image(systemName: showDone ? "chevron.up" : "chevron.down")
            .foregroundStyle(NS.accent)
        }
        .frame(minHeight: NS.tap)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(showDone ? "Hide done items" : "Show done items")
      if showDone {
        ForEach(doneFacilities) { facility in
          HStack {
            Text(facility.displayName).font(.body).foregroundStyle(NS.textBody)
            Spacer()
            FlatButton(title: "Undo", accessibilityLabel: "Mark \(facility.displayName) not done") {
              controller.undoDone(facility.id)
            }
            .frame(width: 100)
          }
          .padding(.leading, 12)
          .flatCard()
        }
        ForEach(decidedFlags) { flag in
          HStack {
            Text("Possible \(flag.type)").font(.body).foregroundStyle(NS.textBody)
            Spacer()
            Badge(text: flag.priority == true ? "Prioritized" : flag.status.rawValue.capitalized,
                  tone: flag.status == .dismissed ? .grey : .green)
          }
          .padding(12)
          .frame(minHeight: NS.tap)
          .flatCard()
        }
      }
    }
  }
}

/// Elapsed shift time, monospaced so it doesn't jitter.
struct ShiftTimer: View {
  let start: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let seconds = max(0, Int(context.date.timeIntervalSince(start)))
      Text(String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
        .font(.headline.monospacedDigit())
        .foregroundStyle(NS.textBody)
        .accessibilityLabel("Shift time \(seconds / 3600) hours \(seconds / 60 % 60) minutes")
    }
  }
}

/// End shift: the app-built flag summary, a handover note, then the existing end logic.
struct EndShiftSheet: View {
  var controller: NightShiftController
  @Environment(\.dismiss) private var dismiss
  @State private var note = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("End shift")
        .font(.title2.bold())
        .foregroundStyle(NS.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(NightShiftController.endOfShiftSummary(for: controller.store.current?.flags ?? []))
        .font(.body)
        .foregroundStyle(NS.textBody)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
      Text("Handover note")
        .font(.headline)
        .foregroundStyle(NS.textSecondary)
      TextField("Anything the next shift should know", text: $note, axis: .vertical)
        .lineLimit(3...6)
        .font(.body)
        .foregroundStyle(NS.textPrimary)
        .padding(12)
        .frame(minHeight: NS.tap)
        .flatCard(fill: NS.raised, stroke: NS.borderStrong)
        .accessibilityLabel("Handover note")
      Spacer()
      FlatButton(title: "End shift and send report", icon: "paperplane.fill", kind: .danger) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          controller.store.addNote("Handover: \(text)", to: nil)
        }
        dismiss()
        Task { await controller.endShift() }
      }
      FlatButton(title: "Cancel") { dismiss() }
    }
    .padding(16)
    .background(NS.background)
  }
}
