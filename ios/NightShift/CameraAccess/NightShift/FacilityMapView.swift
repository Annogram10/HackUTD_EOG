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
  /// The ranked list under the map; collapsed by default on the home screen.
  @Binding var isListExpanded: Bool
  @State private var position: MapCameraPosition = .automatic
  @State private var selected: MapFacility?

  /// Backend order (already ranked), narrowed to the system chosen in Settings.
  /// Never re-sorted.
  private var facilities: [MapFacility] {
    let all = controller.map?.facilities ?? []
    guard let filter = controller.mapSystemFilter else { return all }
    return all.filter { $0.system == filter }
  }

  /// Facilities that need checking, in rank order: the route.
  private var routeStops: [MapFacility] {
    facilities.filter(\.needsCheck)
  }

  private var systems: [MapSystem] {
    let all = controller.map?.systems ?? []
    guard let filter = controller.mapSystemFilter else { return all }
    return all.filter { $0.id == filter }
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
                .accessibilityLabel("\(system.id) truck yard")
            }
          }
          if let site = system.disposalSite, let lat = site.lat, let lon = site.lon {
            Annotation(site.id ?? "\(system.id) disposal", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
              siteIcon("drop.fill")
                .accessibilityLabel("\(system.id) water disposal site")
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
                Group {
                  if facility.needsCheck {
                    pin(for: facility)
                  } else {
                    smallPin(for: facility)
                  }
                }
                // Large invisible tap area around the small drawn pin.
                .frame(minWidth: 56, minHeight: 56)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityHint("Shows details")
            }
          }
        }
      }
      .mapStyle(.standard(pointsOfInterest: .excludingAll))
      // Re-frame the map when the system changes.
      .onChange(of: controller.mapSystemFilter) { position = .automatic }

      if isListExpanded {
        List {
          Section {
            if let error = controller.mapError {
              Label("Couldn't update the map. Showing the last one.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityHint(error)
            }
            if facilities.isEmpty {
              Text(controller.isLoadingMap ? "Loading…" : "Nothing to show yet.")
                .foregroundStyle(.secondary)
            }
            // Backend order: already ranked by importance.
            ForEach(facilities) { facility in
              Button {
                selected = facility
              } label: {
                row(for: facility)
                  .frame(minHeight: 56)
              }
              .buttonStyle(.plain)
              .accessibilityHint("Shows details")
            }
          } header: {
            Text(routeStops.isEmpty ? "Nothing to check" : "Visit in this order: \(routeStops.count) place\(routeStops.count == 1 ? "" : "s")")
          }
        }
        .listStyle(.plain)
        .frame(maxHeight: 320)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isListExpanded)
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
          LabeledContent("Visit order", value: facility.rank.map(String.init) ?? "—")
          LabeledContent("How serious", value: FacilityMapView.levelText(facility.level))
          LabeledContent("Sensor reading", value: facility.status ?? "—")
          if let hours = facility.hoursToShutdown {
            LabeledContent("Hours to shutdown", value: String(hours))
          }
          LabeledContent("ID", value: facility.id)
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
            Button {
              Task { await Speaker.shared.speak(text) }
            } label: {
              Label("Read aloud", systemImage: "speaker.wave.2")
                .frame(minHeight: 56)
            }
          }
          Button {
            controller.setCurrentFacility(facility.id)
            dismiss()
          } label: {
            Label("I'm here now", systemImage: "mappin.and.ellipse")
              .frame(minHeight: 56)
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

extension FacilityMap {
  /// System ids in the order the backend lists them (systems first, then any only
  /// seen on facilities).
  var systemIDs: [String] {
    var seen = Set<String>()
    return (systems.map(\.id) + facilities.compactMap(\.system)).filter { seen.insert($0).inserted }
  }
}
