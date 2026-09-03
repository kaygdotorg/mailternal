import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import SwiftUI

/// Core Image QR generation kept separate from the SwiftUI card so the
/// encoding behavior can be exercised without presenting a view.
enum QRCodeRenderer {
    static func outputImage(for copyText: String) -> CIImage? {
        guard let payload = QRCodePolicy.payload(for: copyText),
              QRCodePolicy.canEncode(payload),
              let message = payload.data(using: .utf8)
        else {
            return nil
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = message
        filter.correctionLevel = QRCodePolicy.errorCorrectionLevel
        return filter.outputImage
    }

    /// Produces an integer-scaled bitmap so each QR module remains a crisp
    /// block when SwiftUI displays it without interpolation.
    static func image(for copyText: String) -> CGImage? {
        guard let output = outputImage(for: copyText) else { return nil }
        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let targetSide = CGFloat(QRCodePolicy.renderedSide)
        let scale = max(1, floor(targetSide / extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent.integral)
    }
}

/// The QR alone, centred in the popover. The popover's own frosted chrome is
/// the surface; the QR keeps a white tile so dark modules stay dark-on-light
/// (the form scanners expect) in either appearance.
struct QRCodeCard: View {
    let payload: String

    var body: some View {
        qrSurface
            .padding(16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("QR code for \(payload)")
    }

    @ViewBuilder
    private var qrSurface: some View {
        if let image = QRCodeRenderer.image(for: payload) {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding(10)
                .frame(width: CGFloat(QRCodePolicy.renderedSide), height: CGFloat(QRCodePolicy.renderedSide))
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("QR code")
        } else {
            Label("QR code unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: CGFloat(QRCodePolicy.renderedSide), height: CGFloat(QRCodePolicy.renderedSide))
        }
    }
}
