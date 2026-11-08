//
// CityMapView.swift
//
// One system as a top-down neon city: the dashboard's SiteMap (frontend/components/
// SiteMap.tsx) on the phone, using the same geometry (CityMap.swift). Facilities, the
// disposal site and the truck yard sit at their real lat/lon positions; blocks,
// streets, river, district name and landmarks are decoration seeded by the system id.
// Facility cards carry the backend's severity color with a text label. Pipelines glow,
// with flow pulses toward the disposal site (none from a failed pump). The route
// through the backend's ranked stops is solid where done and dashed where still to go.
// Drag to pan, pinch to zoom (0.6x-4x). Cards switch to a compact chip when zoomed out
// too far for the full card to fit.
// Reduce Motion: no flow pulses, no danger glow pulse, no sign breathing.
//

import SwiftUI

/// Colors used only by the city map (the dashboard's neon set).
private enum CityColor {
  static let cyan = Color(hex: 0x19E6FF)
  static let flow = Color(hex: 0xE6FDFF)
  static let river = Color(hex: 0x0B1622)
  static let dangerFill = Color(hex: 0x34161D)
  static let routeDone = Color(hex: 0xC8CCD2)
  static let routeTodo = Color(hex: 0xA9AFB8)
  static let yard = Color(hex: 0xD4D4D8)
  static let card = Color(hex: 0x09090B)
  static let vignette = Color(.sRGB, red: 8 / 255, green: 6 / 255, blue: 10 / 255, opacity: 0.75)
}

/// The city and its paths in map units, built once per system / danger state and reused
/// on every pan and zoom frame.
private struct CityScene {
  let layout: CityMap.Layout
  let city: CityMap.City
  /// Normal blocks grouped by their fill color (a dozen paths instead of ~1,700 rects).
  let blockPaths: [(color: Color, path: Path)]
  /// Blocks near a facility in danger.
  let dangerPath: Path
  let minorStreets: Path
  let mainStreets: Path
  let river: Path

  init?(system: MapSystem, facilities: [MapFacility]) {
    // Sorted by id so the layout never moves when the backend's ranking changes.
    let placed = facilities
      .compactMap { f -> (id: String, at: CityMap.LatLon)? in
        guard let lat = f.lat, let lon = f.lon else { return nil }
        return (f.id, CityMap.LatLon(lat: lat, lon: lon))
      }
      .sorted { $0.id < $1.id }
    guard !placed.isEmpty else { return nil }

    let disposal: CityMap.LatLon
    if let site = system.disposalSite, let lat = site.lat, let lon = site.lon {
      disposal = CityMap.LatLon(lat: lat, lon: lon)
    } else if let center = system.center, center.count == 2 {
      disposal = CityMap.LatLon(lat: center[0], lon: center[1])
    } else {
      let n = Double(placed.count)
      disposal = CityMap.LatLon(lat: placed.reduce(0) { $0 + $1.at.lat } / n, lon: placed.reduce(0) { $0 + $1.at.lon } / n)
    }
    let yard = system.truckYard.flatMap { $0.count == 2 ? CityMap.LatLon(lat: $0[0], lon: $0[1]) : nil }

    let layout = CityMap.layout(facilities: placed, disposal: disposal, truckYard: yard)
    let city = CityMap.buildCity(systemID: system.id, layout: layout)
    self.layout = layout
    self.city = city

    let danger = facilities.filter { levelTone($0.severityKey) == .red }.compactMap { layout.pos[$0.id] }
    var groups: [UInt32: Path] = [:]
    var dangerPath = Path()
    for block in city.blocks {
      let rect = CGRect(x: block.rect.x, y: block.rect.y, width: block.rect.w, height: block.rect.h)
      if danger.contains(where: { CityMap.near(block, $0, 13) }) {
        dangerPath.addRect(rect)
      } else {
        groups[block.fill, default: Path()].addRect(rect)
      }
    }
    blockPaths = groups.sorted { $0.key < $1.key }.map { (Color(hex: $0.key), $0.value) }
    self.dangerPath = dangerPath

    var minor = Path()
    var main = Path()
    for street in city.streets {
      if street.main {
        main.move(to: street.a.cg)
        main.addLine(to: street.b.cg)
      } else {
        minor.move(to: street.a.cg)
        minor.addLine(to: street.b.cg)
      }
    }
    minorStreets = minor
    mainStreets = main
    river = Path { $0.addLines(city.river.map(\.cg)) }
  }
}

