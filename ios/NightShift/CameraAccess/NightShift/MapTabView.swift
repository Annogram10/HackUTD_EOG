//
// MapTabView.swift
//
// Map tab: GET /map drawn as the dashboard's neon city (CityMapView), one system at a
// time like the dashboard. System chips pick the system; with no choice saved it shows
// the system of the backend's top-ranked facility. "Updated Xs ago", a STALE tag when
// the last refresh failed, and a collapsible legend. Tapping a facility opens its
// detail sheet.
//

import CoreLocation
import SwiftUI

struct MapTabView: View {
  var controller: NightShiftController
  @State private var selected: MapFacility?
  @State private var showLegend = false

  /// The chosen system if it is in the data, else the system of the first facility in
  /// backend order, else the first system.
  private var system: MapSystem? {
    guard let map = controller.map else { return nil }
    if let filter = controller.mapSystemFilter, let chosen = map.systems.first(where: { $0.id == filter }) {
      return chosen
    }
    let top = map.facilities.first?.system
    return map.systems.first { $0.id == top } ?? map.systems.first
  }

  /// Backend order (already ranked), narrowed to the shown system. Never re-sorted.
  private var facilities: [MapFacility] {
    guard let system else { return [] }
    return (controller.map?.facilities ?? []).filter { $0.system == system.id }
  }

  private var routeStops: [MapFacility] { facilities.filter(\.needsCheck) }

  private var routeDone: Set<String> {
    Set(routeStops.map(\.id).filter { controller.todo.done[$0] != nil })
  }

  /// Open phone flags (not dismissed) per facility id.
  private var flagCounts: [String: Int] {
    (controller.store.current?.flags ?? [])
      .filter { $0.status != .dismissed }
      .compactMap(\.facility)
      .reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }

  var body: some View {
    VStack(spacing: 8) {
      systemChips
      HStack(spacing: 8) {
        UpdatedAgo(date: controller.mapUpdatedAt)
          .padding(.horizontal, 10)
          .frame(minHeight: 36)
          .flatCard(fill: NS.background.opacity(0.92))
        // A failed refresh keeps the last good map, tagged stale.
        if controller.mapError != nil && controller.map != nil {
          Badge(text: "STALE", tone: .amber, icon: "clock.badge.exclamationmark")
            .accessibilityLabel("Map data is stale; showing the last good update")
        }
        Spacer()
        Button {
          Haptics.tap()
          showLegend.toggle()
        } label: {
          Image(systemName: showLegend ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
            .font(.ns(.title3))
            .foregroundStyle(NS.accent)
            .frame(width: NS.tap, height: NS.tap)
            .flatCard(fill: NS.background.opacity(0.92))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showLegend ? "Hide legend" : "Show legend")
      }
      .padding(.horizontal, 12)

      if controller.map == nil {
        StateCard(
          title: controller.mapError == nil ? "Loading the map…" : "Can't reach the console",
          detail: controller.mapError == nil ? nil : "Everything is saved on the phone and will upload later.",
          icon: controller.mapError == nil ? "hourglass" : "exclamationmark.triangle",
          tone: controller.mapError == nil ? .grey : .red,
          actionTitle: controller.mapError == nil ? nil : "Retry now"
        ) {
          Task { await controller.refreshMap() }
        }
        .padding(.horizontal, 12)
        Spacer()
      } else if let system {
        if routeStops.isEmpty {
          StateCard(title: "GRID STABLE", detail: "No problems in progress.", icon: "checkmark.circle", tone: .green)
            .padding(.horizontal, 12)
        }
        CityMapView(
          system: system,
          facilities: facilities,
          routeStops: routeStops,
          routeDone: routeDone,
          flagCounts: flagCounts,
          onSelect: { selected = $0 }
        )
        // A new system starts at the default view.
        .id(system.id)
        // No taller than the drawn city at the default zoom, so a tall screen shows no
        // empty band above and below it.
        .aspectRatio(0.8, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(NS.borderStrong, lineWidth: 1))
        if showLegend {
          legend
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.top, 8)
    .background(NS.background)
    .sheet(item: $selected) { facility in
      FacilityDetailSheet(facility: facility, controller: controller)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(0)
    }
  }

  // MARK: - Chrome

  private var systemChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(controller.map?.systemIDs ?? [], id: \.self) { id in
          chip(id)
        }
      }
      .padding(.horizontal, 12)
    }
  }

  private func chip(_ id: String) -> some View {
    let selected = system?.id == id
    let hasProblem = controller.map?.facilities.contains { $0.system == id && $0.needsCheck } == true
    return Button {
      Haptics.tap()
      controller.mapSystemFilter = id
    } label: {
      HStack(spacing: 6) {
        Text(id)
          .font(.ns(.headline))
          .foregroundStyle(selected ? NS.textPrimary : NS.textSecondary)
        if hasProblem {
          Rectangle().fill(NS.red).frame(width: 7, height: 7)
        }
      }
      .padding(.horizontal, 14)
      .frame(minWidth: NS.tap, minHeight: 44)
      .background(selected ? NS.raised : NS.background.opacity(0.92))
      .overlay(Rectangle().strokeBorder(selected ? NS.accent : NS.border, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("System \(id)\(hasProblem ? ", has a problem" : "")")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  /// The dashboard's map legend.
  private var legend: some View {
    VStack(alignment: .leading, spacing: 6) {
      legendRow(NS.green, "Normal or minor")
      legendRow(NS.amber, "Check soon")
      legendRow(NS.red, "Danger")
      lineRow(Color(hex: 0x19E6FF), dashed: false, "Pipeline, dots show flow")
      lineRow(Color(hex: 0xC8CCD2), dashed: false, "Route done")
      lineRow(Color(hex: 0xA9AFB8), dashed: true, "Route to visit")
      Text("Named buildings are decoration.")
        .font(.ns(.footnote))
        .foregroundStyle(NS.textMuted)
    }
    .padding(12)
    .flatCard(fill: NS.background.opacity(0.95))
    .accessibilityElement(children: .combine)
  }

  private func legendRow(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 8) {
      Rectangle().fill(Color(hex: 0x09090B)).frame(width: 16, height: 16)
        .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
      Text(text).font(.ns(.subheadline)).foregroundStyle(NS.textBody)
    }
  }

  private func lineRow(_ color: Color, dashed: Bool, _ text: String) -> some View {
    HStack(spacing: 8) {
      Path { $0.move(to: CGPoint(x: 0, y: 2)); $0.addLine(to: CGPoint(x: 24, y: 2)) }
        .stroke(color, style: StrokeStyle(lineWidth: 3, dash: dashed ? [4, 4] : []))
        .frame(width: 24, height: 4)
      Text(text).font(.ns(.subheadline)).foregroundStyle(NS.textBody)
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
