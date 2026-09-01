import AppKit
import SwiftUI
import MailternalInterfaces

enum AppShapeScale {
    static let window: CGFloat = 24
    static let card: CGFloat = 18
    static let toast: CGFloat = 14
    static let row: CGFloat = 12
}

enum MessageTypography {
    static let bodyPointSize: CGFloat = 13
    static let bodyLineSpacing: CGFloat = 2
    static let bodyLineHeight: CGFloat = 18
    static let paragraphGap: CGFloat = 10
    /// Sample used to average glyph width; the reading measure is expressed in
    /// characters, and mail bodies are mixed case.
    private static let measureSample = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ"

    /// Width of `MessageViewerLayoutPolicy.plainTextMeasureCharacters` average
    /// body glyphs. Plain text wraps here inside the full-width body region;
    /// HTML and raw source are never measured this way. Measured once: the
    /// body font is fixed, so every reader render can read the same number.
    static let plainTextMeasure: CGFloat = {
        let width = (measureSample as NSString).size(withAttributes: [.font: bodyFont]).width
        let perCharacter = width / CGFloat(measureSample.count)
        return ceil(perCharacter * CGFloat(MessageViewerLayoutPolicy.plainTextMeasureCharacters))
    }()

    static var bodyFont: NSFont {
        .systemFont(ofSize: bodyPointSize)
    }

    static var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = bodyLineHeight
        style.maximumLineHeight = bodyLineHeight
        style.lineSpacing = bodyLineSpacing
        style.paragraphSpacing = paragraphGap
        return style
    }
}

/// The reader's region surfaces: one opaque tone per region, so subject,
/// envelope, and body separate by material weight instead of by cards, blur,
/// or glass. Nothing here is translucent, so Reduce Transparency needs no
/// fallback. A later theme retints these values; call sites never name a color.
enum MessageReaderSurface {
    /// Subject band — one step further from the page than the envelope, so the
    /// title reads as chrome continuing under the window's dissolve.
    static var subject: Color {
        Color(nsColor: .windowBackgroundColor).mix(with: Color(nsColor: .textColor), by: 0.06)
    }

    /// Envelope band — window chrome tone, distinct from the reading page.
    static var envelope: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    /// The reading page, and the scroll canvas behind it.
    static var page: Color {
        Color(nsColor: .textBackgroundColor)
    }

    /// Hairline between regions. Increased contrast trades the hairline for a
    /// separator that survives a strengthened palette.
    static func divider(increasedContrast: Bool) -> Color {
        Color(nsColor: increasedContrast ? .tertiaryLabelColor : .separatorColor)
    }
}

enum MailMotion {
    static let sidebarToggle = Animation.snappy(duration: 0.24, extraBounce: 0)
    static let disclosure = Animation.easeOut(duration: 0.12)
    static let hover = Animation.easeOut(duration: 0.12)
    static let searchPanel = Animation.spring(response: 0.36, dampingFraction: 1)
    static let searchPanelReduced = Animation.easeOut(duration: 0.18)
    static let composer = Animation.smooth(duration: 0.18)

    static func searchPanel(reduceMotion: Bool) -> Animation {
        reduceMotion ? searchPanelReduced : searchPanel
    }
}

enum OutgoingForegroundPolicy {
    static let crossoverLuminance: CGFloat = 0.179128784747792

    static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func prefersBlackText(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        relativeLuminance(red: red, green: green, blue: blue) > crossoverLuminance
    }

    static func prefersBlackText(on color: NSColor) -> Bool {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return prefersBlackText(
            red: srgb.redComponent,
            green: srgb.greenComponent,
            blue: srgb.blueComponent
        )
    }

    private static func linear(_ component: CGFloat) -> CGFloat {
        let value = min(max(component, 0), 1)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

extension FolderRole {
    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .archive: "archivebox"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .none: "folder"
        }
    }
}
