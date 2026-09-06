import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders only the opaque handshake string supplied by PairingSession.
/// Account configuration and credentials are never passed to this renderer.
enum PairingQRRenderer {
    private static let correctionLevel = "M"
    private static let targetSide: CGFloat = 226
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for qrString: String) -> CGImage? {
        guard !qrString.isEmpty,
              let message = qrString.data(using: .utf8)
        else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = message
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = max(1, floor(targetSide / max(extent.width, extent.height)))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }
}
