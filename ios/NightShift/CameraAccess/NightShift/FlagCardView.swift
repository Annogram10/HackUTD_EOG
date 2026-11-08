//
// FlagCardView.swift
//
// The flag card shown when the camera (or voice) raises a flag: photo, "POSSIBLE LEAK",
// facility, time, the vision description, a CAMERA/VOICE badge, and CONFIRM / DISMISS.
// Voice "confirm" / "dismiss" change the same flag, so the card follows the stored
// status: once decided it shows "SAVED · CONFIRMED" (or DISMISSED) briefly, then closes.
//

import SwiftUI

struct FlagCardView: View {
  var controller: NightShiftController
  let flagID: Flag.ID
  /// Called after the "SAVED" toast, or on Close.
  let onClose: () -> Void
  @State private var savedText: String?

  private var shift: ShiftRecord? { controller.store.current }
  private var flag: Flag? { shift?.flags.first { $0.id == flagID } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let flag, let shift {
        content(flag, shift: shift)
      } else {
        Text("This flag is no longer on the phone.")
          .font(.ns(.body))
          .foregroundStyle(NS.textMuted)
        FlatButton(title: "Close", kind: .secondary, action: onClose)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .flatCard(fill: NS.surface, stroke: NS.borderStrong)
    .overlay(alignment: .center) {
      if let savedText {
        Text(savedText)
          .font(.nsMono(.headline, .bold))
          .foregroundStyle(NS.onFill)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(NS.primary, in: ChamferedRect())
          .accessibilityLabel(savedText)
      }
    }
    // A voice decision (or a tap) moves the flag out of pending: confirm it saved, close.
    .onChange(of: flag?.status) { _, status in
      guard let status, status != .pending, savedText == nil else { return }
      showSaved(status)
    }
  }

  @ViewBuilder
  private func content(_ flag: Flag, shift: ShiftRecord) -> some View {
    let place = flag.facility.flatMap { id in controller.map?.facilities.first { $0.id == id }?.displayName } ?? flag.facility ?? "Unknown facility"
    if let url = controller.store.photoURL(for: flag, in: shift) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Rectangle().fill(NS.raised)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 170)
      .clipShape(ChamferedRect())
      .accessibilityLabel("Photo of the possible \(flag.type)")
    }
    HStack(alignment: .firstTextBaseline) {
      Text("POSSIBLE \(flag.type.uppercased())")
        .font(.nsDisplay(.title))
        .foregroundStyle(NS.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Badge(text: flag.source == "voice" ? "Voice" : "Camera", tone: .blue, icon: flag.source == "voice" ? "mic.fill" : "camera.fill")
    }
    HStack(spacing: 10) {
      Text(place)
        .font(.ns(.headline, .semibold))
        .foregroundStyle(NS.textPrimary)
      Text(flag.createdAt.formatted(date: .omitted, time: .standard))
        .font(.nsMono(.subheadline))
        .foregroundStyle(NS.textMuted)
    }
    if let description = flag.description {
      Text(description)
        .font(.ns(.body))
        .foregroundStyle(NS.textMuted)
        .lineLimit(2)
    }
    if flag.status == .pending {
      AdaptiveStack(spacing: 10) {
        FlatButton(title: "Confirm", icon: "checkmark", kind: .primary,
                   accessibilityLabel: "Confirm possible \(flag.type) at \(place)") {
          controller.decide(flag.id, as: .confirmed)
        }
        FlatButton(title: "Dismiss", icon: "xmark", kind: .secondary,
                   accessibilityLabel: "Dismiss possible \(flag.type) at \(place)") {
          controller.decide(flag.id, as: .dismissed)
        }
      }
    } else {
      HStack {
        Badge(text: flag.status.rawValue, tone: flag.status == .confirmed ? .amber : .grey)
        Spacer()
        Button("Close") { onClose() }
          .font(.ns(.headline, .bold))
          .foregroundStyle(NS.accent)
          .frame(minWidth: 56, minHeight: 44)
      }
    }
  }

  private func showSaved(_ status: FlagStatus) {
    savedText = status == .confirmed ? "SAVED · CONFIRMED" : "SAVED · DISMISSED"
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    Task {
      try? await Task.sleep(for: .milliseconds(1200))
      onClose()
    }
  }
}

/// Presents the newest flag card over the LIVE tab when a pending flag appears.
struct FlagCardOverlay: ViewModifier {
  var controller: NightShiftController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shownFlagID: Flag.ID?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let shownFlagID {
          FlagCardView(controller: controller, flagID: shownFlagID) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { self.shownFlagID = nil }
          }
          .padding(12)
          .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
      }
      // A newly raised flag that still needs a decision slides up.
      .onChange(of: controller.store.current?.flags.last?.id) { _, newID in
        guard let newID, controller.store.current?.flags.last?.status == .pending else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
          shownFlagID = newID
        }
      }
  }
}

extension View {
  func flagCardOverlay(controller: NightShiftController) -> some View {
    modifier(FlagCardOverlay(controller: controller))
  }
}
