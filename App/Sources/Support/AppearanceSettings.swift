import AppKit
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

enum WindowBackdropKind: String, CaseIterable, Identifiable {
    case opaque, blur, glass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .opaque: "Opaque"
        case .blur: "Blur"
        case .glass: "Liquid Glass"
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

@MainActor
@Observable
final class AppearanceSettings {
    var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: Keys.mode)
            applyAppKitAppearance()
        }
    }

    var accentOverride: AccentColorValue? {
        didSet {
            guard oldValue != accentOverride else { return }
            if let accentOverride {
                defaults.set(
                    [accentOverride.red, accentOverride.green, accentOverride.blue, accentOverride.alpha],
                    forKey: Keys.accent
                )
            } else {
                defaults.removeObject(forKey: Keys.accent)
            }
        }
    }

    var backgroundOpacity: Double {
        didSet {
            let clamped = min(max(backgroundOpacity, 0), 1)
            if clamped != backgroundOpacity {
                backgroundOpacity = clamped
                return
            }
        }
    }

    var backdropKind: WindowBackdropKind {
        didSet {
            guard oldValue != backdropKind else { return }
            defaults.set(backdropKind.rawValue, forKey: Keys.backdrop)
        }
    }

    var effectiveAccentColor: NSColor {
        accentOverride?.nsColor ?? .controlAccentColor
    }

    var effectiveAccentSwiftUI: Color {
        Color(nsColor: effectiveAccentColor)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .system
        backdropKind = WindowBackdropKind(rawValue: defaults.string(forKey: Keys.backdrop) ?? "") ?? .opaque
        let storedOpacity = defaults.object(forKey: Keys.opacity) as? Double
        backgroundOpacity = storedOpacity ?? Self.defaultBackgroundOpacity
        if let values = defaults.array(forKey: Keys.accent) as? [Double], values.count == 4 {
            accentOverride = AccentColorValue(red: values[0], green: values[1], blue: values[2], alpha: values[3])
        } else {
            accentOverride = nil
        }
        applyAppKitAppearance()
    }

    func persistOpacity() {
        defaults.set(backgroundOpacity, forKey: Keys.opacity)
    }

    func applyAppKitAppearance() {
        // NSApp is nil until NSApplication is created; .shared creates it on demand,
        // so this is safe during early init and headless launches.
        NSApplication.shared.appearance = mode.nsAppearance
    }

    private static let defaultBackgroundOpacity = 0.85

    private enum Keys {
        static let mode = "mailternal.appearance.mode"
        static let backdrop = "mailternal.appearance.backdrop"
        static let opacity = "mailternal.appearance.opacity"
        static let accent = "mailternal.appearance.accent"
    }
}
