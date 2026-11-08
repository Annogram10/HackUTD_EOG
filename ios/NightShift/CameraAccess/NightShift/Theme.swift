//
// Theme.swift
//
// NightShift design system: deep-wine dark theme, solid cards with a 1 pt border and a
// small chamfered top-right corner (4 pt radius elsewhere), no shadows, gradients or
// blur. Rajdhani for UI text, Big Shoulders Stencil Display for titles and the danger
// banner, SF Mono (system monospaced) for every number. All fonts scale with Dynamic
// Type. Color means status and is always paired with a text label.
//

import SwiftUI
import UIKit

enum NS {
  // MARK: Colors

  static let background = Color(hex: 0x1A0710)      // deep wine
  static let surface = Color(hex: 0x342B30)         // cards
  static let raised = Color(hex: 0x3F3238)          // raised / pressed
  static let border = Color(hex: 0x5A3A42)
  /// Key card borders and the camera frame.
  static let borderStrong = Color(hex: 0xA83C47)
  static let textPrimary = Color(hex: 0xF8EED7)     // cream
  static let textBody = Color(hex: 0xF8EED7)
  static let textMuted = Color(hex: 0xC9B8B0)
  static let textSecondary = Color(hex: 0xC59FB0)

  /// Primary buttons and "Shift" in the title (dark text on it).
  static let primary = Color(hex: 0xBC7579)         // salmon
  static let primaryPressed = Color(hex: 0xA4615F)
  /// Links, selected tab, "Night" in the title.
  static let accent = Color(hex: 0x8E95B5)          // periwinkle
  static let accentPressed = Color(hex: 0x737A9C)
  /// HUD decoration: dividers, card corner marks.
  static let hud = Color(hex: 0xAD6564)
  /// HUD label text: a touch lighter than `hud` so 12 pt labels meet AA contrast.
  static let hudText = Color(hex: 0xB56B6A)
  /// Tiny highlights only (recording dot, listening cursor).
  static let highlight = Color(hex: 0xF3F654)

  // Status (always with a text label).
  static let green = Color(hex: 0x5DD39E)           // normal
  static let greenStrong = Color(hex: 0x5DD39E)
  static let amber = Color(hex: 0xFF9F1C)           // check soon
  static let amberText = Color(hex: 0xFF9F1C)
  static let red = Color(hex: 0xFF2D2D)             // danger (filled badges)
  /// Red for text on cards (pure #FF2D2D on a card is below AA).
  static let redText = Color(hex: 0xFF7A7A)
  static let alarmRed = Color(hex: 0xFF2D2D)
  /// Text on filled danger / salmon fills.
  static let onFill = Color(hex: 0x1A0710)

  /// Minimum tap target.
  static let tap: CGFloat = 56
}

// MARK: - Fonts

/// Rajdhani (UI), Big Shoulders Stencil Display (titles), SF Mono (numbers). Sizes are
/// tied to text styles so everything follows Dynamic Type. Rajdhani runs small, so its
/// sizes sit a little above the system ones; body text is never under 17 pt.
extension Font {
  private static func rajdhaniSize(_ style: TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: return 36
    case .title: return 30
    case .title2: return 25
    case .title3: return 22
    case .headline: return 19
    case .body: return 18
    case .callout: return 17
    case .subheadline: return 17
    case .footnote: return 15
    case .caption: return 14
    case .caption2: return 13
    @unknown default: return 18
    }
  }

  /// Rajdhani at a text style; Medium or heavier.
  static func ns(_ style: TextStyle, _ weight: Weight = .medium) -> Font {
    let name: String
    switch weight {
    case .bold, .heavy, .black: name = "Rajdhani-Bold"
    case .semibold: name = "Rajdhani-SemiBold"
    default: name = style == .headline ? "Rajdhani-SemiBold" : "Rajdhani-Medium"
    }
    return .custom(name, size: rajdhaniSize(style), relativeTo: style)
  }

  /// Big Shoulders Stencil Display Bold for the app title, screen titles, danger banner.
  static func nsDisplay(_ style: TextStyle) -> Font {
    .custom("BigShouldersStencilDisplay-Bold", size: rajdhaniSize(style) + 2, relativeTo: style)
  }

  /// SF Mono with tabular digits, for every number (tank %, countdowns, costs, times).
  static func nsMono(_ style: TextStyle, _ weight: Weight = .regular) -> Font {
    .system(style, design: .monospaced, weight: weight).monospacedDigit()
  }
}

