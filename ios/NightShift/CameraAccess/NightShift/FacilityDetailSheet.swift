//
// FacilityDetailSheet.swift
//
// Shared detail sheet (To-do and Map tabs): every backend reason as received, hours to
// shutdown, the tank level from GET /facility/{id} when present, Read aloud (spoken_text
// exactly as received), Open in Apple Maps, I'm here, and Done.
//

import MapKit
import SwiftUI

struct FacilityDetailSheet: View {
  let facility: MapFacility
  var controller: NightShiftController
  @Environment(\.dismiss) private var dismiss
  @State private var status: FacilityStatus?

  /// The tank warning level isn't sent by the backend; until it is, warn at 85% of the
  /// shutdown limit (stub).
  private static let warningFraction = 0.85

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          Text(facility.rank.map(String.init) ?? "–")
            .font(.largeTitle.bold().monospacedDigit())
            .foregroundStyle(NS.textMuted)
            .accessibilityLabel("Visit order \(facility.rank.map(String.init) ?? "unknown")")
          Text(facility.displayName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(NS.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
        HStack(spacing: 8) {
          LevelBadge(level: facility.level)
          StatusBadge(status: facility.status)
          if controller.todo.done[facility.id] != nil {
            Badge(text: "Done", tone: .green, icon: "checkmark")
          } else if controller.todo.here[facility.id] != nil {
            Badge(text: "Visited", tone: .blue)
          }
        }
        if let hours = facility.hoursToShutdown {
          Text(hoursLeftText(hours))
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(NS.redText)
            .accessibilityLabel("\(hoursLeftText(hours)) before shutdown")
        }

        if let tank = status?.tankLevel, let value = tank.value, let limit = tank.limit, limit > 0 {
          TankBar(value: value, limit: limit, warning: limit * Self.warningFraction, unit: tank.unit ?? "%")
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("Why")
            .font(.headline)
            .foregroundStyle(NS.textSecondary)
          if facility.reasons.isEmpty {
            Text("Nothing wrong.")
              .font(.body)
              .foregroundStyle(NS.textBody)
          }
          ForEach(Array(facility.reasons.enumerated()), id: \.offset) { _, reason in
            Text(reason)
              .font(.body)
              .foregroundStyle(NS.textBody)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .flatCard()
          }
        }

        VStack(spacing: 10) {
          FlatButton(title: "Read aloud", icon: "speaker.wave.2.fill", kind: .primary,
                     accessibilityLabel: "Read aloud what's wrong at \(facility.displayName)") {
            if let text = facility.spokenText {
              Task { await Speaker.shared.speak(text) }
            }
          }
          .disabled(facility.spokenText == nil)
          HStack(spacing: 10) {
            FlatButton(title: "I'm here", icon: "mappin.and.ellipse",
                       accessibilityLabel: "I'm here at \(facility.displayName)") {
              controller.markHere(facility.id)
            }
            FlatButton(title: controller.todo.done[facility.id] == nil ? "Done" : "Not done",
                       icon: "checkmark",
                       accessibilityLabel: controller.todo.done[facility.id] == nil
                         ? "Mark \(facility.displayName) done" : "Mark \(facility.displayName) not done") {
              if controller.todo.done[facility.id] == nil {
                controller.markDone(facility.id)
                dismiss()
              } else {
                controller.undoDone(facility.id)
              }
            }
          }
          FlatButton(title: "Open in Apple Maps", icon: "map",
                     accessibilityLabel: "Open \(facility.displayName) in Apple Maps") {
            openInMaps()
          }
          .disabled(facility.coordinate == nil)
        }
      }
      .padding(16)
    }
    .background(NS.background)
    .task {
      status = try? await controller.api.fetchFacility(id: facility.id)
    }
  }

  private func openInMaps() {
    guard let coordinate = facility.coordinate else { return }
    let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    item.name = facility.displayName
    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
  }
}

/// Tank level bar: blue normally, amber past the warning level, red at the shutdown
/// level, with a thin light-red tick at the shutdown line.
struct TankBar: View {
  let value: Double
  let limit: Double
  let warning: Double
  let unit: String

  private var tone: Color {
    if value >= limit { return NS.red }
    if value >= warning { return NS.amber }
    return NS.accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Tank level")
          .font(.subheadline)
          .foregroundStyle(NS.textSecondary)
        Spacer()
        Text("\(value.formatted(.number.precision(.fractionLength(0))))\(unit) of \(limit.formatted(.number.precision(.fractionLength(0))))\(unit) shutdown")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(NS.textBody)
      }
      GeometryReader { geo in
        let scale = max(limit * 1.08, value, 1)
        ZStack(alignment: .leading) {
          Rectangle().fill(NS.raised)
          Rectangle().fill(tone).frame(width: geo.size.width * min(value / scale, 1))
          Rectangle()
            .fill(NS.redText)
            .frame(width: 1.5)
            .offset(x: geo.size.width * (limit / scale))
        }
        .overlay(Rectangle().strokeBorder(NS.border, lineWidth: 1))
      }
      .frame(height: 12)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Tank level \(Int(value)) \(unit), shutdown at \(Int(limit)) \(unit)")
  }
}
