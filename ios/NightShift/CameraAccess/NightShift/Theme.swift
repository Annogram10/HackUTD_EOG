//
// Theme.swift
//
// NightShift design system, copied from the web dashboard: flat dark theme, grey
// surfaces with 1 pt borders, no shadows, gradients or blur, square corners
// everywhere. Color means status only; blue is the one accent for tappable things.
// Every status color is paired with a text label.
//

import SwiftUI
import UIKit

enum NS {
  // MARK: Colors

  static let background = Color(hex: 0x0E0F11)
  static let surface = Color(hex: 0x17191C)
  static let raised = Color(hex: 0x22252A)
  static let border = Color(hex: 0x32363D)
  static let borderStrong = Color(hex: 0x4D535C)
  static let textMuted = Color(hex: 0x8B929C)
  static let textSecondary = Color(hex: 0xA9AFB8)
  static let textBody = Color(hex: 0xC8CCD2)
  static let textPrimary = Color(hex: 0xECEEF1)

  static let accent = Color(hex: 0x5A9BF0)
  static let accentPressed = Color(hex: 0x2F6FD6)

  static let green = Color(hex: 0x3FB97F)
  static let greenStrong = Color(hex: 0x2C9C67)
  static let amber = Color(hex: 0xF2B33D)
  static let amberText = Color(hex: 0xF6C76A)
  static let red = Color(hex: 0xE5484D)
  static let redText = Color(hex: 0xF5A3A5)
  static let alarmRed = Color(hex: 0xE5484D)

  /// Minimum tap target.
  static let tap: CGFloat = 56
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

/// 1 pt ring at ~40% of the status color, ~15% tinted fill, lighter text, square.
struct Badge: View {
  let text: String
  let tone: Tone
  var icon: String? = nil

  var body: some View {
    HStack(spacing: 4) {
      if let icon {
        Image(systemName: icon)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(text)
    }
    .font(.footnote.weight(.medium))
    .foregroundStyle(tone.text)
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(tone.color.opacity(tone.fillOpacity))
    .overlay(Rectangle().strokeBorder(tone.color.opacity(0.4), lineWidth: 1))
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
      .background(fill)
      .overlay(Rectangle().strokeBorder(stroke, lineWidth: 1))
  }
}

extension View {
  /// Flat square card: surface fill and a 1 pt border.
  func flatCard(fill: Color = NS.surface, stroke: Color = NS.border) -> some View {
    modifier(FlatCard(fill: fill, stroke: stroke))
  }
}

// MARK: - Buttons

/// Square, flat, at least 56 pt tall. Haptic on tap (see `FlatButton`).
struct FlatButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, danger, warning }
  var kind: Kind = .secondary
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity, minHeight: NS.tap)
      .padding(.horizontal, 12)
      .foregroundStyle(foreground)
      .background(background(pressed: configuration.isPressed))
      .overlay(Rectangle().strokeBorder(stroke, lineWidth: 1))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Rectangle())
  }

  private var foreground: Color {
    switch kind {
    case .primary: return NS.background
    case .secondary: return NS.textPrimary
    case .danger: return NS.redText
    case .warning: return NS.amberText
    }
  }

  private func background(pressed: Bool) -> Color {
    switch kind {
    case .primary: return pressed ? NS.accentPressed : NS.accent
    case .secondary: return pressed ? NS.border : NS.raised
    case .danger: return NS.red.opacity(pressed ? 0.3 : 0.15)
    case .warning: return NS.amber.opacity(pressed ? 0.3 : 0.15)
    }
  }

  private var stroke: Color {
    switch kind {
    case .primary: return NS.accent
    case .secondary: return NS.borderStrong
    case .danger: return NS.red.opacity(0.4)
    case .warning: return NS.amber.opacity(0.4)
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
        .fill(alarmActive ? NS.alarmRed : NS.border)
        .frame(height: alarmActive ? 2 : 1)
    }
    .background(NS.background)
  }
}

/// Thin red banner when the backend can't be reached; cached data stays visible.
struct OfflineBanner: View {
  var body: some View {
    Label("Offline. Showing saved data.", systemImage: "wifi.slash")
      .font(.subheadline.weight(.medium))
      .foregroundStyle(NS.redText)
      .frame(maxWidth: .infinity, minHeight: 28)
      .background(NS.red.opacity(0.15))
      .overlay(alignment: .bottom) { Rectangle().fill(NS.red.opacity(0.4)).frame(height: 1) }
      .accessibilityLabel("Offline. Showing saved data.")
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
    let time = clock.nowDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? clock.now ?? ""
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
        .font(.title3.weight(.semibold))
        .foregroundStyle(tone == .grey ? NS.textBody : tone.text)
      if let detail {
        Text(detail)
          .font(.body)
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
            .font(.body)
            .foregroundStyle(NS.textBody)
          Text(text)
            .font(.subheadline.weight(.semibold).monospacedDigit())
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

  private var text: String {
    let last = lastSuccess.map { $0.formatted(date: .omitted, time: .standard) } ?? "never"
    return "Monitoring lost — last contact \(last)"
  }

  var body: some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.headline.monospacedDigit())
      .foregroundStyle(NS.textPrimary)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(NS.red)
      .accessibilityLabel(text)
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
              .font(.headline)
              .foregroundStyle(selected ? NS.textPrimary : NS.textSecondary)
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
        .font(.subheadline.monospacedDigit())
        .foregroundStyle((seconds ?? 999) > 30 ? NS.amberText : NS.textSecondary)
    }
  }
}

/// Hours left as "2.1 h left" with monospaced digits.
func hoursLeftText(_ hours: Double) -> String {
  "\(hours.formatted(.number.precision(.fractionLength(1)))) h left"
}