// MARK: - Shapes

/// Card shape: 4 pt corners with a small chamfer cut at the top right.
struct ChamferedRect: InsettableShape {
  var chamfer: CGFloat = 10
  var radius: CGFloat = 4
  var insetAmount: CGFloat = 0

  func path(in rect: CGRect) -> Path {
    let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
    let c = min(chamfer, r.width / 2, r.height / 2)
    let rad = min(radius, r.width / 4, r.height / 4)
    var p = Path()
    p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
    p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
    p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.closeSubpath()
    return p
  }

  func inset(by amount: CGFloat) -> ChamferedRect {
    var copy = self
    copy.insetAmount += amount
    return copy
  }
}

/// Small uppercase HUD label above a card: SF Mono 12, HUD color, 0.08em tracking.
struct HudLabel: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .font(.nsMono(.caption, .medium))
      .tracking(12 * 0.08)
      .foregroundStyle(NS.hudText)
      .accessibilityHidden(true)
  }
}

/// A HUD label plus a chamfered card. `key` cards get the crimson border.
struct SysCard<Content: View>: View {
  let label: String
  var key: Bool = false
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HudLabel(text: label)
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .flatCard(stroke: key ? NS.borderStrong : NS.border)
      .overlay(alignment: .topTrailing) {
        // HUD corner mark on the chamfer.
        Path { p in
          p.move(to: CGPoint(x: 0, y: 0))
          p.addLine(to: CGPoint(x: 10, y: 10))
        }
        .stroke(NS.hud, lineWidth: 1)
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
      }
    }
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1
    )
  }
}

// MARK: - Layout

/// Side by side normally; stacked at accessibility text sizes so big text and big
/// buttons never clip (Dynamic Type up to xxxLarge and beyond).
struct AdaptiveStack<Content: View>: View {
  var spacing: CGFloat = 10
  /// Alignment when stacked.
  var stackedAlignment: HorizontalAlignment = .center
  @ViewBuilder let content: Content
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: stackedAlignment, spacing: spacing) { content }
    } else {
      HStack(spacing: spacing) { content }
    }
  }
}

// MARK: - Haptics

enum Haptics {
  /// Light tap for the main buttons.
  @MainActor static func tap() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }
}

// MARK: - Status tones

/// A status color with its lighter text shade.
enum Tone {
  case green, amber, red, redStrong, grey, blue

  var color: Color {
    switch self {
    case .green: return NS.green
    case .amber: return NS.amber
    case .red, .redStrong: return NS.red
    case .grey: return NS.textMuted
    case .blue: return NS.accent
    }
  }

  var text: Color {
    switch self {
    case .green: return NS.green
    case .amber: return NS.amberText
    case .red, .redStrong: return NS.redText
    case .grey: return NS.textMuted
    case .blue: return NS.accent
    }
  }

  var fillOpacity: Double { self == .redStrong ? 0.32 : 0.15 }
}

/// The server's severity (`severity`, else `level`) as a tone. This is the only place
/// severity is turned into color; every screen and the map use it.
///   high (or old "red")          -> red
///   medium (or old "yellow")     -> amber
///   low                          -> grey
///   none (or old "green")        -> green
func levelTone(_ severity: String?) -> Tone {
  switch severity?.lowercased() {
  case "high", "red": return .red
  case "medium", "yellow", "amber": return .amber
  case "none", "green": return .green
  default: return .grey
  }
}

/// Dashboard labels: HIGH, MEDIUM, LOW, NORMAL.
func levelLabel(_ severity: String?) -> String {
  switch severity?.lowercased() {
  case "high", "red": return "HIGH"
  case "medium", "yellow", "amber": return "MEDIUM"
  case "low": return "LOW"
  case "none", "green": return "NORMAL"
  default: return (severity ?? "UNKNOWN").uppercased()
  }
}

