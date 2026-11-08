//
// MapTabView.swift
//
// Map tab: GET /map on a muted dark map. Square, numbered markers with a 2 pt border by
// status plus the level as text; the route through ranked facilities (importance > 0)
// is dashed light grey, with the part already done drawn solid. System chips, "Updated
// Xs ago", recenter, and a collapsible legend. Wells and pipelines aren't in /map, so
// placeholder ("demo") layers are drawn for them while Config.showDemoMapLayers is on.
//

import MapKit
import SwiftUI

struct MapTabView: View {
  var controller: NightShiftController
  @State private var position: MapCameraPosition = .automatic
  @State private var selected: MapFacility?
  @State private var showLegend = false
  @AppStorage(Config.Keys.showDemoMapLayers) private var showDemoLayers = true

  /// Backend order (already ranked), narrowed to the selected system. Never re-sorted.
  private var facilities: [MapFacility] {
    let all = controller.map?.facilities ?? []
    guard let filter = controller.mapSystemFilter else { return all }
    return all.filter { $0.system == filter }
  }

  private var routeStops: [MapFacility] { facilities.filter(\.needsCheck) }

  private var systems: [MapSystem] {
    let all = controller.map?.systems ?? []
    guard let filter = controller.mapSystemFilter else { return all }
    return all.filter { $0.id == filter }
  }

  /// Route split at the last stop marked done: solid before, dashed after.
  private var routeParts: (done: [CLLocationCoordinate2D], remaining: [CLLocationCoordinate2D]) {
    let coordinates = routeStops.compactMap(\.coordinate)
    guard let lastDone = routeStops.lastIndex(where: { controller.todo.done[$0.id] != nil }) else {
      return ([], coordinates)
    }
    let split = min(lastDone, coordinates.count - 1)
    return (Array(coordinates[...split]), Array(coordinates[split...]))
  }

