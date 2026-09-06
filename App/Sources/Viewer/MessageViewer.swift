import AppKit
import SwiftUI
import MailternalInterfaces
enum MessageViewerContext: Equatable {
    case main
    case detached(messageID: MessageID)
}
private enum ReaderSurfaceKind: Hashable {
    case html
    case plainText
    case rawSource
    case quarantine
    case empty
}
private struct ReaderScrollAnchor: Hashable {
    let tabID: UUID?
    let messageID: MessageID
    let surface: ReaderSurfaceKind
}
private struct HeaderLoadDemand: Hashable {
    let messageID: MessageID
    let isShowingRawSource: Bool
    let hasCachedSource: Bool
}

struct MessageViewer: View {
    @Bindable var model: AppModel
    let context: MessageViewerContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var viewerFocus
    @State private var findIndex: Int?
    @State private var findBackwards = false
    @State private var findTick: UInt64 = 0
    /// Detached readers have no tab identity, so retain only the current
    /// transient document's measured height. Tab-owned geometry lives in the
    /// bounded ``ReaderSurfacePool``.
    @State private var htmlContentHeightForDetachedReader: CGFloat = 0
    /// The pool owns active-tab heights; this signal only asks SwiftUI to
    /// re-read the bounded entry after WebKit reports a new measurement.
    @State private var htmlContentHeightRevision: UInt64 = 0
    /// AppKit reports document-layout changes after pooled reader surfaces are
    /// installed. This signal reapplies SwiftUI's top anchor for zero offsets.
    @State private var readerLayoutRevision: UInt64 = 0
    /// Set only after the active HTML/TextKit bridge has installed the
    /// requested pooled surface. The scroll bridge uses it to reject a
    /// zero-offset observation from the previous tab's document.
    @State private var surfaceReadyAnchor: ReaderScrollAnchor?
    @State private var headersStore: MessageHeadersStore

    init(model: AppModel, context: MessageViewerContext = .main) {
        self.model = model
        self.context = context
        _headersStore = State(initialValue: MessageHeadersStore { [facade = model.facade] id in
            try await facade.rawSource(id)
        })
    }

    private var usesPaneChrome: Bool {
        context == .main && model.listPaneLayout == .listAboveReader
    }

    private var dissolvePolicy: MailWindowDissolvePolicy {
        usesPaneChrome ? .paneViewer : .viewer
    }

    /// Stable native focus and geometry anchor, independent of the active
    /// document and SwiftUI's virtual accessibility hierarchy.
    static func focusAnchor(in contentView: NSView) -> NSView? {
        ReaderGeometryView.find(.reader, in: contentView)
    }
    private var findHaystack: String {
        MessageFind.haystack(
            bodyText: model.detail?.bodyText,
            html: model.detail?.sanitizedHTML,
            raw: model.rawSource,
            showingRaw: model.isShowingRawSource
        )
    }

    private var findSnapshot: MessageFind.Snapshot {
        MessageFind.make(text: findHaystack, query: model.findQuery, index: findIndex)
    }

    private var activeFindQuery: String {
        model.isFindPresented ? model.findQuery : ""
    }


    /// Plain text is SwiftUI-rendered, so scope the per-message override to
    /// this body surface instead of changing the reader chrome. Original mode
    /// follows the app's System/Light/Dark appearance.
    private var emailBodyColorScheme: ColorScheme? {
        model.effectiveEmailReadingMode == .dark
            ? .dark
            : model.appearance.mode.colorScheme
    }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
            if model.isFindPresented {
                FindBar(
                    query: $model.findQuery,
                    matchCount: findSnapshot.count,
                    selectedMatchNumber: findSnapshot.selectedMatchNumber,
                    next: { stepFind(.next) },
                    previous: { stepFind(.previous) },
                    close: { model.isFindPresented = false }
                )
                .padding(.top, 12)
                .padding(.trailing, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(MailMotion.disclosure, value: model.isFindPresented)
        .focusScope(viewerFocus)
        .background(ReaderGeometryProbe(role: .reader).allowsHitTesting(false))
        .accessibilityIdentifier(UIIdentifier.messageViewer)
        .simultaneousGesture(
            TapGesture().onEnded {
                model.noteReaderInteraction()
            }
        )
        .onExitCommand {
            if model.isFindPresented {
                model.isFindPresented = false
            }
        }
        .onChange(of: model.findQuery) { _, _ in
            restartFind()
        }
        .onChange(of: model.isShowingRawSource) { _, _ in
            restartFind()
        }
        .onChange(of: model.isFindPresented) { _, presented in
            if presented { restartFind() }
        }
        .onChange(of: model.effectiveEmailReadingMode) { _, mode in
            model.readerSurfacePool.updateReadingMode(mode)
        }
#if DEBUG
        .onChange(of: model.detail?.id) { _, id in
            guard let id,
                  ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1"
            else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                QALaunch.log(
                    "selection-perf event=reader-commit message=\(id.rawValue) t=\(DispatchTime.now().uptimeNanoseconds)"
                )
            }
            NSApp.keyWindow?.contentView?.needsLayout = true
            CATransaction.commit()
        }
#endif
    }

    @ViewBuilder
    private var content: some View {
        if context == .main,
           model.tabs.active == nil,
           let title = MessageReaderStatePolicy.emptyStateTitle(
               selectionCount: model.selectedMessageIDs.count
           ) {
            EmptyMailboxState(
                title: title,
                detail: MessageReaderStatePolicy.emptyStateDetail(
                    selectionCount: model.selectedMessageIDs.count
                ) ?? "Choose one message to read it."
            )
        } else if let detail = model.detail,
                  canRender(detail) {
            reader(detail)
        } else if model.isLoadingDetail {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#if DEBUG
                .onAppear { noteSpinnerVisibility(true) }
                .onDisappear { noteSpinnerVisibility(false) }
#endif
        } else {
            EmptyMailboxState(
                title: "No Message Selected",
                detail: "Choose a message from the list to read it."
            )
        }
    }

#if DEBUG
    /// Measures the mounted indicator, not merely a pending detail request.
    private func noteSpinnerVisibility(_ visible: Bool) {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" else { return }
        let event = visible ? "spinner-visible" : "spinner-hidden"
        QALaunch.log("selection-perf event=\(event) t=\(DispatchTime.now().uptimeNanoseconds)")
    }
#endif

    private func surfaceKind(for detail: MessageDetail) -> ReaderSurfaceKind {
        if model.isShowingRawSource {
            return .rawSource
        }
        if detail.isQuarantined {
            return .quarantine
        }
        if let html = detail.sanitizedHTML, !html.isEmpty {
            return .html
        }
        if let text = detail.bodyText, !text.isEmpty {
            return .plainText
        }
        return .empty
    }

    private func canRender(_ detail: MessageDetail) -> Bool {
        switch context {
        case .main:
            return model.tabs.active?.message == detail.id
        case .detached(let messageID):
            return messageID == detail.id
        }
    }

