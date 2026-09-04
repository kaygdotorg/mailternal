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
        // The popover supplies the chrome (material, border, arrow): the card
        // paints nothing of its own and scrolls as one piece.
        ScrollView(.vertical, showsIndicators: false) {
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
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, ReaderTabTokens.previewHorizontalPadding)
            .padding(.vertical, ReaderTabTokens.previewVerticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            width: ReaderTabTokens.previewWidth,
            height: ReaderTabTokens.previewHeight,
            alignment: .topLeading
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIIdentifier.readerHoverCard)
        .accessibilityLabel("Preview of \(subject)")
    }
}