/// Live sensor state ("ok", "worn", "leak", "failure", "tripped") as plain words.
func statusLabel(_ status: String?) -> String {
  switch status?.lowercased() {
  case "ok", nil: return "Normal"
  case "worn": return "Pump wearing out"
  case "leak": return "Possible leak"
  case "failure": return "Pump failure"
  case "tripped": return "Tank tripped, wells shut in"
  default: return status?.capitalized ?? "Normal"
  }
}

func statusTone(_ status: String?) -> Tone {
  switch status?.lowercased() {
  case "ok", nil: return .green
  case "worn", "leak": return .amber
  case "failure": return .red
  case "tripped": return .redStrong
  default: return .grey
  }
}

// MARK: - Badges

/// Status badge, always with text. Danger is a FILLED red badge with dark text;
/// the others are a 1 pt ring with a light tint and colored text.
struct Badge: View {
  let text: String
  let tone: Tone
  var icon: String? = nil

  private var filled: Bool { tone == .red || tone == .redStrong }

  var body: some View {
    HStack(spacing: 4) {
      if let icon {
        Image(systemName: icon)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(text.uppercased())
    }
    .font(.ns(.footnote, .bold))
    .tracking(0.5)
    .foregroundStyle(filled ? NS.onFill : tone.text)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(filled ? tone.color : tone.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 2))
    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(filled ? tone.color : tone.color.opacity(0.5), lineWidth: 1))
  }
}

struct LevelBadge: View {
  let level: String?

  var body: some View {
    let tone = levelTone(level)
    Badge(
      text: levelLabel(level),
      tone: tone,
      icon: tone == .red || tone == .amber ? "exclamationmark.triangle.fill" : nil
    )
    .accessibilityLabel("Level \(levelLabel(level).lowercased())")
  }
}

struct StatusBadge: View {
  let status: String?

  var body: some View {
    Badge(text: statusLabel(status), tone: statusTone(status))
      .accessibilityLabel("Status: \(statusLabel(status))")
  }
}

// MARK: - Cards

struct FlatCard: ViewModifier {
  var fill: Color = NS.surface
  var stroke: Color = NS.border

  func body(content: Content) -> some View {
    content
      .background(fill, in: ChamferedRect())
      .overlay(ChamferedRect().strokeBorder(stroke, lineWidth: 1))
      .contentShape(ChamferedRect())
  }
}

extension View {
  /// Solid card: fill, 1 pt border, chamfered top-right corner.
  func flatCard(fill: Color = NS.surface, stroke: Color = NS.border) -> some View {
    modifier(FlatCard(fill: fill, stroke: stroke))
  }
}

// MARK: - Buttons

/// Full width, 56 pt tall, chamfered, Rajdhani Bold uppercase. Primary is salmon with
/// dark text; secondary is outlined. Haptic on tap (see `FlatButton`).
struct FlatButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, danger, warning }
  var kind: Kind = .secondary
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.ns(.headline, .bold))
      .textCase(.uppercase)
      .tracking(0.6)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity, minHeight: NS.tap)
      .padding(.horizontal, 12)
      .foregroundStyle(foreground)
      .background(background(pressed: configuration.isPressed), in: ChamferedRect())
      .overlay(ChamferedRect().strokeBorder(stroke, lineWidth: 1))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(ChamferedRect())
  }

  private var foreground: Color {
    switch kind {
    case .primary: return NS.onFill
    case .secondary: return NS.textPrimary
    case .danger: return NS.redText
    case .warning: return NS.amberText
    }
  }

  private func background(pressed: Bool) -> Color {
    switch kind {
    case .primary: return pressed ? NS.primaryPressed : NS.primary
    case .secondary: return pressed ? NS.raised : Color.clear
    case .danger: return pressed ? NS.red.opacity(0.25) : Color.clear
    case .warning: return pressed ? NS.amber.opacity(0.25) : Color.clear
    }
  }

  private var stroke: Color {
    switch kind {
    case .primary: return NS.primary
    case .secondary: return NS.border
    case .danger: return NS.redText.opacity(0.7)
    case .warning: return NS.amber.opacity(0.7)
    }
  }
}

