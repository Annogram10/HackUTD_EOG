//
// FlagRow.swift
//
// One flag: photo, type, description (camera flags), facility, status, and notes.
// Pending flags get Confirm and Dismiss buttons; every flag can take a note.
//

import SwiftUI

struct FlagRow: View {
  let flag: Flag
  let photoURL: URL?
  let facilityName: String?
  var onConfirm: () -> Void = {}
  var onDismiss: () -> Void = {}
  var onAddNote: () -> Void = {}

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AsyncImage(url: photoURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Color.secondary.opacity(0.2)
          .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
      }
      .frame(width: 64, height: 86)
      .clipShape(RoundedRectangle(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(flag.type)
            .font(.subheadline.bold())
            .strikethrough(flag.status == .dismissed)
          if flag.source == "voice" {
            Text("voice")
              .font(.caption2)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.secondary.opacity(0.2), in: Capsule())
          }
          Spacer()
          Label(flag.status.rawValue, systemImage: statusIcon)
            .font(.caption.bold())
            .foregroundStyle(statusColor)
        }
        if let description = flag.description, !description.isEmpty {
          Text(description)
            .font(.caption)
            .lineLimit(1)
        }
        Text("\(facilityName ?? "Unknown facility") · \(flag.createdAt.formatted(date: .omitted, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(flag.notes) { note in
          Label(note.text, systemImage: "quote.bubble")
            .font(.caption)
        }
        // Bordered styles keep each button separately tappable inside a List row.
        HStack(spacing: 8) {
          if flag.status == .pending {
            Button("Confirm", systemImage: "checkmark", action: onConfirm)
              .buttonStyle(.borderedProminent)
              .tint(.red)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
              .buttonStyle(.bordered)
          }
          Button("Note", systemImage: "square.and.pencil", action: onAddNote)
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.top, 2)
      }
    }
    .padding(.vertical, 2)
    .opacity(flag.status == .dismissed ? 0.55 : 1)
    .listRowBackground(flag.status == .pending ? Color.orange.opacity(0.12) : nil)
  }

  private var statusIcon: String {
    switch flag.status {
    case .pending: return "clock"
    case .confirmed: return "checkmark.seal.fill"
    case .dismissed: return "xmark.circle"
    }
  }

  private var statusColor: Color {
    switch flag.status {
    case .pending: return .orange
    case .confirmed: return .red
    case .dismissed: return .secondary
    }
  }
}