extension CityMap.Pt {
  fileprivate var cg: CGPoint { CGPoint(x: x, y: y) }
}

/// Screen geometry for one frame: map units -> points.
private struct MapFrame {
  let size: CGSize
  /// Points per map unit at zoom 1 (the W x H map fits the view).
  let base: CGFloat
  /// Top-left of the W x H map at zoom 1, before panning.
  let origin: CGPoint

  init(size: CGSize) {
    self.size = size
    base = max(0.01, min(size.width / CityMap.W, size.height / CityMap.H))
    origin = CGPoint(x: (size.width - CityMap.W * base) / 2, y: (size.height - CityMap.H * base) / 2)
  }
}

struct CityMapView: View {
  let system: MapSystem
  /// This system's facilities in backend order (never re-sorted for display).
  let facilities: [MapFacility]
  /// Stops on the route (backend order) and which are done.
  let routeStops: [MapFacility]
  let routeDone: Set<String>
  /// Open (not dismissed) phone flags per facility id.
  let flagCounts: [String: Int]
  let onSelect: (MapFacility) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var scene: CityScene?
  @State private var zoom: CGFloat = 1
  @State private var pan: CGSize = .zero
  @State private var lastDrag: CGSize = .zero
  @State private var lastMagnification: CGFloat = 1
  @State private var tooltip: String?
  @State private var signsDim = false

  private static let zMin: CGFloat = 0.6
  private static let zMax: CGFloat = 4
  /// Full card width in points; below this many points per card slot, cards go compact.
  private static let fullCardWidth: CGFloat = 150

  /// Rebuild the city only when what it depends on changes.
  private var sceneKey: String {
    let danger = facilities.filter { levelTone($0.severityKey) == .red }.map(\.id).sorted()
    let spots = facilities.map { "\($0.id)@\($0.lat ?? 0),\($0.lon ?? 0)" }.sorted()
    return ([system.id] + spots + ["!"] + danger).joined(separator: "|")
  }

  var body: some View {
    GeometryReader { geo in
      let frame = MapFrame(size: geo.size)
      ZStack(alignment: .topLeading) {
        NS.background
        if let scene {
          let transform = transform(frame)
          Canvas { context, _ in
            drawCity(scene, in: &context, transform: transform)
          }
          TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { timeline in
            Canvas { context, _ in
              drawLive(scene, in: &context, transform: transform, time: timeline.date.timeIntervalSinceReferenceDate)
            }
          }
          EllipticalGradient(
            stops: [.init(color: .clear, location: 0.5), .init(color: CityColor.vignette, location: 1)],
            endRadiusFraction: 0.71
          )
          .allowsHitTesting(false)
          overlays(scene, frame: frame)
        }
        controls(frame)
      }
      .contentShape(Rectangle())
      .simultaneousGesture(dragGesture(frame).simultaneously(with: magnifyGesture(frame)))
      .clipped()
    }
    .task(id: sceneKey) {
      scene = CityScene(system: system, facilities: facilities)
    }
    .onAppear { signsDim = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Map of \(system.id). Drag to pan, pinch to zoom.")
  }

  // MARK: - Geometry

  private func transform(_ frame: MapFrame) -> CGAffineTransform {
    let s = frame.base * zoom
    return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: frame.origin.x + pan.width, ty: frame.origin.y + pan.height)
  }

  private func screen(_ p: CityMap.Pt, _ frame: MapFrame) -> CGPoint {
    p.cg.applying(transform(frame))
  }

