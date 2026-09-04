import AppKit
import SwiftUI

/// The sender mark shared by the reader header, tabs, and message-list rows.
/// A favicon is rendered aspect-fill and clipped to the same circle as the
/// initial fallback; the AppKit renderer below keeps the table view SwiftUI-free.
struct SenderGlyph: View {
    let favicon: NSImage?
    let initials: String
    let accent: Color
    var diameter: CGFloat = 26

    var body: some View {
        Group {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } else {
                MonogramView(initials: initials, accent: accent, diameter: diameter)
                    .frame(width: diameter, height: diameter)
            }
        }
        .accessibilityHidden(true)
    }

    /// Produces the equivalent glyph for an AppKit row without doing any
    /// network or disk work. `favicon` must already be a cached image.
    @MainActor
    static func nsImage(
        favicon: NSImage?,
        initials: String,
        accent: NSColor,
        diameter: CGFloat
    ) -> NSImage {
        let size = max(diameter, 1)
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        defer { result.unlockFocus() }

        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let circle = NSBezierPath(ovalIn: bounds)
        if let favicon, favicon.size.width > 0, favicon.size.height > 0 {
            NSColor.controlBackgroundColor.setFill()
            circle.fill()
            circle.addClip()
            let source = favicon.size
            let scale = max(size / source.width, size / source.height)
            let fitted = NSSize(width: source.width * scale, height: source.height * scale)
            let destination = NSRect(
                x: (size - fitted.width) / 2,
                y: (size - fitted.height) / 2,
                width: fitted.width,
                height: fitted.height
            )
            favicon.draw(
                in: destination,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        } else {
            accent.withAlphaComponent(0.15).setFill()
            circle.fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(size * 0.42, 9), weight: .semibold),
                .foregroundColor: accent,
                .paragraphStyle: style
            ]
            let text = NSString(string: initials)
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                in: NSRect(
                    x: 0,
                    y: (size - textSize.height) / 2,
                    width: size,
                    height: textSize.height
                ),
                withAttributes: attributes
            )
        }
        return result
    }

    /// A rendered sender name is what the message-list model exposes. Keep
    /// the fallback deterministic and aligned with the reader's initials rule.
    static func initials(for renderedSender: String) -> String {
        let words = renderedSender.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2,
           let first = words[0].first,
           let second = words[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String((words.first?.prefix(2) ?? "?")).uppercased()
    }
}

/// A small accent wash keeps the monogram legible without fetching an avatar.
struct MonogramView: View {
    let initials: String
    let accent: Color
    var diameter: CGFloat = 26

    var body: some View {
        Text(initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .frame(width: diameter, height: diameter)
            .background(accent.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}
