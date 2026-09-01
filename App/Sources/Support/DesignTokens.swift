import AppKit
import SwiftUI
import MailternalInterfaces

enum AppShapeScale {
    static let window: CGFloat = 24
    static let card: CGFloat = 18
    static let toast: CGFloat = 14
    static let row: CGFloat = 12
    static let compact: CGFloat = 8
}

enum MessageTypography {
    static let bodyPointSize: CGFloat = 13
    static let bodyLineSpacing: CGFloat = 2
    static let bodyLineHeight: CGFloat = 18
    static let paragraphGap: CGFloat = 10
    static let readingMeasure: CGFloat = 490
    static let transcriptInset: CGFloat = 20

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

enum MailDateFormat {
    private static let time: Date.FormatStyle = .dateTime.hour().minute()
    private static let absolute: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()
    private static let weekday: Date.FormatStyle = .dateTime.weekday(.wide)

    static func listRow(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.relative(presentation: .named, unitsStyle: .narrow))
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekAgo {
            return date.formatted(weekday)
        }
        return date.formatted(absolute)
    }

    static func envelope(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
    }

    static func syncedThrough(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
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

    var sortRank: Int {
        switch self {
        case .inbox: 0
        case .drafts: 1
        case .sent: 2
        case .archive: 3
        case .junk: 4
        case .trash: 5
        case .none: 6
        }
    }
}

private struct MailternalAccentColorKey: EnvironmentKey {
    static let defaultValue = Color(nsColor: .controlAccentColor)
}

extension EnvironmentValues {
    var mailternalAccentColor: Color {
        get { self[MailternalAccentColorKey.self] }
        set { self[MailternalAccentColorKey.self] = newValue }
    }
}
