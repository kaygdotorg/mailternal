import AppKit
import SwiftUI
import MailternalInterfaces
import os

private let readerTabBarSignpostLog = OSLog(
    subsystem: "org.kayg.mailternal",
    category: "ReaderTabs"
)

/// The main-window reader's single tab row. It owns no message state: opening,
/// activation, persistence, and mutation all stay on AppModel/ReaderTabs.
struct ReaderTabBar: View {
    @Bindable var model: AppModel
    var trailingGap: CGFloat = 0
    init(model: AppModel) {
        self.model = model
    }

    /// Native input routing uses the strip's local probe in stacked layouts.
    /// Window-toolbar placement is measured by MainToolbarController instead.
    static func frame(in contentView: NSView) -> CGRect? {
        func find(in view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if view is ReaderTabWindowProbeView, view.bounds.width > 0 { return view }
            for child in view.subviews {
                if let probe = find(in: child) { return probe }
            }
            return nil
        }
        guard let probe = find(in: contentView) else { return nil }
        return probe.convert(probe.bounds, to: contentView)
    }

    @State private var hoveredTabID: UUID?
    @State private var hoverDismissTask: Task<Void, Never>?
    @State private var hoverPopover: ReaderTabHoverPopover?
    @State private var isCardHovered = false
    @State private var tabBarView: NSView?
    @State private var showsLeadingFade = false
    @FocusState private var focusedTabID: UUID?