    private func reader(_ detail: MessageDetail) -> some View {
        let activeTabID = model.tabs.activeID
        let savedScrollOffset = activeTabID.map {
            model.tabs.scrollOffset(for: $0)
        } ?? 0
        let scrollAnchor = ReaderScrollAnchor(
            tabID: activeTabID,
            messageID: detail.id,
            surface: surfaceKind(for: detail)
        )
        let surfaceIsReady = surfaceReadyAnchor == scrollAnchor
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(scrollAnchor)
                    VStack(
                        alignment: .leading,
                        spacing: MessageViewerLayoutPolicy.islandSpacing
                    ) {
                        MessageSubjectRegion(
                            subject: detail.envelope.subject,
                            envelope: detail.envelope,
                            attachments: detail.attachments,
                            messageID: detail.id,
                            headersStore: headersStore,
                            backdropStyle: model.appearance.backdropStyle,
                            showsSenderIcons: model.appearance.showsSenderIcons,
                            isShowingRawSource: model.isShowingRawSource,
                            rawSource: model.rawSource,
                            accent: model.appearance.accent.color
                        )
                        bodyRegion(detail)
                    }
                    .padding(.horizontal, MessageViewerLayoutPolicy.horizontalPadding)
                    // The inset is local to the reader's chrome: stacked
                    // panes do not reserve the window titlebar a second time.
                    .padding(
                        .top,
                        max(
                            MessageViewerLayoutPolicy.readerTopInset(dissolve: dissolvePolicy)
                                - MessageViewerLayoutPolicy.islandVerticalPadding,
                            0
                        )
                    )
                    .padding(.bottom, MessageViewerLayoutPolicy.bottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        ReaderScrollHost(
                            tabID: activeTabID,
                            messageID: detail.id,
                            restoreOffset: savedScrollOffset,
                            surfaceReady: surfaceIsReady,
                            onScrollEnd: { id, offset in
                                guard model.tabs.activeID == id,
                                      model.detail?.id == detail.id
                                else { return }
                                model.tabs.setScrollOffset(offset, for: id)
                            },
                            onLayoutChange: {
                                guard model.tabs.activeID == activeTabID,
                                      model.detail?.id == detail.id
                                else { return }
                                readerLayoutRevision &+= 1
                            },
                            onScrollRestored: { id, messageID, offset in
                                model.noteQAScrollRestored(
                                    tabID: id,
                                    messageID: messageID,
                                    offset: offset
                                )
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keep the outer viewport mounted across tab switches. The
            // AppKit bridge below resets and restores its native position.
            .task(id: scrollAnchor) {
                guard savedScrollOffset <= 0.5 else { return }
                await Task.yield()
                proxy.scrollTo(scrollAnchor, anchor: .top)
            }
            .onChange(of: readerLayoutRevision) { _, _ in
                guard let activeTabID,
                      model.tabs.activeID == activeTabID,
                      model.detail?.id == detail.id,
                      model.tabs.scrollOffset(for: activeTabID) <= 0.5
                else { return }
                proxy.scrollTo(scrollAnchor, anchor: .top)
            }
            .background {
                ScrollEdgeEffectSuppressor()
            }
            .ignoresSafeArea(.container, edges: usesPaneChrome ? [] : .top)
            .mailWindowDissolve(dissolvePolicy)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bodyRegion(_ detail: MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.bodyContentSpacing) {
            if detail.isQuarantined {
                QuarantineBanner(
                    showingRaw: model.isShowingRawSource,
                    loadRaw: { Task { await model.loadRawSource() } }
                )
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.top, MessageViewerLayoutPolicy.islandVerticalPadding)
            }
            bodyContent(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerIslandSurface(
            role: .body,
            backdropStyle: model.appearance.backdropStyle
        )
        .accessibilityIdentifier(UIIdentifier.messageBody)
    }

    @ViewBuilder
    private func bodyContent(_ detail: MessageDetail) -> some View {
        let surfaceAnchor = ReaderScrollAnchor(
            tabID: model.tabs.activeID,
            messageID: detail.id,
            surface: surfaceKind(for: detail)
        )
        let surfaceReadiness = $surfaceReadyAnchor
        if model.isShowingRawSource {
            if let raw = model.rawSource {
                RawSourceView(
                    text: raw,
                    query: activeFindQuery,
                    selectedMatchIndex: findSnapshot.index,
                    findTick: findTick,
                )
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
                .task(id: surfaceAnchor) {
                    surfaceReadiness.wrappedValue = surfaceAnchor
                    if let tabID = surfaceAnchor.tabID {
                        model.noteQASurfaceReady(
                            tabID: tabID,
                            messageID: detail.id
                        )
                    }
                }
            } else {
                ProgressView("Loading source…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                    .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
            }
        } else if detail.isQuarantined {
            Text("The original source is available if you need it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
            .task(id: surfaceAnchor) {
                surfaceReadiness.wrappedValue = surfaceAnchor
                if let tabID = surfaceAnchor.tabID {
                    model.noteQASurfaceReady(
                        tabID: tabID,
                        messageID: detail.id
                    )
                }
            }
        } else if let html = detail.sanitizedHTML, !html.isEmpty {
            htmlBody(detail, html: html)
        } else if let text = detail.bodyText, !text.isEmpty {
            PlainTextBody(
                text: text,
                query: activeFindQuery,
                selectedMatchIndex: findSnapshot.index,
                findTick: findTick,
                pool: model.readerSurfacePool,
                tabID: model.tabs.activeID,
                messageID: detail.id,
                onSurfaceReady: { [weak model, surfaceReadiness] tabID, messageID in
                    DispatchQueue.main.async {
                        guard let model,
                              model.tabs.activeID == tabID,
                              model.detail?.id == messageID else { return }
                        surfaceReadiness.wrappedValue = surfaceAnchor
                        model.noteQASurfaceReady(
                            tabID: tabID,
                            messageID: messageID
                        )
                    }
                }
            )
            .preferredColorScheme(emailBodyColorScheme)
            .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
            .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
            // The pane stays full width; only the plain-text measure narrows.
            .frame(maxWidth: MessageTypography.plainTextMeasure, alignment: .leading)
        } else {
            Text("This message has no text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)
                .task(id: surfaceAnchor) {
                    surfaceReadiness.wrappedValue = surfaceAnchor
                    if let tabID = surfaceAnchor.tabID {
                        model.noteQASurfaceReady(
                            tabID: tabID,
                            messageID: detail.id
                        )
                    }
                }
        }
    }


    private func htmlBody(_ detail: MessageDetail, html: String) -> some View {
        let surfaceReadiness = $surfaceReadyAnchor
        let surfaceAnchor = ReaderScrollAnchor(
            tabID: model.tabs.activeID,
            messageID: detail.id,
            surface: surfaceKind(for: detail)
        )
        let activeTabID = model.tabs.activeID
        let showRemoteImageNotice = model.hasRemoteImageReferences && !model.allowRemoteImages
        let _ = htmlContentHeightRevision
        let cachedContentHeight: CGFloat
        if let activeTabID {
            cachedContentHeight = model.readerSurfacePool.height(
                for: activeTabID,
                messageID: detail.id
            )
        } else {
            cachedContentHeight = htmlContentHeightForDetachedReader
        }
        let detachedContentHeight = $htmlContentHeightForDetachedReader
        let contentHeightRevision = $htmlContentHeightRevision
        return VStack(alignment: .leading, spacing: 0) {
            // Keep a stable slot ahead of the representable. If the notice is
            // removed as a sibling, SwiftUI can shift MessageHTMLView's
            // structural identity and recreate its host instead of delivering
            // the consent update to the pooled surface.
            ZStack(alignment: .topLeading) {
                if showRemoteImageNotice {
                    RemoteImageNotice { model.allowRemoteImages = true }
                        .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
                        .padding(.top, MessageViewerLayoutPolicy.islandVerticalPadding)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(
                .bottom,
                showRemoteImageNotice ? MessageViewerLayoutPolicy.bodyContentSpacing : 0
            )
            MessageHTMLView(
                pool: model.readerSurfacePool,
                messageID: detail.id,
                tabID: activeTabID,
                restoreScrollOffset: activeTabID.map {
                    model.tabs.scrollOffset(for: $0)
                } ?? 0,
                html: html,
                partProvider: model.partProvider(for: detail.id),
                onContentHeightChange: { [weak model, detachedContentHeight, contentHeightRevision] height in
                    guard let model,
                          model.detail?.id == detail.id,
                          height.isFinite,
                          height > 0
                    else { return }
                    if let activeTabID {
                        guard model.tabs.activeID == activeTabID else { return }
                        contentHeightRevision.wrappedValue &+= 1
                        return
                    }
                    guard abs(detachedContentHeight.wrappedValue - height) > 0.5 else {
                        return
                    }
                    detachedContentHeight.wrappedValue = height
                },
                onDocumentScrollOffset: { [weak model] tabID, offset in
                    guard let model,
                          model.tabs.activeID == tabID,
                          model.detail?.id == detail.id
                    else { return }
                    model.tabs.setScrollOffset(offset, for: tabID)
                },
                onSurfaceReady: { [weak model, surfaceReadiness] tabID, messageID in
                    DispatchQueue.main.async {
                        guard let model,
                              model.tabs.activeID == tabID,
                              model.detail?.id == messageID else { return }
                        surfaceReadiness.wrappedValue = surfaceAnchor
                        model.noteQASurfaceReady(
                            tabID: tabID,
                            messageID: messageID
                        )
                    }
                },
                allowRemoteImages: model.allowRemoteImages,
                emailReadingMode: model.effectiveEmailReadingMode,
                findQuery: activeFindQuery,
                findTick: findTick,
                findBackwards: findBackwards
            )
            // The web page is the body island's canvas. Its document height
            // exactly owns the island height, so the reader is the only
            // scrolling surface.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(
                height: MessageViewerLayoutPolicy.htmlHeight(
                    contentHeight: cachedContentHeight
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restartFind() {
        findBackwards = false
        findIndex = MessageFind.restartIndex(
            count: MessageFind.ranges(in: findHaystack, query: model.findQuery).count
        )
        findTick += 1
    }

    private func stepFind(_ step: MessageFind.Step) {
        findBackwards = step == .previous
        findIndex = MessageFind.advance(
            index: findSnapshot.index,
            count: findSnapshot.count,
            step: step
        )
        findTick += 1
    }
}

/// Bridges the SwiftUI reader's AppKit scroll host to the active tab's
/// persisted position. The bridge is intentionally zero-sized: it observes
/// the scroll view SwiftUI creates instead of introducing a second viewport.
private struct ReaderScrollHost: NSViewRepresentable {
    let tabID: UUID?
    let messageID: MessageID
    let restoreOffset: CGFloat
    let surfaceReady: Bool
    let onScrollEnd: (UUID, CGFloat) -> Void
    let onLayoutChange: @MainActor @Sendable () -> Void
    let onScrollRestored: (UUID, MessageID, CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderScrollTrackingView {
        let view = ReaderScrollTrackingView()
        view.update(
            tabID: tabID,
            messageID: messageID,
            restoreOffset: restoreOffset,
            surfaceReady: surfaceReady,
            onScrollEnd: onScrollEnd,
            onLayoutChange: onLayoutChange,
            onScrollRestored: onScrollRestored
        )
        return view
    }

    func updateNSView(_ nsView: ReaderScrollTrackingView, context: Context) {
        nsView.update(
            tabID: tabID,
            messageID: messageID,
            restoreOffset: restoreOffset,
            surfaceReady: surfaceReady,
            onScrollEnd: onScrollEnd,
            onLayoutChange: onLayoutChange,
            onScrollRestored: onScrollRestored
        )
    }

    static func dismantleNSView(
        _ nsView: ReaderScrollTrackingView,
        coordinator: Void
    ) {
        nsView.dispose()
    }
}

@MainActor
private final class ReaderScrollTrackingView: NSView {
    private var tabID: UUID?
    private var messageID: MessageID?
    private var restoreOffset: CGFloat = 0
    private var surfaceReady = false
    private var onScrollRestored: ((UUID, MessageID, CGFloat) -> Void)?
    private var onScrollEnd: ((UUID, CGFloat) -> Void)?
    private var onLayoutChange: (@MainActor @Sendable () -> Void)?
    private weak var scrollView: NSScrollView?
    private var didApplyRestore = false
    private var didReportScrollRestored = false
    private var restoreTask: Task<Void, Never>?
    private var restoreGeneration: UInt64 = 0
    private var captureTask: Task<Void, Never>?
    private var keyEventMonitor: Any?
    private var keyboardScrollIntentDeadline: TimeInterval = 0
    /// Bounds changes also come from SwiftUI document layout. Persist only
    /// changes carrying live-wheel or keyboard intent; restoration mutations
    /// are separately suppressed.
    private var suppressScrollPersistence = false
    private var isLiveScrolling = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleAttach()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAttach()
    }

    func update(
        tabID: UUID?,
        messageID: MessageID,
        restoreOffset: CGFloat,
        surfaceReady: Bool,
        onScrollEnd: @escaping (UUID, CGFloat) -> Void,
        onLayoutChange: @escaping @MainActor @Sendable () -> Void,
        onScrollRestored: @escaping (UUID, MessageID, CGFloat) -> Void
    ) {
        let contentChanged = self.tabID != tabID || self.messageID != messageID
        self.tabID = tabID
        self.messageID = messageID
        self.surfaceReady = surfaceReady
        self.onScrollEnd = onScrollEnd
        self.onLayoutChange = onLayoutChange
        self.onScrollRestored = onScrollRestored
        if contentChanged {
            captureTask?.cancel()
            captureTask = nil
            restoreTask?.cancel()
            restoreTask = nil
            isLiveScrolling = false
            suppressScrollPersistence = false
            self.restoreOffset = restoreOffset.isFinite ? max(restoreOffset, 0) : 0
            didApplyRestore = false
            didReportScrollRestored = false
            restoreGeneration &+= 1
            resetScrollPositionForContentChange()
        }
        attach()
        if contentChanged {
            scheduleRestore(generation: restoreGeneration)
            requestTopAnchorIfNeeded()
        }
    }
    /// The outer SwiftUI scroll view stays mounted for hierarchy stability.
    /// Reset its clip to the visual top before a new document is installed;
    /// the bounded restore task then reapplies the tab's saved offset once the
    /// new document reports a sufficient extent.
    private func resetScrollPositionForContentChange() {
        guard let scrollView,
              let documentView = scrollView.documentView else {
            return
        }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = documentView.frame.minY
        suppressScrollPersistence = true
        clip.setBoundsOrigin(bounds.origin)
        scrollView.reflectScrolledClipView(clip)
        suppressScrollPersistence = false
    }


    private func scheduleAttach() {
        DispatchQueue.main.async { [weak self] in
            self?.attach()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.attach()
        }
    }

    private func attach() {
        guard tabID != nil else {
            detach()
            return
        }
        guard let enclosing = attachedScrollView() else { return }
        if scrollView !== enclosing {
            detach()
            scrollView = enclosing
            didApplyRestore = false
            installKeyEventMonitor()
            OverlayScrollerPolicy.apply(to: enclosing)
            let clip = enclosing.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollStarted),
                name: NSScrollView.willStartLiveScrollNotification,
                object: enclosing
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollEnded),
                name: NSScrollView.didEndLiveScrollNotification,
                object: enclosing
            )
            if let documentView = enclosing.documentView {
                documentView.postsBoundsChangedNotifications = true
                documentView.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentBoundsChanged),
                    name: NSView.boundsDidChangeNotification,
                    object: documentView
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentBoundsChanged),
                    name: NSView.frameDidChangeNotification,
                    object: documentView
                )
            }
        }
        applyRestoreIfPossible()
    }

    private func attachedScrollView() -> NSScrollView? {
        if let enclosingScrollView {
            return enclosingScrollView
        }

        var root: NSView = self
        while let superview = root.superview {
            if superview is NSSplitView { break }
            root = superview
            if root === window?.contentView { break }
        }
        var result: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView {
                result.append(scrollView)
                return
            }
            for subview in view.subviews {
                visit(subview)
            }
        }
        visit(root)
        return result.first(where: { $0.hasVerticalScroller }) ?? result.first
    }

    @objc private func documentBoundsChanged() {
        // Layout can move the clip after an initial zero-offset restore. Keep
        // reapplying the saved position until real user input updates it.
        guard !hasUserScrollIntent else { return }
        applyRestoreIfPossible(force: true)
        requestTopAnchorIfNeeded()
    }

    func dispose() {
        detach()
        onScrollEnd = nil
        onLayoutChange = nil
        onScrollRestored = nil
    }

    private func detach() {
        NotificationCenter.default.removeObserver(self)
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        scrollView = nil
        captureTask?.cancel()
        captureTask = nil
        restoreTask?.cancel()
        restoreTask = nil
        keyboardScrollIntentDeadline = 0
        suppressScrollPersistence = false
        isLiveScrolling = false
    }

    private func requestTopAnchorIfNeeded() {
        guard restoreOffset <= 0.5,
              !hasUserScrollIntent,
              let onLayoutChange
        else { return }
        DispatchQueue.main.async(execute: onLayoutChange)
    }

    @objc private func boundsChanged() {
        guard didApplyRestore,
              !suppressScrollPersistence,
              hasUserScrollIntent else { return }
        scheduleCapture()
    }

    @objc private func scrollStarted() {
        isLiveScrolling = true
    }

    @objc private func scrollEnded() {
        let shouldCapture = isLiveScrolling
        isLiveScrolling = false
        if shouldCapture {
            captureOffset()
        }
    }

    private var hasUserScrollIntent: Bool {
        if isLiveScrolling { return true }
        if NSApp.currentEvent?.type == .scrollWheel { return true }
        return ProcessInfo.processInfo.systemUptime <= keyboardScrollIntentDeadline
    }

    private func installKeyEventMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.recordKeyboardScrollIntent(for: event)
            return event
        }
    }

    private func recordKeyboardScrollIntent(for event: NSEvent) {
        guard Self.isScrollKey(event),
              let scrollView,
              event.window === scrollView.window,
              let responder = scrollView.window?.firstResponder as? NSView,
              responder === scrollView || responder.isDescendant(of: scrollView)
        else { return }
        keyboardScrollIntentDeadline = ProcessInfo.processInfo.systemUptime + 0.75
    }

    private static func isScrollKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49, 115, 116, 119, 121, 125, 126:
            true
        default:
            false
        }
    }

    private func scheduleCapture() {
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(90))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.captureOffset()
        }
    }

    private func captureOffset() {
        guard didApplyRestore,
              !suppressScrollPersistence,
              let tabID,
              let scrollView,
              scrollView.documentView != nil
        else { return }
        let clip = scrollView.contentView
        let capturedOffset = visualTopOffset(
            clipBounds: clip.bounds,
            documentRect: clip.documentRect
        )
        restoreOffset = capturedOffset
        onScrollEnd?(tabID, capturedOffset)
    }

    private func scheduleRestore(generation: UInt64) {
        restoreTask?.cancel()
        let delays: [Duration] = [
            .zero,
            .milliseconds(100),
            .milliseconds(200),
            .milliseconds(700)
        ]
        restoreTask = Task { @MainActor [weak self] in
            for delay in delays {
                if delay != .zero {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                }
                guard let self,
                      !Task.isCancelled,
                      generation == self.restoreGeneration,
                      !self.didApplyRestore else {
                    return
                }
                self.applyRestoreIfPossible()
                if self.didApplyRestore {
                    return
                }
            }
        }
    }

    private func applyRestoreIfPossible(force: Bool = false) {
        guard (force || !didApplyRestore),
              surfaceReady,
              !suppressScrollPersistence,
              let scrollView,
              scrollView.documentView != nil,
              tabID != nil
        else { return }
        let clip = scrollView.contentView
        let documentRect = clip.documentRect
        let target = restoreOffset.isFinite ? max(restoreOffset, 0) : 0
        let effectiveOffset = visualTopOffset(
            clipBounds: clip.bounds,
            documentRect: documentRect
        )
        let tolerance: CGFloat = 0.5
        if abs(effectiveOffset - target) <= tolerance {
            didApplyRestore = true
            notifyScrollRestoredIfNeeded()
            return
        }

        let maximumOffset = max(documentRect.height - clip.bounds.height, 0)
        guard target <= maximumOffset + tolerance else { return }
        let proposedBounds = proposedBounds(
            forTopOffset: target,
            clipBounds: clip.bounds,
            documentRect: documentRect
        )

        suppressScrollPersistence = true
        defer { suppressScrollPersistence = false }
        clip.setBoundsOrigin(proposedBounds.origin)
        scrollView.reflectScrolledClipView(clip)
        let finalDocumentRect = clip.documentRect
        didApplyRestore = abs(
            visualTopOffset(
                clipBounds: clip.bounds,
                documentRect: finalDocumentRect
            ) - target
        ) <= tolerance
        if didApplyRestore {
            notifyScrollRestoredIfNeeded()
        }

    }
    private func notifyScrollRestoredIfNeeded() {
        guard !didReportScrollRestored,
              let tabID,
              let messageID,
              let onScrollRestored,
              let scrollView else {
            return
        }
        didReportScrollRestored = true
        let offset = visualTopOffset(
            clipBounds: scrollView.contentView.bounds,
            documentRect: scrollView.contentView.documentRect
        )
        onScrollRestored(tabID, messageID, offset)
    }

    /// SwiftUI's hosting document scrolls from its minimum Y even though
    /// NSClipView's generic constraint helper can choose the opposite edge
    /// during an early layout pass. Measure the actual visual-top origin.
    private func visualTopOffset(
        clipBounds: NSRect,
        documentRect: NSRect
    ) -> CGFloat {
        let offset = clipBounds.minY - documentRect.minY
        return offset.isFinite ? max(offset, 0) : 0
    }

    private func proposedBounds(
        forTopOffset offset: CGFloat,
        clipBounds: NSRect,
        documentRect: NSRect
    ) -> NSRect {
        var proposedBounds = clipBounds
        let topOffset = offset.isFinite ? max(offset, 0) : 0
        proposedBounds.origin.y = documentRect.minY + topOffset
        return proposedBounds
    }

}

