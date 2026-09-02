import AppKit
import SwiftUI

/// Single-file embed of HtmlIsolation's `MessageWebView`.
struct MessageHTMLView: NSViewRepresentable {
    let html: String
    let partProvider: @Sendable (String) async throws -> (data: Data, mimeType: String)
    var onExternalLink: ((URL) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var allowRemoteImages: Bool = false
    var emailReadingMode: EmailReadingMode = .original
    var findQuery: String = ""
    var findTick: UInt64 = 0
    var findBackwards: Bool = false
    final class Coordinator {
        var lastQuery: String = ""
        var lastTick: UInt64 = .max
        var lastHTML: String = ""
        var findTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MessageWebView {
        let view = MessageWebView(frame: .zero)
        view.onExternalLink = onExternalLink
        view.onContentHeightChange = onContentHeightChange
        return view
    }

    func updateNSView(_ nsView: MessageWebView, context: Context) {
        nsView.onExternalLink = onExternalLink
        nsView.onContentHeightChange = onContentHeightChange
        nsView.render(
            html: html,
            partProvider: partProvider,
            emailReadingMode: emailReadingMode
        )
        nsView.setRemoteImagesAllowed(allowRemoteImages)
        let htmlChanged = context.coordinator.lastHTML != html
        let queryChanged = context.coordinator.lastQuery != findQuery
        let tickChanged = context.coordinator.lastTick != findTick
        guard htmlChanged || queryChanged || tickChanged else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastQuery = findQuery
        context.coordinator.lastTick = findTick
        context.coordinator.findTask?.cancel()
        let query = findQuery
        let backwards = findBackwards
        context.coordinator.findTask = Task { @MainActor in
            _ = await nsView.findInPage(query, backwards: backwards)
        }
    }
}