    var body: some View {
        let _ = os_signpost(
            .event,
            log: readerTabBarSignpostLog,
            name: "ReaderTabBar.body"
        )
        if model.tabs.tabs.count > 1 && !model.isSearchPresented {
            let metadata = tabMetadataByMessage()
            GeometryReader { geometry in
                let widths = model.tabs.tabs.map {
                    tabWidth(for: $0, metadata: metadata)
                }
                let contentWidth = ReaderTabLayoutPolicy.contentWidth(tabWidths: widths)
                let viewportWidth = max(0, geometry.size.width + trailingGap)
                // Extend only through the measured native inter-item gap.
                // The clear end of the mask stops at the action capsule.
                tabViewport(
                    width: viewportWidth,
                    widths: widths,
                    contentWidth: contentWidth,
                    metadata: metadata
                )
                .frame(width: viewportWidth, height: ReaderTabLayoutPolicy.rowHeight)
                .coordinateSpace(name: "reader-tab-bar")
            }
            .frame(height: ReaderTabLayoutPolicy.rowHeight)
            .background(
                ReaderTabWindowProbe { view in
                    // The toolbar owns card/capsule alignment. This probe
                    // only tracks the strip's laid-out hover coordinates.
                    DispatchQueue.main.async {
                        if tabBarView !== view {
                            tabBarView = view
                        }
                        guard let anchor = view as? ReaderTabWindowProbeView,
                              anchor.window != nil else { return }
                        let frameInWindow = anchor.convert(anchor.bounds, to: nil)
                        let geometryChanged = anchor.lastFrameInWindow != frameInWindow
                        anchor.lastFrameInWindow = frameInWindow
                        if geometryChanged,
                           let hoverPopover,
                           let contentFrame = anchor.hoverContentFrame {
                            let frame = contentFrame.offsetBy(
                                dx: -anchor.horizontalOffset,
                                dy: 0
                            )
                            if frame.intersects(anchor.bounds) {
                                hoverPopover.present(tabFrame: frame, in: anchor)
                            } else {
                                dismissHoverCard()
                            }
                        }
                    }
                }
            )
            .zIndex(hoveredTabID == nil ? 0 : 1)
            .accessibilityIdentifier(UIIdentifier.readerTabBar)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .contextMenu {
                        Picker("Tab Style", selection: Bindable(model.appearance).tabStyle) {
                            ForEach(ReaderTabStyle.allCases, id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                    }
            }
            .onChange(of: model.tabs.activeID) { _, _ in
                if let hoveredTabID,
                   !canPresentHoverPreview(for: hoveredTabID) {
                    dismissHoverCard()
                }
            }
            .onChange(of: isCardHovered) { _, cardHovered in
                if cardHovered {
                    hoverDismissTask?.cancel()
                    hoverDismissTask = nil
                } else if hoveredTabID == nil {
                    scheduleHoverDismissal()
                }
            }
            .onDisappear {
                dismissHoverCard()
            }
        }
    }

    private func tabViewport(
        width: CGFloat,
        widths: [CGFloat],
        contentWidth: CGFloat,
        metadata: [MessageID: ReaderTabMetadata]
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ReaderTabLayoutPolicy.tabSpacing) {
                    ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        let width = index < widths.count
                            ? widths[index]
                            : ReaderTabLayoutPolicy.minimumTabWidth
                        let tabMetadata = metadata[tab.message] ?? .empty
                        ReaderTabItem(
                            model: model,
                            tab: tab,
                            subject: tabMetadata.subject,
                            sender: tabMetadata.sender,
                            width: width,
                            onHoverChanged: { hovering in
                                updateHover(
                                    for: tab.id,
                                    hovering: hovering,
                                    contentFrame: CGRect(
                                        x: widths.prefix(index).reduce(0, +)
                                            + CGFloat(index) * ReaderTabLayoutPolicy.tabSpacing,
                                        y: 0,
                                        width: width,
                                        height: ReaderTabLayoutPolicy.rowHeight
                                    )
                                )
                            },
                            onTabCommand: {
                                model.noteQATabCommand(
                                    tabID: tab.id,
                                    messageID: tab.message
                                )
                            },
                            focusedTabID: $focusedTabID
                        )
                        .id(tab.id)
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, location in
                            guard let source = items.first,
                                  let sourceID = UUID(uuidString: source),
                                  let target = model.tabs.tabs.firstIndex(where: { $0.id == tab.id }),
                                  sourceID != tab.id else { return false }
                            let sourceIndex = model.tabs.tabs.firstIndex { $0.id == sourceID } ?? target
                            let destination = ReaderTabsPolicy.dropDestination(
                                sourceIndex: sourceIndex,
                                targetIndex: target,
                                afterTarget: location.x > width / 2,
                                count: model.tabs.tabs.count
                            )
                            model.tabs.move(sourceID, to: destination)
                            return true
                        }
                    }
                }
                .padding(
                    .trailing,
                    ReaderTabLayoutPolicy.showsFade(contentWidth: contentWidth, viewportWidth: width)
                        ? ReaderTabLayoutPolicy.rightFadeWidth : 0
                )
                .frame(minWidth: max(width, contentWidth), alignment: .leading)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading
            } action: { _, offset in
                // Keep continuous geometry outside SwiftUI state; scrolling
                // must not rebuild every tab or republish layout preferences.
                (tabBarView as? ReaderTabWindowProbeView)?.horizontalOffset = offset
                if hoverPopover != nil || hoveredTabID != nil {
                    dismissHoverCard()
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.x + geometry.contentInsets.leading > 0.5
            } action: { _, isScrolled in
                // Only the origin crossing invalidates the mask, not each pixel.
                showsLeadingFade = isScrolled
            }
            .focusEffectDisabled(true)
            .frame(width: width, height: ReaderTabLayoutPolicy.rowHeight)
            .mask {
                tabViewportMask(
                    contentWidth: contentWidth,
                    viewportWidth: width
                )
            }
            .onChange(of: model.tabs.activeID, initial: true) { _, activeID in
                guard let activeID else { return }
                proxy.scrollTo(activeID, anchor: .center)
            }
            .onChange(of: width) { _, _ in
                guard let activeID = model.tabs.activeID else { return }
                proxy.scrollTo(activeID, anchor: .center)
            }
            .onChange(of: widths) { _, _ in
                guard let activeID = model.tabs.activeID else { return }
                proxy.scrollTo(activeID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func tabViewportMask(
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> some View {
        if ReaderTabLayoutPolicy.showsFade(
            contentWidth: contentWidth,
            viewportWidth: viewportWidth
        ) {
            GeometryReader { maskGeometry in
                let maskWidth = max(maskGeometry.size.width, 1)
                let fadeFraction = min(
                    1,
                    ReaderTabLayoutPolicy.rightFadeWidth / maskWidth
                )
                let rightFadeStart = max(
                    0,
                    min(1, 1 - fadeFraction)
                )
                // When both ramps would overlap, meet them at the midpoint so
                // every stop remains ordered and the strip never hard-clips.
                let leadingFadeEnd = min(0.5, fadeFraction)
                let orderedRightFadeStart = max(0.5, rightFadeStart)
                let stops: [Gradient.Stop] = [
                    .init(color: showsLeadingFade ? .clear : .black, location: 0),
                    .init(color: .black, location: leadingFadeEnd),
                    .init(color: .black, location: orderedRightFadeStart),
                    .init(color: .clear, location: 1)
                ]
                LinearGradient(
                    stops: stops,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        } else {
            Color.white
        }
    }

    private func tabMetadataByMessage(includeHTMLPreview: Bool = false) -> [MessageID: ReaderTabMetadata] {
        let tabMessages = Set(model.tabs.tabs.map(\.message))
        var metadata: [MessageID: ReaderTabMetadata] = [:]
        metadata.reserveCapacity(tabMessages.count + 1)
        for row in model.listRows where tabMessages.contains(row.id) {
            metadata[row.id] = ReaderTabMetadata(
                subject: row.subject,
                sender: row.from,
                preview: row.preview,
                receivedDate: row.date
            )
        }
        if let detail = model.detail, metadata[detail.id] == nil {
            let sender = detail.envelope.from.first.map {
                ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.address
            }
            metadata[detail.id] = ReaderTabMetadata(
                subject: detail.envelope.subject,
                sender: sender,
                preview: detail.bodyText
                    ?? (includeHTMLPreview ? detail.sanitizedHTML.map(Self.plainText(fromHTML:)) : nil)
                    ?? "",
                receivedDate: detail.envelope.headerDate ?? detail.envelope.internalDate
            )
        }
        return metadata
    }

    private func tabWidth(
        for tab: ReaderTab,
        metadata: [MessageID: ReaderTabMetadata]
    ) -> CGFloat {
        let title = metadata[tab.message]?.subject ?? ""
        let displayTitle = title.isEmpty ? "No Subject" : title
        let titleWidth: CGFloat
        if ReaderTabStylePolicy.showsSubject(for: model.appearance.tabStyle) {
            let font = NSFont.preferredFont(forTextStyle: .subheadline)
            titleWidth = ceil(
                (displayTitle as NSString).size(withAttributes: [.font: font]).width
            )
        } else {
            titleWidth = 0
        }
        let leadingWidth = ReaderTabStylePolicy.showsLeadingSlot(
            for: model.appearance.tabStyle,
            isHovered: false
        ) ? ReaderTabLayoutPolicy.leadingSlotWidth : 0
        let intrinsic = leadingWidth
            + titleWidth
            + (titleWidth > 0 ? ReaderTabLayoutPolicy.subjectItemSpacing : 0)
            + (titleWidth > 0 ? ReaderTabLayoutPolicy.subjectLeadingPadding : 0)
            + (titleWidth > 0 ? ReaderTabLayoutPolicy.subjectTrailingPadding : 0)
        return ReaderTabLayoutPolicy.tabWidth(intrinsic: intrinsic)
    }

    private var hoveredPreview: ReaderTabPreview? {
        guard let hoveredTabID,
              let tab = model.tabs.tabs.first(where: { $0.id == hoveredTabID }) else {
            return nil
        }
        return preview(for: tab, metadata: tabMetadataByMessage(includeHTMLPreview: true))
    }

    private func preview(
        for tab: ReaderTab,
        metadata: [MessageID: ReaderTabMetadata]
    ) -> ReaderTabPreview {
        let value = metadata[tab.message] ?? .empty
        return ReaderTabPreview(
            id: tab.id,
            subject: value.subject.isEmpty ? "No Subject" : value.subject,
            preview: value.preview,
            sender: value.sender,
            receivedDate: value.receivedDate
        )
    }

    private func updateHover(for id: UUID, hovering: Bool, contentFrame: CGRect) {
        if hovering {
            guard canPresentHoverPreview(for: id) else {
                dismissHoverCard()
                return
            }
            hoverDismissTask?.cancel()
            hoverDismissTask = nil
            if hoveredTabID != id {
                hoveredTabID = id
            }
            showHoverPanel(for: id, contentFrame: contentFrame)
            return
        }

        guard hoveredTabID == id else { return }
        hoveredTabID = nil
        scheduleHoverDismissal()
    }

    /// Shared gate for hover events, delayed anchor updates, and active-tab
    /// changes: the selected tab never owns a preview.
    private func canPresentHoverPreview(for id: UUID) -> Bool {
        model.tabs.activeID != id
    }

    private func showHoverPanel(for id: UUID, contentFrame: CGRect) {
        guard canPresentHoverPreview(for: id),
              let preview = hoveredPreview,
              let anchor = tabBarView as? ReaderTabWindowProbeView else {
            if hoveredTabID == id {
                dismissHoverCard()
            }
            return
        }
        let frame = contentFrame.offsetBy(
            dx: -anchor.horizontalOffset,
            dy: 0
        )
        guard !frame.isEmpty, frame.intersects(anchor.bounds) else { return }
        let card = ReaderTabHoverCard(
            subject: preview.subject,
            preview: preview.preview,
            sender: preview.sender,
            receivedDate: preview.receivedDate
        )
        let popover: ReaderTabHoverPopover
        if let hoverPopover {
            popover = hoverPopover
            popover.update(card: card)
        } else {
            popover = ReaderTabHoverPopover(card: card, cardHovered: $isCardHovered)
            hoverPopover = popover
        }
        anchor.hoverContentFrame = contentFrame
        popover.present(tabFrame: frame, in: anchor)
    }

    private func scheduleHoverDismissal() {
        hoverDismissTask?.cancel()
        guard !isCardHovered else { return }
        hoverDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !isCardHovered, hoveredTabID == nil else { return }
            hoverPopover?.dismiss()
            hoverPopover = nil
            hoverDismissTask = nil
        }
    }

    private func dismissHoverCard() {
        hoverDismissTask?.cancel()
        hoverDismissTask = nil
        hoverPopover?.dismiss()
        hoverPopover = nil
        hoveredTabID = nil
        isCardHovered = false
    }



    private static func plainText(fromHTML html: String) -> String {

        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

private struct ReaderTabMetadata {
    let subject: String
    let sender: String?
    let preview: String
    let receivedDate: Date?

    static let empty = ReaderTabMetadata(
        subject: "",
        sender: nil,
        preview: "",
        receivedDate: nil
    )
}


@MainActor
/// Reports the AppKit view that backs the strip's coordinate space so the
/// hover popover can be anchored to a tab frame.
private struct ReaderTabWindowProbe: NSViewRepresentable {
    let onViewReady: (NSView?) -> Void

    func makeNSView(context: Context) -> ReaderTabWindowProbeView {
        ReaderTabWindowProbeView(onViewReady: onViewReady)
    }

    func updateNSView(_ nsView: ReaderTabWindowProbeView, context: Context) {
        nsView.onViewReady = onViewReady
        nsView.resolveWindow()
    }
}

@MainActor
private final class ReaderTabWindowProbeView: NSView {
    var onViewReady: (NSView?) -> Void
    var horizontalOffset: CGFloat = 0
    var lastFrameInWindow: CGRect?
    var hoverContentFrame: CGRect?

    init(onViewReady: @escaping (NSView?) -> Void) {
        self.onViewReady = onViewReady
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindow()
    }
    override func layout() {
        super.layout()
        resolveWindow()
    }


    func resolveWindow() {
        onViewReady(window == nil ? nil : self)
    }
}
private struct ReaderTabPreview: Identifiable {
    let id: UUID
    let subject: String
    let preview: String
    let sender: String?
    let receivedDate: Date?
}
