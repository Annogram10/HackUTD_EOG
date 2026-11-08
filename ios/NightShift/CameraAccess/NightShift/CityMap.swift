//
// CityMap.swift
//
// Map geometry and the decorative neon city around the real facilities: a line-by-line
// port of the dashboard's frontend/lib/city.ts, so one system looks the same on the
// phone and on the dashboard. Pure functions, no SwiftUI.
// Facility, disposal-site and truck-yard positions come from their real lat/lon; the
// city (blocks, streets, river, district name, landmarks) is procedural decoration
// seeded by the system id with the same generator as the dashboard. Landmarks never
// overlap a facility card, a pipeline, the disposal site or the yard.
// This is drawing only: no ranking, severity or countdown is worked out here.
//

import Foundation

enum CityMap {
  static let W = 100.0
  static let H = 56.25
  /// Facility card size in map units (used for spacing and keep-out zones).
  static let chipW = 17.0
  static let chipH = 14.5

  struct Pt: Hashable {
    var x: Double
    var y: Double
  }

  struct Rect: Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
  }

  struct LatLon {
    let lat: Double
    let lon: Double
  }

  // MARK: - Layout (real positions)

  /// Equirectangular projection of lat/lon, scaled and centered into the W x H map
  /// with a margin for the cards.
  static func fit(_ points: [LatLon]) -> [Pt] {
    guard !points.isEmpty else { return [] }
    let lat0 = points.reduce(0) { $0 + $1.lat } / Double(points.count)
    let kx = 111 * cos(lat0 * .pi / 180)
    let xy = points.map { Pt(x: $0.lon * kx, y: -$0.lat * 111) }
    let xs = xy.map(\.x)
    let ys = xy.map(\.y)
    let dx = orOne(xs.max()! - xs.min()!)
    let dy = orOne(ys.max()! - ys.min()!)
    let s = min((W - 2 * 16) / dx, (H - 2 * 13) / dy)
    let cx = (xs.max()! + xs.min()!) / 2
    let cy = (ys.max()! + ys.min()!) / 2
    return xy.map { Pt(x: W / 2 + ($0.x - cx) * s, y: H / 2 + ($0.y - cy) * s) }
  }

  /// JavaScript's `value || 1`.
  private static func orOne(_ value: Double) -> Double { value == 0 ? 1 : value }

  /// Nudge cards apart when real locations are close, keeping them near where they
  /// really are.
  static func spread(_ points: [Pt]) -> [Pt] {
    var q = points
    for _ in 0..<80 {
      for i in q.indices {
        for j in q.indices where j > i {
          let ox = chipW - abs(q[i].x - q[j].x)
          let oy = chipH - abs(q[i].y - q[j].y)
          if ox > 0 && oy > 0 {
            if ox < oy {
              let d = (q[i].x <= q[j].x ? -1.0 : 1.0) * (ox / 2 + 0.2)
              q[i].x += d
              q[j].x -= d
            } else {
              let d = (q[i].y <= q[j].y ? -1.0 : 1.0) * (oy / 2 + 0.2)
              q[i].y += d
              q[j].y -= d
            }
          }
        }
      }
      for k in q.indices {
        q[k].x = min(W - chipW / 2 - 1, max(chipW / 2 + 1, q[k].x))
        q[k].y = min(H - chipH / 2 - 1, max(chipH / 2 + 1, q[k].y))
      }
    }
    return q
  }

  struct Layout {
    /// Facility id -> card center, in the order the facilities were given.
    let ids: [String]
    let pos: [String: Pt]
    let disp: Pt
    /// Nil when the system has no truck yard position.
    let yard: Pt?
  }

  /// `facilities` are (id, lat, lon) in a stable order (the layout must not move when
  /// the backend's ranking changes).
  static func layout(facilities: [(id: String, at: LatLon)], disposal: LatLon, truckYard: LatLon?) -> Layout {
    let base = fit(facilities.map(\.at) + [disposal])
    let pts = spread(base).prefix(facilities.count)
    var pos: [String: Pt] = [:]
    for (f, p) in zip(facilities, pts) { pos[f.id] = p }
    let disp = base[facilities.count]
    // The truck yard is usually far away: show it at the edge of the map in its real direction.
    var yard: Pt?
    if let truckYard {
      let yardRaw = fit(facilities.map(\.at) + [disposal, truckYard])
      let last = yardRaw[yardRaw.count - 1]
      let dir = Pt(x: last.x - W / 2, y: last.y - H / 2)
      let k = min((W / 2 - 8) / abs(dir.x == 0 ? 1e-6 : dir.x), (H / 2 - 5) / abs(dir.y == 0 ? 1e-6 : dir.y))
      yard = Pt(x: W / 2 + dir.x * k, y: H / 2 + dir.y * k)
    }
    return Layout(ids: facilities.map(\.id), pos: pos, disp: disp, yard: yard)
  }

  // MARK: - The decorative city

  struct LandmarkName {
    let name: String
    let joke: String
  }

  static let landmarkNames: [LandmarkName] = [
    LandmarkName(name: "Owlsaka Tower", joke: "they're always watching. So are we."),
    LandmarkName(name: "Brinetechnica", joke: "salt water in, salty engineers out."),
    LandmarkName(name: "Pumpitech", joke: "pumps so smart they file their own work orders."),
    LandmarkName(name: "Tank Tao", joke: "the tank that is full is not the eternal tank."),
    LandmarkName(name: "Megatank H10", joke: "holds ten of everything. Mostly water."),
    LandmarkName(name: "Hootsuka Works", joke: "night shift only. Day shift is a rumour."),
    LandmarkName(name: "Arroyo Pumpworks", joke: "established before the arroyo dried up."),
    LandmarkName(name: "Petrochem Nest", joke: "premium perches, zero vacancies."),
    LandmarkName(name: "Afterflow", joke: "the bar where pressure goes to unwind."),
  ]
  private static let maxLandmarks = 6
  /// Neon sign colors (magenta, cyan, yellow) as 0xRRGGBB.
  static let signColors: [UInt32] = [0xFF2BD6, 0x19E6FF, 0xFFD319]
  private static let districts = ["BRINELANDS", "NEON FLATS", "LOW PRESSURE", "RUST HARBOR", "SALT MESA", "PUMPTOWN", "NIGHT BASIN", "STATIC ROW"]
  /// Landmarks keep this far from everything real (~80 px at a normal dashboard width).
  private static let gap = 6.7
  /// The city is drawn well past the visible map so panning and zooming out never
  /// show an empty edge.
  static let outer = Rect(x: -W * 0.6, y: -H * 0.6, w: W * 2.2, h: H * 2.2)

  struct Block {
    let rect: Rect
    /// 0xRRGGBB between #2A1F25 and #342B30.
    let fill: UInt32
    var center: Pt { Pt(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2) }
  }

  struct Street {
    let a: Pt
    let b: Pt
    let main: Bool
  }

  struct Light {
    let at: Pt
    let color: UInt32
    let opacity: Double
  }

  struct Landmark {
    let name: String
    let joke: String
    let rect: Rect
    let sign: UInt32
    var center: Pt { Pt(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2) }
  }

  struct City {
    let blocks: [Block]
    /// Minor streets and the main avenues (incl. one diagonal).
    let streets: [Street]
    /// Points along the curved river.
    let river: [Pt]
    let lights: [Light]
    let district: String
    let landmarks: [Landmark]
  }

  /// FNV-1a hash of the id seeding mulberry32: the same numbers as the dashboard's
  /// `seeded()` (JavaScript's 32-bit integer math done with wrapping UInt32 ops).
  final class Random {
    private var a: UInt32

    init(seed id: String) {
      var h: UInt32 = 2_166_136_261
      for unit in id.utf16 { h = (h ^ UInt32(unit)) &* 16_777_619 }
      a = h
    }

    func next() -> Double {
      a = a &+ 0x6D2B_79F5
      var t = a
      t = (t ^ (t >> 15)) &* (t | 1)
      t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
      return Double(t ^ (t >> 14)) / 4_294_967_296
    }
  }

  private static func overlaps(_ a: Rect, _ b: Rect) -> Bool {
    a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
  }

  private static func grow(_ r: Rect, _ m: Double) -> Rect {
    Rect(x: r.x - m, y: r.y - m, w: r.w + 2 * m, h: r.h + 2 * m)
  }

  private static func rectPointDist(_ r: Rect, _ p: Pt) -> Double {
    let dx = max(r.x - p.x, 0, p.x - (r.x + r.w))
    let dy = max(r.y - p.y, 0, p.y - (r.y + r.h))
    return hypot(dx, dy)
  }

  private static func rectNearSegment(_ r: Rect, _ a: Pt, _ b: Pt, _ clear: Double) -> Bool {
    var t = 0.0
    while t <= 1.0001 {
      if rectPointDist(r, Pt(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) < clear { return true }
      t += 0.02
    }
    return false
  }

  /// Keep-out zones in map units: every facility card, the disposal site and the truck
  /// yard (with their labels).
  static func keepOut(_ l: Layout) -> [Rect] {
    var out = l.ids.compactMap { l.pos[$0] }.map { Rect(x: $0.x - chipW / 2, y: $0.y - chipH / 2, w: chipW, h: chipH) }
    out.append(Rect(x: l.disp.x - 6, y: l.disp.y - 4, w: 12, h: 10))  // diamond + "Disposal site" + psi
    if let yard = l.yard {
      out.append(Rect(x: yard.x - 9, y: yard.y - 3.5, w: 18, h: 8))  // square + "Truck yard"
    }
    return out
  }

  /// Between #2A1F25 and #342B30 (dark mauve).
  private static func shade(_ t: Double) -> UInt32 {
    func c(_ a: Double, _ b: Double) -> UInt32 { UInt32((a + (b - a) * t).rounded()) }
    return c(0x2A, 0x34) << 16 | c(0x1F, 0x2B) << 8 | c(0x25, 0x30)
  }

  static func buildCity(systemID: String, layout l: Layout) -> City {
    let rnd = Random(seed: systemID)
    var streets: [Street] = []
    var leaves: [Rect] = []

    // Recursive subdivision: big blocks, small lots and odd shapes, not a grid.
    func split(_ r: Rect, _ depth: Int) {
      let big = max(r.w, r.h)
      let stopP = big < 3 ? 1 : big < 6 ? 0.55 : big < 10 ? 0.25 : big < 16 ? 0.08 : 0
      if depth > 1 && rnd.next() < stopP {
        leaves.append(r)
        return
      }
      let vertical = r.w > r.h * 1.25 ? true : r.h > r.w * 1.25 ? false : rnd.next() < 0.5
      let t = 0.28 + rnd.next() * 0.44
      let gap = 0.55
      if vertical {
        let x = r.x + r.w * t
        streets.append(Street(a: Pt(x: x, y: r.y), b: Pt(x: x, y: r.y + r.h), main: false))
        split(Rect(x: r.x, y: r.y, w: x - r.x - gap / 2, h: r.h), depth + 1)
        split(Rect(x: x + gap / 2, y: r.y, w: r.x + r.w - x - gap / 2, h: r.h), depth + 1)
      } else {
        let y = r.y + r.h * t
        streets.append(Street(a: Pt(x: r.x, y: y), b: Pt(x: r.x + r.w, y: y), main: false))
        split(Rect(x: r.x, y: r.y, w: r.w, h: y - r.y - gap / 2), depth + 1)
        split(Rect(x: r.x, y: y + gap / 2, w: r.w, h: r.y + r.h - y - gap / 2), depth + 1)
      }
    }

    // Two straight main avenues (one each way) cut the city first; everything else
    // subdivides inside them.
    let ax = W * (0.25 + rnd.next() * 0.5)
    let ay = H * (0.25 + rnd.next() * 0.5)
    let mg = 1.4
    streets.append(Street(a: Pt(x: ax, y: outer.y), b: Pt(x: ax, y: outer.y + outer.h), main: true))
    streets.append(Street(a: Pt(x: outer.x, y: ay), b: Pt(x: outer.x + outer.w, y: ay), main: true))
    for (x0, x1) in [(outer.x, ax - mg), (ax + mg, outer.x + outer.w)] {
      for (y0, y1) in [(outer.y, ay - mg), (ay + mg, outer.y + outer.h)] {
        split(Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), 0)
      }
    }

    // A diagonal avenue and a curved river cut through; blocks under them are cleared.
    let dx0 = W * (0.1 + rnd.next() * 0.5)
    let diag = (Pt(x: dx0 - 40, y: -30), Pt(x: dx0 + 60, y: H + 30))
    streets.append(Street(a: diag.0, b: diag.1, main: true))
    let ry0 = H * (0.2 + rnd.next() * 0.6)
    let ry1 = H * (rnd.next() * 1.2 - 0.1)
    let ry2 = H * (0.2 + rnd.next() * 0.6)
    let river: [Pt] = (0...60).map { i in
      let t = Double(i) / 60
      let x = -30 + (W + 60) * t
      let y = (1 - t) * (1 - t) * ry0 + 2 * (1 - t) * t * ry1 + t * t * ry2
      return Pt(x: x, y: y)
    }

    var blocks: [Block] = []
    var lights: [Light] = []
    for r in leaves {
      if r.w < 0.6 || r.h < 0.6 { continue }
      if rectNearSegment(r, diag.0, diag.1, 1.1) { continue }
      if river.contains(where: { rectPointDist(r, $0) < 1.9 }) { continue }
      // Now and then a big block is cut into tiny lots.
      let lots: [Rect] = r.w > 4 && r.h > 3 && rnd.next() < 0.2
        ? [0.0, 1.0].flatMap { i in
          [0.0, 1.0].map { j in
            Rect(x: r.x + (i * r.w) / 2 + 0.12, y: r.y + (j * r.h) / 2 + 0.12, w: r.w / 2 - 0.24, h: r.h / 2 - 0.24)
          }
        }
        : [r]
      for b in lots {
        blocks.append(Block(rect: b, fill: shade(rnd.next())))
        // A few lit windows, not a light show.
        if rnd.next() < 0.08 {
          let x = b.x + 0.3 + rnd.next() * max(0, b.w - 0.6)
          let y = b.y + 0.3 + rnd.next() * max(0, b.h - 0.6)
          let color: UInt32 = rnd.next() < 0.7 ? 0xFFD319 : 0xFF2BD6
          lights.append(Light(at: Pt(x: x, y: y), color: color, opacity: 0.2 + rnd.next() * 0.25))
        }
      }
    }

    // Landmark signs: on blocks in empty space, at most six, well away from anything
    // real and from each other.
    let zones = keepOut(l).map { grow($0, gap) }
    let pipes = l.ids.compactMap { l.pos[$0] }.map { ($0, l.disp) }
    var placed: [Landmark] = []
    let candidates = blocks
      .filter { b in
        let r = b.rect
        return r.x > 2 && r.y > 3 && r.x + r.w < W - 2 && r.y + r.h < H - 2 && r.w > 2.5 && r.h > 1.6
      }
      .enumerated()
      .map { (order: rnd.next(), index: $0.offset, block: $0.element) }
      .sorted { ($0.order, $0.index) < ($1.order, $1.index) }
      .map(\.block)
    for b in candidates {
      if placed.count >= min(maxLandmarks, landmarkNames.count) { break }
      let lm = landmarkNames[placed.count]
      let w = Double(lm.name.utf16.count) * 0.62 + 1.2  // label width in map units at 12 px
      let h = 1.7
      let c = b.center
      let r = Rect(x: c.x - w / 2, y: c.y - h / 2, w: w, h: h)
      if r.x < 1 || r.x + r.w > W - 1 || r.y < 3 || r.y + r.h > H - 1 { continue }
      if zones.contains(where: { overlaps(r, $0) }) { continue }
      if pipes.contains(where: { rectNearSegment(r, $0.0, $0.1, gap) }) { continue }
      if placed.contains(where: { overlaps(r, grow($0.rect, gap)) }) { continue }
      placed.append(Landmark(name: lm.name, joke: lm.joke, rect: r, sign: signColors[placed.count % signColors.count]))
    }

    let district = districts[Int(rnd.next() * Double(districts.count))]
    return City(blocks: blocks, streets: streets, river: river, lights: lights, district: district, landmarks: placed)
  }

  /// City blocks within `radius` map units of a point (lights up blocks around a
  /// facility in danger).
  static func near(_ b: Block, _ p: Pt, _ radius: Double) -> Bool {
    hypot(b.center.x - p.x, b.center.y - p.y) < radius
  }
}