private enum ReaderIslandRole: Equatable {
    case translucent
    case body
}

private struct ReaderIslandSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let role: ReaderIslandRole
    let backdropStyle: WindowBackdropStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppShapeScale.card, style: .continuous)
        content
            .background {
                surfaceBackground(in: shape)
            }
            .overlay {
                if !reduceTransparency, role == .translucent,
                   let image = ReaderFilmGrain.image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable(resizingMode: .tile)
                        .opacity(0.04)
                        .blendMode(.overlay)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.strokeBorder(
                    contrast == .increased ? Color.primary : Color.primary.opacity(0.18),
                    lineWidth: contrast == .increased ? 1.5 : 0.75
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
    }

    @ViewBuilder
    private func surfaceBackground(in shape: RoundedRectangle) -> some View {
        if reduceTransparency || role == .body {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            switch backdropStyle {
            case .clearGlass, .regularGlass:
                shape
                    .fill(Color.clear)
                    .glassEffect(
                        backdropStyle == .clearGlass ? .clear : .regular,
                        in: shape
                    )
            case .frostedBlur:
                shape.fill(.ultraThinMaterial)
            }
        }
    }
}

private enum ReaderFilmGrain {
    static let image: CGImage? = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        var seed: UInt64 = 0x4D61696C7465726E
        for index in bytes.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 56)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }()
}

