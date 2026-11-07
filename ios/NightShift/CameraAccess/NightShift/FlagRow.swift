//
// FlagRow.swift
//
// One flag: photo, type, facility, status, and notes.
//

import SwiftUI

struct FlagRow: View {
  let flag: Flag
  let photoURL: URL?
  let facilityName: String?

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
          Spacer()
          Text(flag.status.rawValue)
            .font(.caption.bold())
            .foregroundStyle(statusColor)
        }
        Text("\(facilityName ?? "Unknown facility") · \(flag.createdAt.formatted(date: .omitted, time: .shortened))")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(flag.notes) { note in
          Label(note.text, systemImage: "quote.bubble")
            .font(.caption)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var statusColor: Color {
    switch flag.status {
    case .waiting: return .orange
    case .confirmed: return .red
    case .dismissed: return .secondary
    }
  }
}
