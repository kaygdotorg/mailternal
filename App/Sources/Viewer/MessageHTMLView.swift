import AppKit
import SwiftUI
import MailternalInterfaces

/// Installs the active tab's retained ``MessageWebView`` in the SwiftUI reader.
/// The host itself is stable across detail updates; only its pooled child is
/// swapped, so switching a loaded tab never calls `loadHTMLString`.
struct MessageHTMLView: NSViewRepresentable {
    let pool: ReaderSurfacePool
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
        var lastQuery: String = ""
        var lastTick: UInt64 = .max
        var lastMessageID: MessageID?
        var findTask: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReaderWebViewHost {
        let host = ReaderWebViewHost()
        host.update(
            pool: pool,
            messageID: messageID,
            tabID: tabID,
            restoreScrollOffset: restoreScrollOffset,
            html: html,
            partProvider: partProvider,
            onExternalLink: onExternalLink,
            onContentHeightChange: onContentHeightChange,
            onDocumentScrollOffset: onDocumentScrollOffset,
            allowRemoteImages: allowRemoteImages,
            emailReadingMode: emailReadingMode,
            findQuery: findQuery,
            findTick: findTick,
            findBackwards: findBackwards,
            coordinator: context.coordinator
        )
        return host
    }

    func updateNSView(_ nsView: ReaderWebViewHost, context: Context) {
        nsView.update(
            pool: pool,
            messageID: messageID,
            tabID: tabID,
            restoreScrollOffset: restoreScrollOffset,
            html: html,
            partProvider: partProvider,
            onExternalLink: onExternalLink,
            onContentHeightChange: onContentHeightChange,
            onDocumentScrollOffset: onDocumentScrollOffset,
            allowRemoteImages: allowRemoteImages,
            emailReadingMode: emailReadingMode,
            findQuery: findQuery,
            findTick: findTick,
            findBackwards: findBackwards,
            coordinator: context.coordinator
        )
    }
    static func dismantleNSView(_ nsView: ReaderWebViewHost, coordinator: Coordinator) {
        coordinator.findTask?.cancel()
        nsView.detach()
    }

}

@MainActor
final class ReaderWebViewHost: NSView {
    private lazy var fallbackView = MessageWebView(frame: .zero)
    private var installedView: MessageWebView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        installedView?.frame = bounds
    }

    func detach() {
        installedView?.onExternalLink = nil
        installedView?.onContentHeightChange = nil
        installedView?.onDocumentScrollOffset = nil
        installedView?.removeFromSuperview()
        installedView = nil
    }

    func update(
        pool: ReaderSurfacePool,
        messageID: MessageID,
        tabID: UUID?,
        restoreScrollOffset: CGFloat,
        html: String,
        partProvider: @escaping @Sendable (String) async throws -> (data: Data, mimeType: String),
        onExternalLink: ((URL) -> Void)?,
        onContentHeightChange: ((CGFloat) -> Void)?,
        onDocumentScrollOffset: ((UUID, CGFloat) -> Void)?,
        allowRemoteImages: Bool,
        emailReadingMode: EmailReadingMode,
        findQuery: String,
        findTick: UInt64,
        findBackwards: Bool,
        coordinator: MessageHTMLView.Coordinator
    ) {
        let nextView: MessageWebView
        if let tabID {
            nextView = pool.webView(for: tabID)
        } else {
            // A no-tab transition is not an LRU entry: keep this one transient
            // fallback outside the bounded per-tab pool.
            nextView = fallbackView
        }
        if installedView !== nextView {
            installedView?.removeFromSuperview()
            installedView = nextView
            nextView.translatesAutoresizingMaskIntoConstraints = true
            nextView.autoresizingMask = [.width, .height]
            addSubview(nextView)
            nextView.frame = bounds
        } else if let tabID {
            pool.touch(tabID)
        }

        guard let view = installedView else { return }
        let messageChanged = view.renderedMessageID != messageID
        view.onExternalLink = onExternalLink
        view.onContentHeightChange = { [weak pool] height in
            if let tabID {
                pool?.recordContentHeight(height, for: tabID, messageID: messageID)
            }
            onContentHeightChange?(height)
        }
        view.onDocumentScrollOffset = { offset in
            guard let tabID else { return }
            onDocumentScrollOffset?(tabID, offset)
        }

        // A pooled surface already owns its native WebKit scroll position.
        // Restore only a newly created surface or a transient message that
        // changed in place; doing this on every tab swap would enqueue JS work
        // in the otherwise paint-only path.
        if messageChanged {
            view.render(
                html: html,
                partProvider: partProvider,
                emailReadingMode: emailReadingMode,
                remoteImagesAllowed: allowRemoteImages,
                messageID: messageID,
                forceReload: true
            )
            view.restoreScrollOffset(restoreScrollOffset)
        } else {
            if view.remoteImagesAreAllowed != allowRemoteImages {
                // Consent is an explicit user action and may reload the current
                // document; it is not part of a tab switch.
                view.setRemoteImagesAllowed(allowRemoteImages)
            }
            // A retained document can switch reading modes without another
            // navigation. If a load is still in flight, didFinish applies the
            // pending mode only when its navigation identity matches.
            view.updateReadingMode(emailReadingMode)
        }

        let queryChanged = coordinator.lastQuery != findQuery
        let tickChanged = coordinator.lastTick != findTick
        let messageIDChanged = coordinator.lastMessageID != messageID
        guard queryChanged || tickChanged || messageIDChanged else { return }
        coordinator.lastQuery = findQuery
        coordinator.lastTick = findTick
        coordinator.lastMessageID = messageID
        coordinator.findTask?.cancel()
        let query = findQuery
        let backwards = findBackwards
        coordinator.findTask = Task { @MainActor in
            _ = await view.findInPage(query, backwards: backwards)
        }
    }
}
