#if os(macOS)
import AppKit

/// The HTML reader has its own WebKit appearance boundary. A message's
/// `.original` mode follows the app/window appearance; `.dark` is the
/// per-message dark override.
enum MessageHTMLReadingPolicy {
    static func appearance(for mode: EmailReadingMode) -> NSAppearance? {
        switch mode {
        case .original:
            nil
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    static func colorScheme(for mode: EmailReadingMode) -> String {
        switch mode {
        case .original:
            "light dark"
        case .dark:
            "dark"
        }
    }

    /// The dark treatment inverts authored light surfaces while restoring
    /// raster/vector images so email chrome and image colors remain intact.
    static var darkTreatmentCSS: String {
        """
        html {
          filter: invert(1) hue-rotate(180deg);
          background: #e1e1e1;
        }
        html img, html svg, html video, html canvas {
          filter: invert(1) hue-rotate(180deg) !important;
        }
        """
    }
}
#endif
