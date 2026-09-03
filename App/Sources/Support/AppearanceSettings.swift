import AppKit
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

public enum EmailReadingMode: String, CaseIterable, Identifiable {
    case original, dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .original: "Original"
        case .dark: "Dark"
        }
    }
}

enum WindowBackdropStyle: String, CaseIterable, Identifiable {
    case clearGlass, frostedBlur, regularGlass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clearGlass: "Clear glass"
        case .frostedBlur: "Frosted blur"
        case .regularGlass: "Regular glass"
        }
    }
}

struct AccentColorValue: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }
}
/// Owns the persisted custom accent and resolves the one canonical accent used by
/// SwiftUI and AppKit. `color` and `nsColor` are views of the same resolved value;
/// the system accent is never persisted, and changing the override is observable
/// so every injected consumer updates without a restart or window reopen.
/// Semantic warning, error, and content colors remain outside this module.
@MainActor
@Observable
final class AccentSource {
    var accentOverride: AccentColorValue? {
        didSet {
            guard oldValue != accentOverride else { return }
            if let accentOverride {
                defaults.set(
                    [accentOverride.red, accentOverride.green, accentOverride.blue, accentOverride.alpha],
                    forKey: Self.defaultsKey
                )
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    /// The current accent, resolving the system value on every access.
    var nsColor: NSColor {
        accentOverride?.nsColor ?? .controlAccentColor
    }

    /// SwiftUI's view of `nsColor`; neither representation stores a second value.
    var color: Color {
        Color(nsColor: nsColor)
    }

    private static let defaultsKey = "mailternal.appearance.accent"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let values = defaults.array(forKey: Self.defaultsKey) as? [Double], values.count == 4 {
            accentOverride = AccentColorValue(
                red: values[0],
                green: values[1],
                blue: values[2],
                alpha: values[3]
            )
        } else {
            accentOverride = nil
        }
    }
}

/// Owns persisted appearance choices; `accent` is the sole accent source.
/// Its custom override is the only persisted accent input, and all true accent
/// surfaces consume `AccentSource` rather than deriving colors independently.
/// Semantic warning, error, quarantine, find-highlight, and email-content colors
/// are intentionally not part of the accent interface.
@MainActor
@Observable
final class AppearanceSettings {
    let accent: AccentSource
    var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: Keys.mode)
            applyAppKitAppearance()
        }
    }
    var emailReadingMode: EmailReadingMode {
        didSet {
            guard oldValue != emailReadingMode else { return }
            defaults.set(emailReadingMode.rawValue, forKey: Keys.emailReadingMode)
        }
    }

    var showsSenderIcons: Bool {
        didSet {
            guard oldValue != showsSenderIcons else { return }
            defaults.set(showsSenderIcons, forKey: Keys.showsSenderIcons)
        }
    }

    var backgroundOpacity: Double {
        didSet {
            let clamped = Self.clampBackgroundOpacity(backgroundOpacity)
            if clamped != backgroundOpacity {
                backgroundOpacity = clamped
                return
            }
        }
    }

    var backdropStyle: WindowBackdropStyle {
        didSet {
            guard oldValue != backdropStyle else { return }
            defaults.set(backdropStyle.rawValue, forKey: Keys.backdropStyle)
        }
    }

    /// Number of visible lines in each message-list row, including the subject.
    ///
    /// One line keeps only the subject; two lines add sender/date; subsequent
    /// lines reveal the message preview.
    var messageListLines: Int {
        didSet {
            let clamped = Self.clampMessageListLines(messageListLines)
            if clamped != messageListLines {
                messageListLines = clamped
                return
            }
            guard oldValue != messageListLines else { return }
            defaults.set(messageListLines, forKey: Keys.messageListLines)
        }
    }

    static let defaultMessageListLines = 3
    static let messageListLineRange = 1...6
    static let defaultBackgroundOpacity = 0.25
    /// Incremented when a persisted preference's meaning changes. Values
    /// written by older builds are migrated exactly once per suite.
    static let defaultsVersion = 3
    /// The full dial the settings slider offers. 100% resolves to a solid
    /// window; anything below it shows the chosen treatment, down to a window
    /// that adds no fill of its own at 0%.
    static let backgroundOpacityRange = 0.0...1.0

    static func clampMessageListLines(_ value: Int) -> Int {
        min(max(value, messageListLineRange.lowerBound), messageListLineRange.upperBound)
    }

    static func clampBackgroundOpacity(_ value: Double) -> Double {
        value.isFinite
            ? min(max(value, 0), 1)
            : defaultBackgroundOpacity
    }

    static func formattedOpacityPercentage(_ value: Double) -> String {
        let clamped = clampBackgroundOpacity(value)
        return "\(Int((clamped * 100).rounded()))%"
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.accent = AccentSource(defaults: defaults)

        let storedStyle = defaults.string(forKey: Keys.backdropStyle)
            .flatMap(WindowBackdropStyle.init(rawValue:))
        let legacyToggle = defaults.object(forKey: Keys.legacyUsesLiquidGlass) != nil
            ? defaults.bool(forKey: Keys.legacyUsesLiquidGlass)
            : nil
        let legacyBackdrop = defaults.string(forKey: Keys.legacyBackdrop)
        let hasStoredOpacity = defaults.object(forKey: Keys.opacity) != nil
        let storedOpacity = hasStoredOpacity ? defaults.double(forKey: Keys.opacity) : nil
        let storedVersion = defaults.object(forKey: Keys.defaultsVersion) == nil
            ? 0
            : defaults.integer(forKey: Keys.defaultsVersion)
        let shouldMigrateLegacyBackdropStyle = storedVersion < Self.defaultsVersion
        // v1 moved an unwritten 1.0 to the then-default; v3 moves an
        // unwritten 0.80 (the v1/v2 default) to the current default. A value
        // the user set from the slider is never touched.
        let shouldMigrateLegacyFullOpacity =
            !defaults.bool(forKey: Keys.opacityUserWritten)
            && ((storedVersion == 0 && storedOpacity == 1)
                || (storedVersion < 3 && storedOpacity == 0.80))

        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .system
        emailReadingMode = EmailReadingMode(
            rawValue: defaults.string(forKey: Keys.emailReadingMode) ?? ""
        ) ?? .original
        showsSenderIcons = defaults.bool(forKey: Keys.showsSenderIcons)

        let resolvedOpacity = Self.clampBackgroundOpacity(
            shouldMigrateLegacyFullOpacity
                ? Self.defaultBackgroundOpacity
                : (storedOpacity ?? Self.defaultBackgroundOpacity)
        )
        let resolvedStyle: WindowBackdropStyle
        if let storedStyle {
            resolvedStyle = storedStyle
        } else if shouldMigrateLegacyBackdropStyle, let legacyToggle {
            resolvedStyle = legacyToggle ? .regularGlass : .frostedBlur
        } else if shouldMigrateLegacyBackdropStyle, let legacyBackdrop {
            switch legacyBackdrop {
            case "glass":
                resolvedStyle = .regularGlass
            case "blur", "opaque":
                resolvedStyle = .frostedBlur
            default:
                resolvedStyle = .frostedBlur
            }
        } else {
            resolvedStyle = .frostedBlur
        }
        backdropStyle = resolvedStyle
        backgroundOpacity = resolvedOpacity
        defaults.set(resolvedStyle.rawValue, forKey: Keys.backdropStyle)
        defaults.removeObject(forKey: Keys.legacyUsesLiquidGlass)
        defaults.removeObject(forKey: Keys.legacyBackdrop)

        if let storedLines = defaults.object(forKey: Keys.messageListLines) as? NSNumber {
            let normalizedLines = Self.clampMessageListLines(storedLines.intValue)
            messageListLines = normalizedLines
            if normalizedLines != storedLines.intValue {
                defaults.set(normalizedLines, forKey: Keys.messageListLines)
            }
        } else {
            messageListLines = Self.defaultMessageListLines
        }

        if shouldMigrateLegacyFullOpacity {
            defaults.set(resolvedOpacity, forKey: Keys.opacity)
        } else if !hasStoredOpacity {
            defaults.set(resolvedOpacity, forKey: Keys.opacity)
        }
        defaults.set(max(storedVersion, Self.defaultsVersion), forKey: Keys.defaultsVersion)
        applyAppKitAppearance()
    }

    func persistOpacity() {
        defaults.set(backgroundOpacity, forKey: Keys.opacity)
        defaults.set(true, forKey: Keys.opacityUserWritten)
    }

    func applyAppKitAppearance() {
        // NSApp is nil until NSApplication is created; .shared creates it on demand,
        // so this is safe during early init and headless launches.
        NSApplication.shared.appearance = mode.nsAppearance
    }

    private enum Keys {
        static let mode = "mailternal.appearance.mode"
        static let backdropStyle = "mailternal.appearance.backdropStyle"
        static let legacyBackdrop = "mailternal.appearance.backdrop"
        static let legacyUsesLiquidGlass = "mailternal.appearance.usesLiquidGlass"
        static let opacity = "mailternal.appearance.opacity"
        static let opacityUserWritten = "mailternal.appearance.opacity-user-written"
        static let defaultsVersion = "mailternal.appearance.defaultsVersion"
        static let messageListLines = "mailternal.appearance.message-list-lines"
        static let emailReadingMode = "mailternal.appearance.email-reading"
        static let showsSenderIcons = "mailternal.appearance.showsSenderIcons"
    }
}
