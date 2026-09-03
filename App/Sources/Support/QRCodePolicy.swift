import Foundation

/// Constraints and payload selection for the reader's QR-code actions.
///
/// The QR generator uses error-correction level M.  The 2,953-byte limit is
/// the largest binary payload supported by that level; counting UTF-8 bytes
/// keeps the menu decision aligned with what Core Image receives.
enum QRCodePolicy {
    static let maxPayloadBytes = 2_953
    static let errorCorrectionLevel = "M"
    static let renderedSide = 176

    /// Returns the exact text represented by a copy action, or nil when the
    /// copy action has no text to encode.
    static func payload(for copyText: String) -> String? {
        copyText.isEmpty ? nil : copyText
    }

    static func isWithinPayloadLimit(_ copyText: String) -> Bool {
        guard let payload = payload(for: copyText) else { return false }
        return payload.utf8.count <= maxPayloadBytes
    }

    static func canEncode(_ copyText: String) -> Bool {
        isWithinPayloadLimit(copyText)
    }

    /// Tooltip text is intentionally useful for both disabled and enabled
    /// menu items, since a disabled item otherwise has no visible explanation.
    static func menuHelp(for copyText: String) -> String {
        guard payload(for: copyText) != nil else {
            return "There is no text to encode as a QR code."
        }
        guard isWithinPayloadLimit(copyText) else {
            return "This text is too long for a QR code (maximum 2,953 bytes)."
        }
        return "Show this field as a QR code."
    }
}