  var body: some View {
    ZStack(alignment: .top) {
      map
      VStack(spacing: 8) {
        systemChips
        HStack(spacing: 8) {
          UpdatedAgo(date: controller.mapUpdatedAt)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .flatCard(fill: NS.background.opacity(0.92))
          // A failed refresh keeps the last good pins, tagged stale.
          if controller.mapError != nil && controller.map != nil {
            Badge(text: "STALE", tone: .amber, icon: "clock.badge.exclamationmark")
              .accessibilityLabel("Map data is stale; showing the last good update")
          }
          Spacer()
          squareIconButton("location.viewfinder", label: "Recenter the map") {
            position = .automatic
          }
          squareIconButton(showLegend ? "list.bullet.rectangle.fill" : "list.bullet.rectangle", label: showLegend ? "Hide legend" : "Show legend") {
            showLegend.toggle()
          }
        }
        .padding(.horizontal, 12)
        if controller.map == nil {
          StateCard(
            title: controller.mapError == nil ? "Loading the map…" : "Couldn't load the map",
            detail: controller.mapError.map { "\($0) Retrying by itself." },
            icon: controller.mapError == nil ? "hourglass" : "exclamationmark.triangle",
            tone: controller.mapError == nil ? .grey : .red,
            actionTitle: controller.mapError == nil ? nil : "Retry now"
          ) {
            Task { await controller.refreshMap() }
          }
          .padding(.horizontal, 12)
        } else if routeStops.isEmpty {
          StateCard(title: "No problems in progress", detail: nil, icon: "checkmark.circle", tone: .green)
            .padding(.horizontal, 12)
        }
        if showLegend {
          legend
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      .padding(.top, 8)
    }
    .sheet(item: $selected) { facility in
      FacilityDetailSheet(facility: facility, controller: controller)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(0)
    }
  }

  // MARK: - Map

  private var map: some View {
    Map(position: $position) {
      if showDemoLayers {
        demoPipelines
      }
      let parts = routeParts
      if parts.remaining.count >= 2 {
        MapPolyline(MKPolyline(coordinates: parts.remaining, count: parts.remaining.count))
          .stroke(NS.textSecondary.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 6]))
      }
      if parts.done.count >= 2 {
        MapPolyline(MKPolyline(coordinates: parts.done, count: parts.done.count))
          .stroke(NS.textBody, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      }
      ForEach(systems) { system in
        if let yard = coordinate(system.truckYard) {
          Annotation("", coordinate: yard) {
            siteIcon("box.truck.fill").accessibilityLabel("\(system.id) truck yard")
          }
        }
        if let site = system.disposalSite, let lat = site.lat, let lon = site.lon {
          Annotation("", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
            siteIcon("drop.fill").accessibilityLabel("\(system.id) water disposal site")
          }
        }
      }
      if showDemoLayers {
        demoWells
      }
      ForEach(facilities) { facility in
        if let coordinate = facility.coordinate {
          Annotation("", coordinate: coordinate, anchor: .center) {
            Button {
              Haptics.tap()
              selected = facility
            } label: {
              marker(for: facility)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(markerAccessibilityLabel(facility))
            .accessibilityHint("Shows details")
          }
        }
      }
    }
    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
    .environment(\.colorScheme, .dark)
    .onChange(of: controller.mapSystemFilter) { position = .automatic }
  }

  /// Square chip with the rank, a 2 pt status border, and the level as text.
  private func marker(for facility: MapFacility) -> some View {
    let border = markerColor(for: facility)
    return HStack(spacing: 4) {
      if facility.needsCheck {
        Text(facility.rank.map(String.init) ?? "·")
          .font(.nsMono(.subheadline, .bold))
          .foregroundStyle(NS.textPrimary)
          .frame(minWidth: 26, minHeight: 26)
          .background(NS.surface)
          .overlay(Rectangle().strokeBorder(border, lineWidth: 2))
        Text(levelLabel(facility.severityKey))
          .font(.ns(.caption2, .semibold))
          .foregroundStyle(levelTone(facility.severityKey).text)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .background(NS.background.opacity(0.85))
      } else {
        Rectangle()
          .fill(NS.surface)
          .frame(width: 12, height: 12)
          .overlay(Rectangle().strokeBorder(border, lineWidth: 2))
      }
    }
    // 56 pt tap area around the drawn chip.
    .frame(minWidth: NS.tap, minHeight: NS.tap)
    .contentShape(Rectangle())
  }

  /// The marker border is the server's severity (same colors as every other screen).
  private func markerColor(for facility: MapFacility) -> Color {
    levelTone(facility.severityKey).color
  }

  private func markerAccessibilityLabel(_ facility: MapFacility) -> String {
    var parts = [facility.displayName, "level \(levelLabel(facility.severityKey).lowercased())", statusLabel(facility.status)]
    if facility.needsCheck, let rank = facility.rank { parts.insert("Stop \(rank)", at: 0) }
    if let hours = facility.hoursToShutdown { parts.append(hoursLeftText(hours)) }
    return parts.joined(separator: ", ")
  }

  // MARK: - Demo layers (stubs: /map has no wells or pipelines)

  /// Placeholder pipelines from each facility to its system's disposal site; amber and
  /// thicker where the facility reports a possible leak.
  @MapContentBuilder
  private var demoPipelines: some MapContent {
    ForEach(facilities) { facility in
      if let from = facility.coordinate, let to = disposalCoordinate(for: facility.system) {
        let leak = facility.status?.lowercased() == "leak"
        MapPolyline(coordinates: [from, to])
          .stroke(leak ? NS.amber : NS.borderStrong, lineWidth: leak ? 4 : 2)
      }
    }
  }

  /// Placeholder wells: three small dots near each facility, green producing, grey
  /// when the facility is tripped (wells shut in).
  @MapContentBuilder
  private var demoWells: some MapContent {
    ForEach(facilities) { facility in
      if let center = facility.coordinate {
        let shutIn = facility.status?.lowercased() == "tripped"
        ForEach(0..<3, id: \.self) { index in
          Annotation("", coordinate: wellCoordinate(center, index: index)) {
            Circle()
              .fill(shutIn ? NS.textMuted : NS.green)
              .frame(width: 7, height: 7)
              .accessibilityLabel("Demo well, \(shutIn ? "shut in" : "producing")")
          }
        }
      }
    }
  }

  private func wellCoordinate(_ center: CLLocationCoordinate2D, index: Int) -> CLLocationCoordinate2D {
    let angle = Double(index) * 2 * .pi / 3 + 0.5
    return CLLocationCoordinate2D(latitude: center.latitude + 0.025 * sin(angle), longitude: center.longitude + 0.03 * cos(angle))
  }

  private func disposalCoordinate(for systemID: String?) -> CLLocationCoordinate2D? {
    guard let site = controller.map?.systems.first(where: { $0.id == systemID })?.disposalSite,
      let lat = site.lat, let lon = site.lon
    else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lon)
  }

  // MARK: - Chrome

  private var systemChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(title: "All", system: nil)
        ForEach(controller.map?.systemIDs ?? [], id: \.self) { id in
          chip(title: id, system: id)
        }
      }
      .padding(.horizontal, 12)
    }
  }

  private func chip(title: String, system: String?) -> some View {
    let selected = controller.mapSystemFilter == system
    let hasProblem = system.map { id in controller.map?.facilities.contains { $0.system == id && $0.needsCheck } == true } ?? false
    return Button {
      Haptics.tap()
      controller.mapSystemFilter = system
    } label: {
      HStack(spacing: 6) {
        Text(title)
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
    .accessibilityLabel(system.map { "System \($0)\(hasProblem ? ", has a problem" : "")" } ?? "All systems")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 6) {
      legendRow(NS.green, "Normal")
      legendRow(NS.amber, "Pump wearing out")
      legendRow(NS.amber, "Possible leak")
      legendRow(NS.red, "Pump failure")
      HStack(spacing: 8) {
        Rectangle().fill(NS.textSecondary.opacity(0.7)).frame(width: 18, height: 2)
        Text("Route to visit").font(.ns(.subheadline)).foregroundStyle(NS.textBody)
      }
      if showDemoLayers {
        Text("Wells and pipelines: demo data")
          .font(.ns(.footnote))
          .foregroundStyle(NS.amberText)
      }
    }
    .padding(12)
    .flatCard(fill: NS.background.opacity(0.95))
    .accessibilityElement(children: .combine)
  }

  private func legendRow(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 8) {
      Rectangle().fill(NS.surface).frame(width: 16, height: 16)
        .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
      Text(text).font(.ns(.subheadline)).foregroundStyle(NS.textBody)
    }
  }

  private func squareIconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.tap()
      action()
    } label: {
      Image(systemName: systemName)
        .font(.ns(.title3))
        .foregroundStyle(NS.accent)
        .frame(width: NS.tap, height: NS.tap)
        .flatCard(fill: NS.background.opacity(0.92))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func siteIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.ns(.caption2))
      .foregroundStyle(NS.textSecondary)
      .padding(4)
      .background(NS.raised)
      .overlay(Rectangle().strokeBorder(NS.borderStrong, lineWidth: 1))
  }

  private func coordinate(_ pair: [Double]?) -> CLLocationCoordinate2D? {
    guard let pair, pair.count == 2 else { return nil }
    return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
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