/// A main button: flat square style, haptic, VoiceOver label.
struct FlatButton: View {
  let title: String
  var icon: String? = nil
  var kind: FlatButtonStyle.Kind = .secondary
  var accessibilityLabel: String? = nil
  let action: () -> Void

  var body: some View {
    Button {
      Haptics.tap()
      action()
    } label: {
      if let icon {
        Label(title, systemImage: icon)
      } else {
        Text(title)
      }
    }
    .buttonStyle(FlatButtonStyle(kind: kind))
    .accessibilityLabel(accessibilityLabel ?? title)
  }
}

// MARK: - Header and banners

/// Thin header strip with one bottom line, red while an alarm is active.
struct HeaderStrip<Content: View>: View {
  let alarmActive: Bool
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      content
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      Rectangle()
        .fill(alarmActive ? NS.alarmRed : NS.hud.opacity(0.6))
        .frame(height: alarmActive ? 2 : 1)
    }
    .background(NS.background)
  }
}

/// Thin red banner when the backend can't be reached; cached data stays visible.
struct OfflineBanner: View {
  var body: some View {
    Label("Can't reach the console. Everything is saved on the phone and will upload later.", systemImage: "wifi.slash")
      .font(.ns(.subheadline, .semibold))
      .foregroundStyle(NS.amber)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 32)
      .background(NS.amber.opacity(0.12))
      .overlay(alignment: .bottom) { Rectangle().fill(NS.amber.opacity(0.5)).frame(height: 1) }
      .accessibilityLabel("Can't reach the console. Everything is saved on the phone and will upload later.")
  }
}

/// LIVE / REPLAY (time) / OFFLINE pill, shown at the top of every tab.
struct ModePill: View {
  let clock: ServerClock?
  let reachable: Bool?

  private var tone: Tone {
    guard reachable != false else { return .red }
    guard clock != nil else { return .grey }
    return clock?.isReplay == true ? .amber : .green
  }

  private var text: String {
    guard reachable != false else { return "OFFLINE" }
    guard let clock else { return "CHECKING…" }
    guard clock.isReplay else { return "LIVE" }
    let time = clock.nowDate.map { ServerTime.text($0) } ?? clock.now ?? ""
    return time.isEmpty ? "REPLAY" : "REPLAY · \(time)"
  }

  var body: some View {
    Badge(text: text, tone: tone, icon: reachable == false ? "wifi.slash" : (clock?.isReplay == true ? "clock.arrow.circlepath" : "dot.radiowaves.left.and.right"))
      .accessibilityLabel(reachable == false ? "Offline" : (clock?.isReplay == true ? "Replay mode, \(text)" : "Live"))
  }
}

/// Loading / empty / error card with an optional action. Text + icon, never color alone.
struct StateCard: View {
  let title: String
  let detail: String?
  let icon: String
  let tone: Tone
  var actionTitle: String? = nil
  var action: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: icon)
        .font(title == title.uppercased() ? .nsDisplay(.title2) : .ns(.title3, .semibold))
        .foregroundStyle(tone == .grey ? NS.textBody : tone.text)
      if let detail {
        Text(detail)
          .font(.ns(.body))
          .foregroundStyle(NS.textBody)
      }
      if let actionTitle {
        FlatButton(title: actionTitle, icon: "arrow.clockwise", action: action)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .flatCard()
    .accessibilityElement(children: .contain)
  }
}

/// One report's upload state as text + icon (never color alone).
struct ReportStateRow: View {
  let entry: UploadQueue.Entry
  var onRetry: () -> Void = {}

  var body: some View {
    let (text, icon, tone) = describe(entry.state)
    Button {
      if case .failed = entry.state {
        Haptics.tap()
        onRetry()
      }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon).foregroundStyle(tone.text).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Shift report, \(entry.startedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.ns(.body))
            .foregroundStyle(NS.textBody)
          Text(text)
            .font(.nsMono(.subheadline, .semibold))
            .foregroundStyle(tone.text)
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: NS.tap)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint(entry.state.isFailed ? "Tap to retry" : "")
  }

  private func describe(_ state: UploadQueue.State) -> (String, String, Tone) {
    switch state {
    case .sending(let progress):
      return (progress.map { "Sending… \(Int($0 * 100))%" } ?? "Sending…", "arrow.up.circle", .blue)
    case .sent(let at):
      return ("Sent \(at.formatted(date: .omitted, time: .shortened))", "checkmark.circle.fill", .green)
    case .queued:
      return ("Queued — will send when online", "tray.full", .amber)
    case .failed(let message):
      return ("Failed: \(message) Tap to retry.", "exclamationmark.circle.fill", .red)
    }
  }
}

