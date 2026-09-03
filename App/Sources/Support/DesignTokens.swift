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

enum MailMotion {
    /// A critically damped spring gives NavigationSplitView's sidebar width
    /// time to settle without the end-of-collapse jump of a short snappy.
    static let sidebarToggle = Animation.spring(duration: 0.28, bounce: 0.0)
    static let disclosure = Animation.easeOut(duration: 0.12)
    /// Row expansion in settings lists: the card grows to fit revealed content
    /// with no overshoot, so the reveal reads as growth rather than a jump.
    static let expand = Animation.spring(duration: 0.32, bounce: 0)
    /// Settings editors grow without overshoot and collapse quickly enough to
    /// keep the surrounding List's row rhythm feeling immediate.
    static let accountEditorCollapse = Animation.easeOut(duration: 0.14)
    /// The source island should acknowledge the toggle immediately while its
    /// height still eases cleanly into the detailed header layout.
    static let sourceMorph = Animation.easeOut(duration: 0.17)
    static let hover = Animation.easeOut(duration: 0.12)
    static let searchPanel = Animation.spring(response: 0.36, dampingFraction: 1)
    static let searchPanelReduced = Animation.easeOut(duration: 0.18)
    static let composer = Animation.smooth(duration: 0.18)
    static let settle = Animation.spring(duration: 0.32, bounce: 0.22)

    static func searchPanel(reduceMotion: Bool) -> Animation {
        reduceMotion ? searchPanelReduced : searchPanel
    }

    /// On the way out the card snaps away first and the backdrop clears
    /// after it: card exit is quick, the backdrop starts fading once the
    /// card is gone and takes its normal fade.
    static let searchCardExitDuration: TimeInterval = 0.12
    static let searchCardExit = Animation.easeIn(duration: searchCardExitDuration)
    static let searchBackdropExit = Animation.easeOut(duration: 0.22).delay(searchCardExitDuration)
    /// Wall time until both have finished; the overlay is removed then.
    static let searchDismissDuration: TimeInterval = searchCardExitDuration + 0.22
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