  /// Keep at least part of the map on screen.
  private func clampPan(_ pan: CGSize, zoom: CGFloat, _ frame: MapFrame) -> CGSize {
    let boxW = CityMap.W * frame.base * zoom
    let boxH = CityMap.H * frame.base * zoom
    let w = frame.size.width
    let h = frame.size.height
    return CGSize(
      width: min(w * 0.7 - frame.origin.x, max(w * 0.3 - frame.origin.x - boxW, pan.width)),
      height: min(h * 0.7 - frame.origin.y, max(h * 0.3 - frame.origin.y - boxH, pan.height))
    )
  }

  /// Zoom by `factor`, keeping the map point under `anchor` where it is.
  private func zoomAt(_ factor: CGFloat, anchor: CGPoint, _ frame: MapFrame) {
    let z = min(Self.zMax, max(Self.zMin, zoom * factor))
    let s = frame.base * zoom
    let mapX = (anchor.x - frame.origin.x - pan.width) / s
    let mapY = (anchor.y - frame.origin.y - pan.height) / s
    let s2 = frame.base * z
    let newPan = CGSize(width: anchor.x - frame.origin.x - mapX * s2, height: anchor.y - frame.origin.y - mapY * s2)
    zoom = z
    pan = clampPan(newPan, zoom: z, frame)
  }