private extension View {
    func readerIslandSurface(
        role: ReaderIslandRole = .translucent,
        backdropStyle: WindowBackdropStyle = .frostedBlur
    ) -> some View {
        modifier(ReaderIslandSurface(role: role, backdropStyle: backdropStyle))
    }
}

/// Reading anchor: the strongest contrast in the reader, wrapping without
/// limit, resting below the window's dissolve rather than inside its ramp.
/// The envelope and its source representation live inside this same surface,
/// so changing source mode animates one island rather than replacing a card.
struct MessageSubjectRegion: View {
    let subject: String
    let envelope: Envelope
    let attachments: [AttachmentInfo]
    let messageID: MessageID
    let headersStore: MessageHeadersStore
    let backdropStyle: WindowBackdropStyle
    let showsSenderIcons: Bool
    let isShowingRawSource: Bool
    let rawSource: String?
    let accent: Color

    /// The native toolbar aligns to the rendered island, not the split pane:
    /// SwiftUI's detail content can extend beyond the native pane's bounds.
    static let geometryDidChange = Notification.Name("Mailternal.ReaderSubjectGeometryDidChange")

    static func cardFrame(in contentView: NSView) -> CGRect? {
        guard let marker = ReaderGeometryView.find(.subject, in: contentView),
              marker.window != nil, !marker.bounds.isEmpty else { return nil }
        return marker.convert(marker.bounds, to: contentView)
    }

