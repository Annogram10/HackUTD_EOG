//
// FacilityMapView.swift
//
// GET /map on a map. Facilities with importance above 0 get numbered pins (the
// backend's rank) and a route line visiting them in rank order: 1, then 2, then 3.
// Facilities with importance 0 are small grey pins, not on the route. Every pin and
// row shows the level as text (Danger, Check soon, Minor, Normal) as well as color.
// A system picker narrows the view. Tap a pin or row for the backend's reasons;
// "Read aloud" speaks its spoken_text as is.
//

import MapKit
import SwiftUI

struct FacilityMapView: View {
  var controller: NightShiftController
  @State private var position: MapCameraPosition = .automatic
  @State private var selected: MapFacility?
  /// nil = all systems.
  @State private var systemFilter: String?

  /// Backend order (already ranked), narrowed to the chosen system. Never re-sorted.
  private var facilities: [MapFacility] {
    let all = controller.map?.facilities ?? []
    guard let systemFilter else { return all }
    return all.filter { $0.system == systemFilter }
  }

  /// Facilities that need checking, in rank order: the route.
  private var routeStops: [MapFacility] {
    facilities.filter(\.needsCheck)
  }

  private var systems: [MapSystem] {
    let all = controller.map?.systems ?? []
    guard let systemFilter else { return all }
    return all.filter { $0.id == systemFilter }
  }

  /// System ids in the order the backend lists them (systems first, then any only
  /// seen on facilities).
  private var systemIDs: [String] {
    var seen = Set<String>()
    let ids = (controller.map?.systems.map(\.id) ?? []) + (controller.map?.facilities.compactMap(\.system) ?? [])
    return ids.filter { seen.insert($0).inserted }
  }

  private var routeLine: MKPolyline? {
    let coordinates = routeStops.compactMap(\.coordinate)
    guard coordinates.count >= 2 else { return nil }
    return MKPolyline(coordinates: coordinates, count: coordinates.count)
  }

  var body: some View {
    VStack(spacing: 0) {
      Map(position: $position) {
        if let routeLine {
          MapPolyline(routeLine)
            .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [8, 6]))
        }
        ForEach(systems) { system in
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
          if let coordinate = facility.coordinate {
            Annotation(
              facility.needsCheck ? "\(facility.displayName) · \(Self.levelText(facility.level))" : facility.displayName,
              coordinate: coordinate
            ) {
              Button {
                selected = facility
              } label: {
                if facility.needsCheck {
                  pin(for: facility)
                } else {
                  smallPin(for: facility)
                }
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .mapStyle(.standard(pointsOfInterest: .excludingAll))
      .frame(minHeight: 280)
      // Re-frame the map when the system changes.
      .onChange(of: systemFilter) { position = .automatic }

      Picker("System", selection: $systemFilter) {
        Text("All systems").tag(String?.none)
        ForEach(systemIDs, id: \.self) { id in
          Text(id).tag(Optional(id))
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 6)

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
          Text(routeStops.isEmpty ? "Nothing to check" : "Route: \(routeStops.count) stop\(routeStops.count == 1 ? "" : "s") in rank order")
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

  /// Small grey dot for a facility with nothing wrong (not on the route).
  private func smallPin(for facility: MapFacility) -> some View {
    Circle()
      .fill(.gray)
      .frame(width: 12, height: 12)
      .overlay(Circle().stroke(.white, lineWidth: 1.5))
      .accessibilityLabel("\(facility.displayName), \(Self.levelText(facility.level))")
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
    .accessibilityLabel("Rank \(facility.rank.map(String.init) ?? "unknown"), \(facility.displayName), \(Self.levelText(facility.level))")
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
      if facility.needsCheck {
        pin(for: facility)
      } else {
        smallPin(for: facility)
          .frame(width: 28)
      }
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
        HStack(spacing: 6) {
          Text(Self.levelText(facility.level))
            .font(.caption.bold())
            .foregroundStyle(Self.color(for: facility.level))
          if let status = facility.status {
            Text("· \(status)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
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

  /// The level as words, so color is never the only signal.
  static func levelText(_ level: String?) -> String {
    switch level {
    case "high": return "Danger"
    case "medium": return "Check soon"
    case "low": return "Minor"
    case "none": return "Normal"
    default: return "Unknown"
    }
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
          LabeledContent("Level", value: FacilityMapView.levelText(facility.level))
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
            Button("Read out", systemImage: "speaker.wave.2") {
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

extension MapFacility {
  /// On the route: importance above 0.
  var needsCheck: Bool { (importance ?? 0) > 0 }

  var coordinate: CLLocationCoordinate2D? {
    guard let lat, let lon else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }
}
