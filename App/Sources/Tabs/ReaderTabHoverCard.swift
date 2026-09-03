import AppKit
import SwiftUI

/// The local preview shown while a pointer rests on a reader tab. The card is
/// deliberately data-only: callers pass already available row/detail values,
/// so presenting it never starts a fetch or changes reader state.
struct ReaderTabHoverCard: View {
    let subject: String
    let preview: String
    let sender: String?
    let receivedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sender, !sender.isEmpty {
                HStack(spacing: 6) {
                    Text(sender)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let receivedDate {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(receivedDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Text(subject)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)

            Text(preview.isEmpty ? "No preview available." : preview)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .truncationMode(.tail)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, ReaderTabTokens.previewHorizontalPadding)
        .padding(.vertical, ReaderTabTokens.previewVerticalPadding)
        .frame(width: ReaderTabTokens.previewWidth, alignment: .topLeading)
        .frame(maxHeight: ReaderTabTokens.previewMaximumHeight, alignment: .topLeading)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(
                cornerRadius: ReaderTabTokens.previewCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: ReaderTabTokens.previewCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.black.opacity(0.48), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIIdentifier.readerHoverCard)
        .accessibilityLabel("Preview of \(subject)")
    }
}