    var body: some View {
        let display = MessageHeaderPolicy.subject(subject)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(display.text)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(display.isPlaceholder ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(UIIdentifier.messageSubject)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, MessageViewerLayoutPolicy.islandVerticalPadding)

            MessageEnvelopeRegion(
                envelope: envelope,
                attachments: attachments,
                messageID: messageID,
                headersStore: headersStore,
                showsSenderIcons: showsSenderIcons,
                isShowingRawSource: isShowingRawSource,
                rawSource: rawSource,
                accent: accent
            )
        }
        .padding(.horizontal, MessageViewerLayoutPolicy.islandContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readerIslandSurface(backdropStyle: backdropStyle)
        .background(ReaderGeometryProbe(role: .subject).allowsHitTesting(false))
    }
}

private enum ReaderGeometryRole {
    case reader
    case subject
}

private struct ReaderGeometryProbe: NSViewRepresentable {
    let role: ReaderGeometryRole

    func makeNSView(context: Context) -> ReaderGeometryView {
        let view = ReaderGeometryView()
        view.role = role
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ReaderGeometryView, context: Context) {
        nsView.role = role
        nsView.reportGeometry()
    }
}

private final class ReaderGeometryView: NSView {
    var role: ReaderGeometryRole = .subject

    override var acceptsFirstResponder: Bool { role == .reader }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func find(_ role: ReaderGeometryRole, in view: NSView) -> ReaderGeometryView? {
        if let marker = view as? ReaderGeometryView, marker.role == role { return marker }
        for child in view.subviews {
            if let found = find(role, in: child) { return found }
        }
        return nil
    }

    private var lastOrigin: CGFloat?

