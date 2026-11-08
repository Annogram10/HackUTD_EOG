//
// FacilityMapView.swift
//
// GET /map on a map: one pin per facility, numbered by the backend's rank and colored
// by its level, plus a ranked list in the order received (rank 1 = check first). Tap a
// pin or row for the backend's reasons; "Read aloud" speaks its spoken_text as is.
//

import MapKit
import SwiftUI

struct FacilityMapView: View {
  var controller: NightShiftController
  @State private var position: MapCameraPosition = .automatic
  @State private var selected: MapFacility?

  private var facilities: [MapFacility] { controller.map?.facilities ?? [] }

  var body: some View {
    VStack(spacing: 0) {
      Map(position: $position) {
        ForEach(controller.map?.systems ?? []) { system in
          if let yard = coordinate(system.truckYard) {
            Annotation("\(system.id) truck yard", coordinate: yard) {
              siteIcon("box.truck.fill")
            }
          }
          if let site = system.disposalSite, let lat = site.lat, let lon = site.lon {
            Annotation(site.id ?? "\(system.id) disposal", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
              siteIcon("drop.fill")
            }
          }
        }
        ForEach(facilities) { facility in
          if let lat = facility.lat, let lon = facility.lon {
            Annotation(facility.displayName, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
              Button {
                selected = facility
              } label: {
                pin(for: facility)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .mapStyle(.standard(pointsOfInterest: .excludingAll))
      .frame(minHeight: 280)

      List {
        Section {
          if let error = controller.mapError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.red)
          }
          if facilities.isEmpty {
            Text(controller.isLoadingMap ? "Loading map…" : "No map data yet. Tap Refresh.")
              .foregroundStyle(.secondary)
          }
          // Backend order: already ranked by importance.
          ForEach(facilities) { facility in
            Button {
              selected = facility
            } label: {
              row(for: facility)
            }
            .buttonStyle(.plain)
          }
        } header: {
          Text("Check first")
        } footer: {
          if let asOf = controller.map?.asOf {
            Text("Data as of \(asOf)\(controller.map?.dataset.map { " · \($0)" } ?? "")")
          }
        }
      }
      .listStyle(.plain)
    }
    .navigationTitle("Map")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") {
        Task { await controller.refreshMap() }
      }
      .disabled(controller.isLoadingMap)
    }
    .task { await controller.refreshMap() }
    .sheet(item: $selected) { facility in
      FacilityDetailCard(facility: facility, controller: controller)
        .presentationDetents([.medium, .large])
    }
  }

  // MARK: - Pieces

  private func coordinate(_ pair: [Double]?) -> CLLocationCoordinate2D? {
    guard let pair, pair.count == 2 else { return nil }
    return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
  }

  private func pin(for facility: MapFacility) -> some View {
    ZStack {
      Circle()
        .fill(Self.color(for: facility.level))
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .shadow(radius: 2)
      Text(facility.rank.map(String.init) ?? "·")
        .font(.caption.bold())
        .foregroundStyle(.white)
    }
    .accessibilityLabel("Rank \(facility.rank.map(String.init) ?? "unknown"), \(facility.displayName), \(facility.level ?? "unknown") importance")
  }

  private func siteIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.caption2)
      .foregroundStyle(.white)
      .padding(5)
      .background(.gray, in: Circle())
  }

  private func row(for facility: MapFacility) -> some View {
    HStack(spacing: 12) {
      pin(for: facility)
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(facility.displayName)
            .font(.subheadline.bold())
          if facility.id == controller.currentFacilityID {
            Text("I'm here")
              .font(.caption2)
              .padding(.horizontal, 5)
              .background(.blue.opacity(0.2), in: Capsule())
          }
        }
        Text([facility.status, facility.level.map { "\($0) importance" }].compactMap { $0 }.joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let reason = facility.reasons.first {
          Text(reason)
            .font(.caption)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
  }

  /// Pin color from the backend's level: high red, medium amber, low grey, none green.
  static func color(for level: String?) -> Color {
    switch level {
    case "high": return .red
    case "medium": return .orange
    case "none": return .green
    default: return .gray
    }
  }
}

/// Detail card for one facility: the backend's status, reasons and spoken text.
private struct FacilityDetailCard: View {
  let facility: MapFacility
  var controller: NightShiftController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent("Rank", value: facility.rank.map(String.init) ?? "—")
          LabeledContent("Level", value: facility.level ?? "—")
          LabeledContent("Status", value: facility.status ?? "—")
          if let hours = facility.hoursToShutdown {
            LabeledContent("Hours to shutdown", value: String(hours))
          }
          LabeledContent("Facility id", value: facility.id)
        }
        Section("Why") {
          if facility.reasons.isEmpty {
            Text("Nothing wrong.")
              .foregroundStyle(.secondary)
          }
          ForEach(Array(facility.reasons.enumerated()), id: \.offset) { _, reason in
            Text(reason)
          }
        }
        Section {
          if let text = facility.spokenText {
            Button("Read aloud", systemImage: "speaker.wave.2") {
              Task { await Speaker.shared.speak(text) }
            }
          }
          Button("I'm at this facility", systemImage: "mappin.and.ellipse") {
            controller.setCurrentFacility(facility.id)
            dismiss()
          }
          .disabled(facility.id == controller.currentFacilityID)
        }
      }
      .navigationTitle(facility.displayName)
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}
