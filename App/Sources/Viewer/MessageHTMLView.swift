import AppKit
import SwiftUI
import MailternalInterfaces

/// Single-file embed of HtmlIsolation's `MessageWebView`.
struct MessageHTMLView: NSViewRepresentable {
    let messageID: MessageID
    let tabID: UUID?
    let restoreScrollOffset: CGFloat
    let html: String
    let partProvider: @Sendable (String) async throws -> (data: Data, mimeType: String)
    var onExternalLink: ((URL) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var onDocumentScrollOffset: ((UUID, CGFloat) -> Void)?
    var allowRemoteImages: Bool = false
    var emailReadingMode: EmailReadingMode = .original
    var findQuery: String = ""
    var findTick: UInt64 = 0
    var findBackwards: Bool = false
    final class Coordinator {
        struct ScrollIdentity: Equatable {
            let messageID: MessageID
            let tabID: UUID?
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.messageID == rhs.messageID && lhs.tabID == rhs.tabID
            }
        }

        var lastQuery: String = ""
        var lastTick: UInt64 = .max
        var lastHTML: String = ""
        var lastScrollIdentity: ScrollIdentity?
        var onDocumentScrollOffset: ((UUID, CGFloat) -> Void)?
        var findTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MessageWebView {
        let view = MessageWebView(frame: .zero)
        context.coordinator.onDocumentScrollOffset = onDocumentScrollOffset
        view.onExternalLink = onExternalLink
        view.onContentHeightChange = onContentHeightChange
        view.onDocumentScrollOffset = { [weak coordinator = context.coordinator] offset in
            guard let coordinator,
                  let tabID = coordinator.lastScrollIdentity?.tabID
            else { return }
            coordinator.onDocumentScrollOffset?(tabID, offset)
        }
        return view
    }

    func updateNSView(_ nsView: MessageWebView, context: Context) {
        context.coordinator.onDocumentScrollOffset = onDocumentScrollOffset
        nsView.onExternalLink = onExternalLink
        nsView.onContentHeightChange = onContentHeightChange
        nsView.onDocumentScrollOffset = { [weak coordinator = context.coordinator] offset in
            guard let coordinator,
                  let tabID = coordinator.lastScrollIdentity?.tabID
            else { return }
            coordinator.onDocumentScrollOffset?(tabID, offset)
        }
        let scrollIdentity = Coordinator.ScrollIdentity(messageID: messageID, tabID: tabID)
        if context.coordinator.lastScrollIdentity != scrollIdentity {
            context.coordinator.lastScrollIdentity = scrollIdentity
            nsView.restoreScrollOffset(restoreScrollOffset)
        }
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