    override var frame: NSRect {
        didSet { reportGeometry() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastOrigin = nil
        reportGeometry()
    }

    func reportGeometry() {
        guard role == .subject, let window, !bounds.isEmpty else { return }
        let origin = convert(bounds, to: nil).minX
        guard origin != lastOrigin else { return }
        lastOrigin = origin
        NotificationCenter.default.post(
            name: MessageSubjectRegion.geometryDidChange,
            object: window
        )
    }
}

private struct EnvelopeRouteAnchors: PreferenceKey {
    struct Value {
        var sender: Anchor<CGRect>?
        var receiver: Anchor<CGRect>?
    }

    static var defaultValue: Value { Value() }

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.sender = next.sender ?? value.sender
        value.receiver = next.receiver ?? value.receiver
    }
}

/// A rounded elbow connects the measured sender and recipient row centers.
/// The straight middle section stretches with the envelope's actual layout.
struct EnvelopeRouteArrow: Shape {
    let senderY: CGFloat
    let receiverY: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + 4
        let right = rect.maxX - 4
        let top = rect.minY + senderY
        let bottom = rect.minY + receiverY
        let radius = min(6, max(0, (bottom - top) / 2), max(0, (right - left) / 2))
        let arrowDepth: CGFloat = 4
        var path = Path()
        path.move(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: left + radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: left, y: top + radius),
            control: CGPoint(x: left, y: top)
        )
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control: CGPoint(x: left, y: bottom)
        )
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.move(to: CGPoint(x: right - arrowDepth, y: bottom - arrowDepth))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - arrowDepth, y: bottom + arrowDepth))
        return path
    }
}