extension UploadQueue.State {
  var isFailed: Bool {
    if case .failed = self { return true }
    return false
  }
}

/// Persistent red banner while GET /alarm keeps failing; stays until a poll succeeds.
struct MonitoringLostBanner: View {
  let lastSuccess: Date?
  /// Plain-words cause, e.g. "Tunnel offline…".
  var reason: String? = nil

  private var text: String {
    let last = lastSuccess.map { $0.formatted(date: .omitted, time: .standard) } ?? "never"
    return "Monitoring lost — last contact \(last)"
  }

  var body: some View {
    VStack(spacing: 2) {
      Label(text, systemImage: "exclamationmark.triangle.fill")
        .font(.nsMono(.headline, .bold))
      if let reason {
        Text(reason)
          .font(.ns(.subheadline, .semibold))
          .multilineTextAlignment(.center)
      }
    }
    .foregroundStyle(NS.onFill)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 44)
    .background(NS.red)
    .accessibilityElement(children: .combine)
  }
}

/// Text tabs with a 2 pt blue underline on the selected one (used for segments).
struct UnderlineSegments<Value: Hashable>: View {
  let options: [(value: Value, title: String)]
  @Binding var selection: Value

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        let selected = option.value == selection
        Button {
          Haptics.tap()
          selection = option.value
        } label: {
          VStack(spacing: 0) {
            Text(option.title)
              .font(.ns(.headline))
              .foregroundStyle(selected ? NS.accent : NS.textMuted)
              .frame(maxWidth: .infinity, minHeight: NS.tap - 2)
            Rectangle()
              .fill(selected ? NS.accent : Color.clear)
              .frame(height: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .overlay(alignment: .bottom) { Rectangle().fill(NS.border).frame(height: 1) }
  }
}

/// "Updated 12s ago", amber when older than 30 s.
struct UpdatedAgo: View {
  let date: Date?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let seconds = date.map { max(0, Int(context.date.timeIntervalSince($0))) }
      Text(seconds.map { "Updated \($0)s ago" } ?? "Not updated yet")
        .font(.nsMono(.subheadline))
        .foregroundStyle((seconds ?? 999) > 30 ? NS.amberText : NS.textSecondary)
    }
  }
}

/// Server / data times. EOG's data and the backend clock are UTC, and the dashboard
/// shows them in UTC, so the phone does too (in the phone's own zone they read hours
/// off, e.g. 5 h behind in CDT). Phone events (flags, shift start, uploads) stay local.
enum ServerTime {
  private static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!

  /// "Oct 10 at 3:30 PM UTC"
  static func text(_ date: Date) -> String {
    var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
    style.timeZone = utc
    return "\(date.formatted(style)) UTC"
  }

  /// "Saturday, 3:30 PM UTC" for speech.
  static func spoken(_ date: Date) -> String {
    var style = Date.FormatStyle.dateTime.weekday(.wide).hour().minute()
    style.timeZone = utc
    return "\(date.formatted(style)) UTC"
  }

  /// ISO 8601 from the server ("...Z", an offset, or naive = UTC, like the backend's
  /// parse_ts).
  static func parse(_ iso: String) -> Date? {
    let s = iso.trimmingCharacters(in: .whitespaces)
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for candidate in [s, s + "Z"] {
      if let date = plain.date(from: candidate) ?? fractional.date(from: candidate) { return date }
    }
    return nil
  }

  /// A server ISO string as UTC text; the raw string if it can't be read.
  static func text(_ iso: String) -> String {
    parse(iso).map { text($0) } ?? iso
  }
}

/// Hours left as "2.1 h left" with monospaced digits.
func hoursLeftText(_ hours: Double) -> String {
  "\(hours.formatted(.number.precision(.fractionLength(1)))) h left"
}
