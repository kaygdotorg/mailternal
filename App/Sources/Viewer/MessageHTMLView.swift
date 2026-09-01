import AppKit
import SwiftUI

/// Single-file embed of HtmlIsolation's `MessageWebView`.
struct MessageHTMLView: NSViewRepresentable {
    let html: String
    let partProvider: @Sendable (String) async throws -> (data: Data, mimeType: String)
    var onExternalLink: ((URL) -> Void)?
    var allowRemoteImages: Bool = false

    func makeNSView(context: Context) -> MessageWebView {
        let view = MessageWebView(frame: .zero)
        view.onExternalLink = onExternalLink
        return view
    }

    func updateNSView(_ nsView: MessageWebView, context: Context) {
        nsView.onExternalLink = onExternalLink
        nsView.render(html: html, partProvider: partProvider)
        nsView.setRemoteImagesAllowed(allowRemoteImages)
    }
}