struct MessageEnvelopeRegion: View {
    let envelope: Envelope
    let attachments: [AttachmentInfo]
    let messageID: MessageID
    let headersStore: MessageHeadersStore
    let showsSenderIcons: Bool
    let isShowingRawSource: Bool
    let rawSource: String?
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isShowingRawSource {
                rawHeaderContent
            } else {
                prettyEnvelope
                if !attachments.isEmpty {
                    attachmentRows
                        .padding(.top, MessageViewerLayoutPolicy.attachmentSpacing)
                }
            }
        }
        .font(.subheadline)
        .padding(.top, MessageViewerLayoutPolicy.envelopeTopPadding)
        .padding(.bottom, MessageViewerLayoutPolicy.envelopeBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Text survives the source-mode switch in the same island and lets
        // numeric values roll rather than blink as a remove/insert.
        .contentTransition(.numericText())
        .task(
            id: HeaderLoadDemand(
                messageID: messageID,
                isShowingRawSource: isShowingRawSource,
                hasCachedSource: rawSource != nil
            )
        ) {
            if isShowingRawSource {
                headersStore.loadIfNeeded(for: messageID, cachedSource: rawSource)
            } else {
                headersStore.cancelLoads()
            }
        }
        .onDisappear {
            headersStore.cancelLoad(for: messageID)
        }

    }

    private var prettyEnvelope: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
                senderItem
                    .anchorPreference(key: EnvelopeRouteAnchors.self, value: .bounds) {
                        EnvelopeRouteAnchors.Value(sender: $0)
                    }
                receiverItem
                    .anchorPreference(key: EnvelopeRouteAnchors.self, value: .bounds) {
                        EnvelopeRouteAnchors.Value(receiver: $0)
                    }
            }
            .padding(.leading, 25)
            // Give the identity column first claim on a constrained envelope
            // while keeping each copy button itself content-sized.
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .backgroundPreferenceValue(EnvelopeRouteAnchors.self) { anchors in
                GeometryReader { geometry in
                    if let sender = anchors.sender, let receiver = anchors.receiver {
                        EnvelopeRouteArrow(
                            senderY: geometry[sender].midY,
                            receiverY: geometry[receiver].midY
                        )
                        .stroke(
                            accent.opacity(0.85),
                            style: StrokeStyle(
                                lineWidth: 1.7,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: 25, height: geometry.size.height)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
                sentItem
                if let deliveredDate {
                    deliveredItem(deliveredDate)
                }
            }
            // Dates remain right-aligned and can truncate naturally only when
            // the reader is genuinely narrow; they must not reserve a wide
            // column that starves sender/recipient names at normal widths.
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var senderItem: some View {
        if let sender = envelope.from.first {
            EnvelopeCopyItem(
                symbol: nil,
                payload: MessageHeaderPolicy.copyPayload(for: sender),
                accessibilityLabel: "Sender, \(MessageHeaderPolicy.full(sender))",
                accent: accent,
            ) {
                HStack(alignment: .center, spacing: 8) {
                    if showsSenderIcons {
                        MonogramView(
                            initials: MessageHeaderPolicy.initials(for: sender),
                            accent: accent
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MessageHeaderPolicy.name(of: sender))
                            .font(.headline)
                            .lineLimit(1)
                        Text(sender.address)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Text("Unknown sender")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var receiverItem: some View {
        if let recipients = MessageHeaderPolicy.collapseRecipients(envelope.to) {
            EnvelopeCopyItem(
                symbol: nil,
                payload: MessageHeaderPolicy.copyPayload(for: recipients.first),
                accessibilityLabel: "Recipient, \(MessageHeaderPolicy.full(recipients.first))",
                accent: accent,
            ) {
                HStack(alignment: .center, spacing: 8) {
                    if showsSenderIcons {
                        MonogramView(
                            initials: MessageHeaderPolicy.initials(for: recipients.first),
                            accent: accent
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipients.summary)
                            .font(.headline)
                            .lineLimit(1)
                        Text(recipients.first.address)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } else {
            Text("No recipient")
                .foregroundStyle(.secondary)
        }
    }

    private var sentItem: some View {
        let date = envelope.headerDate ?? envelope.internalDate
        return EnvelopeCopyItem(
            symbol: "paperplane",
            payload: MailDateFormat.envelope(date),
            accessibilityLabel: "Sent, \(MailDateFormat.envelope(date))",
            accent: accent
        ) {
            Text(MailDateFormat.envelope(date))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func deliveredItem(_ date: Date) -> some View {
        EnvelopeCopyItem(
            symbol: "tray.and.arrow.down",
            payload: MailDateFormat.envelope(date),
            accessibilityLabel: "Delivered, \(MailDateFormat.envelope(date))",
            accent: accent
        ) {
            Text(MailDateFormat.envelope(date))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var deliveredDate: Date? {
        guard case .loaded(let headers, _) = headersStore.state(for: messageID) else {
            return nil
        }
        return MessageHeaderPolicy.deliveredDate(from: headers)
    }

    private var attachmentRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { attachment in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text(MessageHeaderPolicy.attachmentName(attachment))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let size = MessageHeaderPolicy.attachmentSize(attachment) {
                        Text(size)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Attachment, \(MessageHeaderPolicy.attachmentName(attachment))")
            }
        }
    }

    @ViewBuilder
    private var rawHeaderContent: some View {
        switch headersStore.state(for: messageID) {
        case .idle, .loading:
            if let headers = headersStore.headers(for: messageID, fallback: envelope) {
                RawHeadersBlock(
                    headers: headers,
                    text: MessageHeaderPolicy.rawHeaderBlock(from: headers)
                )
            } else {
                ProgressView("Loading headers…")
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn’t load headers", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    headersStore.retry(messageID, cachedSource: rawSource)
                }
                .buttonStyle(.link)
            }
            .accessibilityIdentifier("message-headers-error")
        case .loaded(let headers, let text):
            if headers.isEmpty {
                Text("No raw headers found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                RawHeadersBlock(headers: headers, text: text)
            }
        }
    }

}


/// Replaces a copy target's text with a centered clipboard glyph (matching the
/// detailed header's overlay) without changing the target's measured size.
/// Reduced Motion swaps the two states immediately.
private struct CopyFeedbackLabel<Label: View>: View {
    let label: Label
    let isShowingCopy: Bool
    let reduceMotion: Bool

    init(
        isShowingCopy: Bool,
        reduceMotion: Bool,
        @ViewBuilder label: () -> Label
    ) {
        self.label = label()
        self.isShowingCopy = isShowingCopy
        self.reduceMotion = reduceMotion
    }

    var body: some View {
        ZStack(alignment: .center) {
            label
                .opacity(isShowingCopy ? 0 : 1)
            Image(systemName: "doc.on.clipboard")
                .opacity(isShowingCopy ? 1 : 0)
                .accessibilityHidden(true)
        }
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: isShowingCopy ? 0.12 : 0.15),
            value: isShowingCopy
        )
    }
}


/// A copy target presents the same interaction for identities and dates:
/// rounded hover wash, pointer cursor, and brief clipboard confirmation.
/// Bounds follow the label plus padding, never the unused row width; long
/// identities can still compress to the reader's available width.
private struct EnvelopeCopyItem<Label: View>: View {
    let symbol: String?
    let payload: String
    let accessibilityLabel: String
    let accent: Color
    let label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var didCopy = false
    @State private var isShowingQRCode = false
    @State private var copyFeedbackGeneration = 0
    init(
        symbol: String?,
        payload: String,
        accessibilityLabel: String,
        accent: Color,
        @ViewBuilder label: () -> Label
    ) {
        self.symbol = symbol
        self.payload = payload
        self.accessibilityLabel = accessibilityLabel
        self.accent = accent
        self.label = label()
    }

    var body: some View {
        Button(action: copy) {
            HStack(alignment: .center, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(accent)
                        .frame(width: 18, alignment: .center)
                }
                CopyFeedbackLabel(
                    isShowingCopy: didCopy,
                    reduceMotion: reduceMotion
                ) {
                    label
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.clipboard", action: copy)
            Button("Show QR Code", systemImage: "qrcode", action: showQRCode)
                .disabled(!QRCodePolicy.canEncode(payload))
                .help(QRCodePolicy.menuHelp(for: payload))
        }
        .popover(isPresented: $isShowingQRCode, arrowEdge: .top) {
            QRCodeCard(payload: payload)
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(MailMotion.hover, value: isHovered)
    }

    private func showQRCode() {
        guard QRCodePolicy.canEncode(payload) else { return }
        isShowingQRCode = true
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        copyFeedbackGeneration &+= 1
        let generation = copyFeedbackGeneration
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == copyFeedbackGeneration else { return }
            didCopy = false
        }
    }
}


/// The complete unfolded header block uses SF Mono. Each header name and
/// value is its own copy target; there is no block-level control.
private struct RawHeadersBlock: View {
    let headers: [MessageHeaderPolicy.HeaderItem]
    let text: String
    @FocusState private var blockFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MessageViewerLayoutPolicy.envelopePairSpacing) {
            ForEach(headers) { header in
                RawHeaderRow(header: header)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($blockFocused)
    }
}

private struct RawHeaderRow: View {
    let header: MessageHeaderPolicy.HeaderItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            RawHeaderField(
                text: "\(header.name):",
                payload: header.keyCopyText,
                accessibilityLabel: "\(header.name), header name",
                expands: false
            )
            RawHeaderField(
                text: header.value,
                payload: header.valueCopyText,
                accessibilityLabel: "\(header.name), header value",
                expands: true
            )
        }
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RawHeaderField: View {
    let text: String
    let payload: String
    let accessibilityLabel: String
    let expands: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var didCopy = false
    @State private var isShowingQRCode = false
    @State private var copyFeedbackGeneration = 0

    var body: some View {
        Button(action: copy) {
            Text(text)
                .opacity(didCopy ? 0 : 1)
                .frame(
                    maxWidth: expands ? .infinity : nil,
                    alignment: expands ? .leading : .center
                )
                .fixedSize(horizontal: !expands, vertical: false)
                .overlay {
                    Image(systemName: "doc.on.clipboard")
                        .opacity(didCopy ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous))
                .animation(
                    reduceMotion
                        ? nil
                        : .easeOut(duration: didCopy ? 0.12 : 0.15),
                    value: didCopy
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Copies \(payload)")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.clipboard", action: copy)
            Button("Show QR Code", systemImage: "qrcode", action: showQRCode)
                .disabled(!QRCodePolicy.canEncode(payload))
                .help(QRCodePolicy.menuHelp(for: payload))
        }
        .popover(isPresented: $isShowingQRCode, arrowEdge: .top) {
            QRCodeCard(payload: payload)
        }
        .onHover { hovered in
            isHovered = hovered
            if hovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(MailMotion.hover, value: isHovered)
    }

    private func showQRCode() {
        guard QRCodePolicy.canEncode(payload) else { return }
        isShowingQRCode = true
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)

        copyFeedbackGeneration &+= 1
        let generation = copyFeedbackGeneration
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == copyFeedbackGeneration else { return }
            didCopy = false
        }
    }
}




/// Blocked remote content is a body state the reader discloses before the
/// message is read, not a permanently disabled control after it.
private struct RemoteImageNotice: View {
    let load: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text("Remote images are blocked in this message.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Load Images", action: load)
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct PlainTextBody: View {
    let text: String
    let query: String
    let selectedMatchIndex: Int?
    let findTick: UInt64
    let pool: ReaderSurfacePool
    let tabID: UUID?
    let messageID: MessageID?
    var onSurfaceReady: ((UUID, MessageID) -> Void)?

    var body: some View {
        HighlightedMessageText(
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            findTick: findTick,
            pool: pool,
            tabID: tabID,
            messageID: messageID,
            onSurfaceReady: onSurfaceReady,
            font: MessageTypography.bodyFont,
            paragraphStyle: MessageTypography.bodyParagraphStyle
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A parse failure is a message state: it sits at the top of the body island,
/// above the source text it replaces.
struct QuarantineBanner: View {
    let showingRaw: Bool
    let loadRaw: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("This message couldn’t be parsed")
                    .font(.headline)
                Text("Mailternal kept it quarantined so it can’t stall the folder. You can inspect the capped raw source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(showingRaw ? "Showing Raw Source" : "Show Raw Source", action: loadRaw)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(showingRaw)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
        .accessibilityIdentifier(UIIdentifier.quarantineBanner)
    }
}

struct RawSourceView: View {
    let text: String
    var query: String = ""
    var selectedMatchIndex: Int?
    var findTick: UInt64 = 0

    var body: some View {
        HighlightedMessageText(
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            findTick: findTick,
            font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            paragraphStyle: .default
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HighlightedMessageText: NSViewRepresentable {
    let text: String
    let query: String
    let selectedMatchIndex: Int?
    let findTick: UInt64
    var pool: ReaderSurfacePool?
    var tabID: UUID?
    var messageID: MessageID?
    var onSurfaceReady: ((UUID, MessageID) -> Void)?
    var font: NSFont = MessageTypography.bodyFont
    var paragraphStyle: NSParagraphStyle = MessageTypography.bodyParagraphStyle

    final class Coordinator {
        var lastTick: UInt64 = .max
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HighlightedMessageTextHost {
        let host = HighlightedMessageTextHost()
        host.update(
            pool: pool,
            tabID: tabID,
            messageID: messageID,
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            font: font,
            paragraphStyle: paragraphStyle,
            onSurfaceReady: onSurfaceReady
        )
        return host
    }
    func updateNSView(_ host: HighlightedMessageTextHost, context: Context) {
        host.update(
            pool: pool,
            tabID: tabID,
            messageID: messageID,
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            font: font,
            paragraphStyle: paragraphStyle,
            onSurfaceReady: onSurfaceReady
        )
        guard context.coordinator.lastTick != findTick else { return }
        context.coordinator.lastTick = findTick
        host.scrollToSelection(
            in: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView host: HighlightedMessageTextHost,
        context: Context
    ) -> CGSize? {
        host.sizeThatFits(proposal)
    }

    static func dismantleNSView(_ host: HighlightedMessageTextHost, coordinator: Coordinator) {
        host.detach()
    }
}

@MainActor
final class HighlightedMessageTextHost: NSView {
    private lazy var fallbackView = ReaderPlainTextView()
    private var installedView: ReaderPlainTextView?
    private weak var pool: ReaderSurfacePool?
    private var installedTabID: UUID?

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
        guard let view = installedView else { return }
        if bounds.width > 0,
           let container = view.textContainer,
           abs(container.containerSize.width - bounds.width) > 0.5 {
            container.containerSize = NSSize(
                width: bounds.width,
                height: .greatestFiniteMagnitude
            )
        }
        if view.frame != bounds {
            view.frame = bounds
        }
    }

    func detach() {
        installedView?.removeFromSuperview()
        installedView = nil
        installedTabID = nil
        pool = nil
    }
    func update(
        pool: ReaderSurfacePool?,
        tabID: UUID?,
        messageID: MessageID?,
        text: String,
        query: String,
        selectedMatchIndex: Int?,
        font: NSFont,
        paragraphStyle: NSParagraphStyle,
        onSurfaceReady: ((UUID, MessageID) -> Void)?
    ) {
        let nextView: ReaderPlainTextView
        let nextTabID: UUID?
        if let tabID, let pool {
            nextView = pool.textView(for: tabID)
            nextTabID = tabID
        } else {
            // Raw source and transient no-tab states deliberately use an
            // unpooled fallback so only actual tabs consume LRU entries.
            nextView = fallbackView
            nextTabID = nil
        }
        if installedView !== nextView {
            installedView?.removeFromSuperview()
            installedView = nextView
            addSubview(nextView)
            nextView.translatesAutoresizingMaskIntoConstraints = true
            nextView.autoresizingMask = [.width, .height]
            nextView.frame = bounds
        } else if let nextTabID, let pool {
            pool.touch(nextTabID)
        }
        self.pool = pool
        installedTabID = nextTabID

        guard let installedView else { return }
        let didRender = installedView.render(
            messageID: messageID,
            text: text,
            query: query,
            selectedMatchIndex: selectedMatchIndex,
            font: font,
            paragraphStyle: paragraphStyle
        )
        if didRender, let installedTabID, let pool = self.pool {
            pool.invalidatePlainLayout(for: installedTabID)
        }
        if let installedTabID,
           let messageID {
            onSurfaceReady?(installedTabID, messageID)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize? {
        guard let view = installedView else { return nil }
        let width = proposal.width ?? view.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        guard let identity = view.renderedIdentity else {
            return CGSize(width: width, height: MessageTypography.bodyLineHeight)
        }

        if let installedTabID,
           let pool,
           let height = pool.cachedPlainHeight(
               for: installedTabID,
               identity: identity,
               width: width
           ) {
            return CGSize(width: width, height: height)
        }

        // SwiftUI probes several widths before placement. Measuring must not
        // resize NSTextView and trigger another AppKit layout/constraint pass.
        let widthChanged = abs((view.textContainer?.containerSize.width ?? 0) - width) > 0.5
        if widthChanged {
            view.textContainer?.containerSize = NSSize(
                width: width,
                height: .greatestFiniteMagnitude
            )
        }
        guard let container = view.textContainer else {
            return CGSize(width: width, height: MessageTypography.bodyLineHeight)
        }
        view.layoutManager?.ensureLayout(for: container)
        let used = view.layoutManager?.usedRect(for: container) ?? .zero
        let height = max(ceil(used.height), MessageTypography.bodyLineHeight)
        if let installedTabID, let pool = self.pool {
            pool.recordPlainHeight(
                height,
                for: installedTabID,
                identity: identity,
                width: width,
                revision: view.renderedRevision
            )
        }
        return CGSize(width: width, height: height)
    }

    func scrollToSelection(
        in text: String,
        query: String,
        selectedMatchIndex: Int?
    ) {
        guard let view = installedView,
              let selectedMatchIndex
        else {
            return
        }
        let matches = MessageFind.ranges(in: text, query: query)
        guard matches.indices.contains(selectedMatchIndex) else { return }
        let nsRange = NSRange(matches[selectedMatchIndex], in: text)
        DispatchQueue.main.async {
            view.scrollRangeToVisible(nsRange)
            if nsRange.length > 0 {
                view.showFindIndicator(for: nsRange)
            }
        }
    }
}

struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    let selectedMatchNumber: Int?
    let next: () -> Void
    let previous: () -> Void
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in message", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(next)
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: previous) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            Button(action: next) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .onAppear { fieldFocused = true }
        .onExitCommand(perform: close)
        .defaultFocus($fieldFocused, true)
    }

    private var countLabel: String {
        if query.isEmpty { return "" }
        if matchCount == 0 { return "No results" }
        if let selectedMatchNumber {
            return "\(selectedMatchNumber) of \(matchCount)"
        }
        return "\(matchCount)"
    }
}
