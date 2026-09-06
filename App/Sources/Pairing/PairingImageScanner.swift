#if os(macOS)
import CoreImage
import Foundation

/// Decodes a QR code from a user-selected image using Core Image. This is the
/// camera-free path for Macs without an available camera.
enum PairingQRScanner {
    static func qrString(from url: URL) throws -> String {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let image = CIImage(contentsOf: url) else {
            throw PairingImageScanError.unreadableImage
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            throw PairingImageScanError.decoderUnavailable
        }
        guard let feature = detector.features(in: image)
            .compactMap({ $0 as? CIQRCodeFeature })
            .first(where: { !($0.messageString ?? "").isEmpty }),
              let message = feature.messageString,
              !message.isEmpty
        else {
            throw PairingImageScanError.noQRCode
        }
        return message
    }
}

enum PairingImageScanError: LocalizedError {
    case unreadableImage
    case decoderUnavailable
    case noQRCode

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That image could not be read. Choose a PNG, JPEG, or HEIF QR image."
        case .decoderUnavailable:
            return "The system QR decoder is unavailable."
        case .noQRCode:
            return "No readable QR code was found in that image."
        }
    }
}
#endif