  private func dragGesture(_ frame: MapFrame) -> some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        let delta = CGSize(width: value.translation.width - lastDrag.width, height: value.translation.height - lastDrag.height)
        lastDrag = value.translation
        pan = clampPan(CGSize(width: pan.width + delta.width, height: pan.height + delta.height), zoom: zoom, frame)
      }
      .onEnded { _ in lastDrag = .zero }
  }

  private func magnifyGesture(_ frame: MapFrame) -> some Gesture {
    MagnifyGesture()
      .onChanged { value in
        zoomAt(value.magnification / lastMagnification, anchor: value.startLocation, frame)
        lastMagnification = value.magnification
      }
      .onEnded { _ in lastMagnification = 1 }
  }

  // MARK: - Drawing

  /// River, streets, blocks and lit windows (redrawn only on pan / zoom).
  private func drawCity(_ scene: CityScene, in context: inout GraphicsContext, transform t: CGAffineTransform) {
    let scale = t.a
    // River: wide dark water (scales with zoom) and a faint cyan centerline.
    context.stroke(scene.river.applying(t), with: .color(CityColor.river), style: StrokeStyle(lineWidth: 3.4 * scale, lineCap: .round))
    context.stroke(scene.river.applying(t), with: .color(CityColor.cyan.opacity(0.07)), lineWidth: 1)
    // Minor streets: thin and dark. Main avenues: a faint wide halo plus a 5 pt line.
    context.stroke(scene.minorStreets.applying(t), with: .color(CityColor.cyan.opacity(0.08)), lineWidth: 1.5)
    let main = scene.mainStreets.applying(t)
    context.stroke(main, with: .color(CityColor.cyan.opacity(0.06)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
    context.stroke(main, with: .color(CityColor.cyan.opacity(0.2)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
    for group in scene.blockPaths {
      context.fill(group.path.applying(t), with: .color(group.color))
    }
    for light in scene.city.lights {
      let c = light.at.cg.applying(t)
      let r = 0.12 * scale
      context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(hex: light.color).opacity(light.opacity)))
    }
  }

  /// Danger glow, pipelines with flow pulses, and the route (animated layer).
  private func drawLive(_ scene: CityScene, in context: inout GraphicsContext, transform t: CGAffineTransform, time: TimeInterval) {
    let layout = scene.layout

    // Blocks near a facility in danger glow red (stroke pulses 0.55 -> 0.25 over 2.4 s).
    if !scene.dangerPath.isEmpty {
      let danger = scene.dangerPath.applying(t)
      context.fill(danger, with: .color(CityColor.dangerFill))
      let pulse = reduceMotion ? 0.55 : 0.4 + 0.15 * cos(2 * .pi * time / 2.4)
      context.stroke(danger, with: .color(NS.red.opacity(pulse)), lineWidth: 1)
    }

    // Pipelines to the disposal site: glow, plus flow pulses unless the pump has failed.
    let disp = layout.disp.cg.applying(t)
    let flowPhase = -24 * (time.truncatingRemainder(dividingBy: 1.6) / 1.6)
    for facility in facilities {
      guard let p = layout.pos[facility.id]?.cg.applying(t) else { continue }
      let status = facility.status?.lowercased()
      let leak = status == "leak"
      let color = leak ? NS.amber : CityColor.cyan
      let line = Path { $0.move(to: p); $0.addLine(to: disp) }
      context.stroke(line, with: .color(color.opacity(0.22)), style: StrokeStyle(lineWidth: 10, lineCap: .round))
      context.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: leak ? [10, 6] : []))
      let failed = status == "failure" || status == "tripped"
      if !failed && !reduceMotion {
        context.stroke(line, with: .color(CityColor.flow), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 22], dashPhase: flowPhase))
      }
    }

    // Route through the ranked stops: solid up to the last one done, dashed after.
    let points = routeStops.compactMap { layout.pos[$0.id]?.cg.applying(t) }
    guard !points.isEmpty else { return }
    let lastDone = routeStops.lastIndex { routeDone.contains($0.id) }
    let split = lastDone.map { min($0, points.count - 1) }
    let done = split.map { Array(points[...$0]) } ?? []
    let remaining = split.map { Array(points[$0...]) } ?? points
    if remaining.count >= 2 {
      context.stroke(Path { $0.addLines(remaining) }, with: .color(CityColor.routeTodo.opacity(0.7)),
                     style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [4, 6]))
    }
    if done.count >= 2 {
      context.stroke(Path { $0.addLines(done) }, with: .color(CityColor.routeDone.opacity(0.9)),
                     style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
    }
  }

  // MARK: - Overlays (text stays readable at any zoom)

  @ViewBuilder
  private func overlays(_ scene: CityScene, frame: MapFrame) -> some View {
    let cardScale = min(1.2, max(0.86, zoom))
    let slot = CityMap.chipW * frame.base * zoom
    let full = slot >= Self.fullCardWidth
    let compactWidth = min(Self.fullCardWidth, max(56, slot - 6))

    // Landmark rooftop signs: small, dim, decoration only. Tap for the joke. Sized to the
    // space the layout reserved for them (0.62 map units per character at 12 px on the
    // dashboard), so they never overlap; hidden while zoomed out too far to read.
    let signSize = min(12, 0.62 * frame.base * zoom / 0.6)
    ForEach(signSize >= 8 ? scene.city.landmarks : [], id: \.name) { landmark in
      let color = Color(hex: landmark.sign)
      Button {
        tooltip = tooltip == landmark.name ? nil : landmark.name
      } label: {
        Text(landmark.name.uppercased())
          .font(.system(size: signSize, weight: .medium, design: .monospaced))
          .foregroundStyle(color)
          .shadow(color: color.opacity(0.4), radius: 4)
          .fixedSize()
          .padding(6)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(reduceMotion ? 0.6 : (signsDim ? 0.4 : 0.6))
      .animation(reduceMotion ? nil : .easeInOut(duration: 2).repeatForever(autoreverses: true), value: signsDim)
      .position(screen(landmark.center, frame))
      .accessibilityLabel("\(landmark.name), decoration")
      .accessibilityHint(landmark.joke)
    }

    // District label.
    Text("\(system.id) // \(scene.city.district)")
      .font(.nsMono(.subheadline))
      .tracking(2)
      .foregroundStyle(NS.textMuted)
      .padding(10)
      .allowsHitTesting(false)
      .accessibilityHidden(true)

    // Disposal site.
    VStack(spacing: 4) {
      Rectangle()
        .fill(CityColor.card)
        .frame(width: 20, height: 20)
        .overlay(Rectangle().strokeBorder(CityColor.cyan, lineWidth: 2))
        .rotationEffect(.degrees(45))
        .frame(width: 28, height: 28)
      Text("Disposal site")
        .font(.ns(.footnote, .semibold))
        .foregroundStyle(NS.textPrimary)
        .padding(.horizontal, 6)
        .background(CityColor.card.opacity(0.85))
      if let psi = system.disposalSite?.pressurePsi {
        Text("\(Int(psi.rounded())) psi")
          .font(.nsMono(.caption))
          .foregroundStyle(NS.textMuted)
          .padding(.horizontal, 4)
          .background(CityColor.card.opacity(0.85))
      }
    }
    .fixedSize()
    .scaleEffect(cardScale)
    .position(screen(scene.layout.disp, frame))
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)

    // Truck yard (at the map edge in its real direction).
    if let yard = scene.layout.yard {
      VStack(spacing: 4) {
        Rectangle()
          .fill(CityColor.card)
          .frame(width: 24, height: 24)
          .overlay(Rectangle().strokeBorder(CityColor.yard, lineWidth: 2))
        Text("Truck yard")
          .font(.ns(.footnote))
          .foregroundStyle(CityColor.yard)
          .padding(.horizontal, 6)
          .background(CityColor.card.opacity(0.85))
      }
      .fixedSize()
      .scaleEffect(cardScale)
      .position(screen(yard, frame))
      .allowsHitTesting(false)
      .accessibilityElement(children: .combine)
    }

    // Facility cards.
    ForEach(facilities) { facility in
      if let p = scene.layout.pos[facility.id] {
        Button {
          Haptics.tap()
          onSelect(facility)
        } label: {
          FacilityCityCard(
            facility: facility,
            stop: routeStops.firstIndex { $0.id == facility.id }.map { $0 + 1 },
            flags: flagCounts[facility.id] ?? 0,
            full: full,
            width: full ? Self.fullCardWidth : compactWidth
          )
        }
        .buttonStyle(.plain)
        .scaleEffect(full ? cardScale : 1)
        .position(screen(p, frame))
        .accessibilityLabel(accessibilityLabel(facility))
        .accessibilityHint("Shows details")
      }
    }

    // Landmark tooltip.
    if let name = tooltip, let landmark = scene.city.landmarks.first(where: { $0.name == name }) {
      let anchor = screen(CityMap.Pt(x: landmark.center.x, y: landmark.rect.y + landmark.rect.h), frame)
      (Text("\(landmark.name): ").foregroundStyle(Color(hex: landmark.sign)) + Text(landmark.joke).foregroundStyle(NS.textMuted))
        .font(.ns(.subheadline, .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(CityColor.card)
        .overlay(Rectangle().strokeBorder(NS.border, lineWidth: 1))
        .position(x: anchor.x, y: anchor.y + 34)
        .onTapGesture { tooltip = nil }
        .task(id: name) {
          try? await Task.sleep(for: .seconds(5))
          if tooltip == name { tooltip = nil }
        }
    }
  }

  private func accessibilityLabel(_ facility: MapFacility) -> String {
    var parts = [facility.displayName, "level \(levelLabel(facility.severityKey).lowercased())", statusLabel(facility.status)]
    if let stop = routeStops.firstIndex(where: { $0.id == facility.id }) { parts.insert("Stop \(stop + 1)", at: 0) }
    if let hours = facility.hoursToShutdown, facility.status?.lowercased() != "tripped" { parts.append(hoursLeftText(hours)) }
    if let flags = flagCounts[facility.id], flags > 0 { parts.append("\(flags) flag\(flags == 1 ? "" : "s")") }
    return parts.joined(separator: ", ")
  }

  // MARK: - Controls

  private func controls(_ frame: MapFrame) -> some View {
    HStack(spacing: 4) {
      controlButton("minus", label: "Zoom out") {
        zoomAt(1 / 1.25, anchor: CGPoint(x: frame.size.width / 2, y: frame.size.height / 2), frame)
      }
      controlButton("plus", label: "Zoom in") {
        zoomAt(1.25, anchor: CGPoint(x: frame.size.width / 2, y: frame.size.height / 2), frame)
      }
      Button {
        Haptics.tap()
        zoom = 1
        pan = .zero
      } label: {
        Text("RESET VIEW")
          .font(.ns(.subheadline, .bold))
          .foregroundStyle(NS.textPrimary)
          .padding(.horizontal, 12)
          .frame(minHeight: 44)
          .background(CityColor.card.opacity(0.9))
          .overlay(Rectangle().strokeBorder(NS.border, lineWidth: 1))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private func controlButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
    Button {
      Haptics.tap()
      action()
    } label: {
      Image(systemName: systemName)
        .font(.ns(.headline, .bold))
        .foregroundStyle(NS.textPrimary)
        .frame(width: 44, height: 44)
        .background(CityColor.card.opacity(0.9))
        .overlay(Rectangle().strokeBorder(NS.border, lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

/// A facility on the city map: the full dashboard card when there is room, otherwise a
/// compact chip (name + severity). Border color = the server's severity.
private struct FacilityCityCard: View {
  let facility: MapFacility
  /// Position on the route, if it is a stop.
  let stop: Int?
  let flags: Int
  let full: Bool
  let width: CGFloat

  private var tone: Tone { levelTone(facility.severityKey) }
  private var danger: Bool { tone == .red }
  private var tripped: Bool { facility.status?.lowercased() == "tripped" }

  var body: some View {
    content
      .frame(width: width, alignment: .leading)
      .background(CityColor.card)
      .overlay(Rectangle().strokeBorder(tone.color, lineWidth: 2))
      .padding(full ? 4 : 2)
      .background(NS.background.opacity(0.9))
      .overlay(danger ? Rectangle().stroke(NS.red.opacity(0.4), lineWidth: 1) : nil)
      .overlay(alignment: .topLeading) {
        if let stop {
          Text("\(stop)")
            .font(.nsMono(full ? .subheadline : .caption, .bold))
            .foregroundStyle(NS.onFill)
            .frame(width: full ? 26 : 20, height: full ? 26 : 20)
            .background(Circle().fill(CityColor.yard))
            .overlay(Circle().stroke(CityColor.card, lineWidth: 2))
            .offset(x: full ? -11 : -9, y: full ? -11 : -9)
        }
      }
      .dynamicTypeSize(...DynamicTypeSize.xLarge)
      .contentShape(Rectangle())
  }

  @ViewBuilder
  private var content: some View {
    if full {
      VStack(alignment: .leading, spacing: 3) {
        nameRow(font: .ns(.headline, .bold))
        Text(statusLabel(facility.status))
          .font(.ns(.subheadline, .semibold))
          .foregroundStyle(statusTone(facility.status).text)
          .lineLimit(2)
        if tripped {
          Text("Tank at shutdown")
            .font(.ns(.subheadline, .semibold))
            .foregroundStyle(NS.redText)
        } else if let hours = facility.hoursToShutdown {
          Text(hoursLeftText(hours))
            .font(.nsMono(.footnote, .semibold))
            .foregroundStyle(NS.redText)
        }
        Text(levelLabel(facility.severityKey) + (flags > 0 ? " · \(flags) flag\(flags == 1 ? "" : "s")" : ""))
          .font(.ns(.subheadline, .semibold))
          .foregroundStyle(tone.text)
      }
      .padding(8)
    } else {
      VStack(alignment: .leading, spacing: 1) {
        nameRow(font: .ns(.caption, .bold))
        Text(levelLabel(facility.severityKey))
          .font(.ns(.caption2, .semibold))
          .foregroundStyle(tone.text)
          .lineLimit(1)
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
    }
  }

  private func nameRow(font: Font) -> some View {
    HStack(spacing: 5) {
      Circle().fill(tone.color).frame(width: full ? 10 : 7, height: full ? 10 : 7)
      Text(facility.displayName)
        .font(font)
        .foregroundStyle(danger ? NS.redText : NS.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
  }
}

#Preview("City map (mock data)") {
  if let url = Bundle.main.url(forResource: "mock_map", withExtension: "json"),
    let data = try? Data(contentsOf: url),
    let map = try? JSONCoding.decoder.decode(FacilityMap.self, from: data),
    let system = map.systems.first
  {
    let facilities = map.facilities.filter { $0.system == system.id }
    CityMapView(
      system: system,
      facilities: facilities,
      routeStops: facilities.filter(\.needsCheck),
      routeDone: [],
      flagCounts: [:],
      onSelect: { _ in }
    )
    .aspectRatio(0.8, contentMode: .fit)
    .preferredColorScheme(.dark)
  } else {
    Text("mock_map.json missing")
  }
}
