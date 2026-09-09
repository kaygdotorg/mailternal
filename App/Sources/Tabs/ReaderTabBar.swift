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
    @State private var hoverPresentationTask: Task<Void, Never>?
    @State private var previewTabID: UUID?
    @State private var hoverDismissTask: Task<Void, Never>?
    @State private var hoverPopover: ReaderTabHoverPopover?
    @State private var isCardHovered = false
    @State private var showsLeadingFade = false
    @State private var metadataCache = ReaderTabMetadataCache()
    @State private var widthCache = ReaderTabWidthCache()
    @State private var scrollState = ReaderTabScrollState()
    @FocusState private var focusedTabID: UUID?

    var body: some View {
        let _ = os_signpost(
            .event,
            log: readerTabBarSignpostLog,
            name: "ReaderTabBar.body"
        )
        if model.tabs.tabs.count > 1 && !model.isSearchPresented {
            let metadata = tabMetadataByMessage()
            let widths = widthCache.widths(
                for: model.tabs.tabs,
                metadata: metadata,
                style: model.appearance.tabStyle
            )
            let contentWidth = ReaderTabLayoutPolicy.contentWidth(tabWidths: widths)
            GeometryReader { geometry in
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
            .background(ReaderTabWindowProbe())
            .zIndex(hoveredTabID == nil ? 0 : 1)
            .accessibilityIdentifier(UIIdentifier.readerTabBar)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .contextMenu {
                        Picker("Tab Style", selection: Binding(
                            get: { model.appearance.tabStyle },
                            set: { style in
                                model.dispatchFromUI(.setSetting(AutomationPreferences.Keys.tabStyle, style.rawValue))
                            }
                        )) {
                            ForEach(ReaderTabStyle.allCases, id: \.self) { style in
                                Text(style.label).tag(style)
                            }
                        }
                    }
            }
            .onChange(of: model.tabs.activeID) { _, _ in
                dismissHoverCard()
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
                scrollState.isUserDriven = false
                scrollState.hoverSuspendedAt = nil
                scrollState.pendingReveal = false
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
                            onHoverChanged: { hovering, tabView in
                                updateHover(for: tab.id, hovering: hovering, tabView: tabView)
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
                            model.moveTab(sourceID, to: destination)
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
                // Moving content beneath a stationary pointer is scrolling,
                // not a request to construct another native preview window.
                scrollState.hoverSuspendedAt = NSEvent.mouseLocation
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
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    scrollState.isUserDriven = true
                    scrollState.hoverSuspendedAt = NSEvent.mouseLocation
                    if hoverPopover != nil || hoveredTabID != nil {
                        dismissHoverCard()
                    }
                default:
                    scrollState.isUserDriven = false
                    if scrollState.pendingReveal {
                        scrollState.pendingReveal = false
                        if let activeID = model.tabs.activeID {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: model.tabs.activeID, initial: true) { _, activeID in
                guard let activeID else { return }
                scrollState.pendingReveal = false
                // Activation is authoritative: reveal the selected tab even
                // when a wheel gesture is still settling.
                proxy.scrollTo(activeID, anchor: .center)
            }
            .onChange(of: width) { _, _ in
                guard let activeID = model.tabs.activeID else { return }
                guard !scrollState.isUserDriven else {
                    scrollState.pendingReveal = true
                    return
                }
                proxy.scrollTo(activeID, anchor: .center)
            }
            .onChange(of: widths) { _, _ in
                guard let activeID = model.tabs.activeID else { return }
                guard !scrollState.isUserDriven else {
                    scrollState.pendingReveal = true
                    return
                }
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
        if !includeHTMLPreview {
            return metadataCache.metadata(
                tabs: model.tabs.tabs,
                rows: model.listRows,
                detail: model.detail,
                listRevision: model.listContentRevision
            )
        }
        let tabMessages = Set(model.tabs.tabs.map(\.message))
        var metadata = tabMetadataByMessage()
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
                    ?? detail.sanitizedHTML.map(Self.plainText(fromHTML:))
                    ?? "",
                receivedDate: detail.envelope.headerDate ?? detail.envelope.internalDate
            )
        }
        return metadata
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

    private func updateHover(for id: UUID, hovering: Bool, tabView: NSView?) {
        if hovering {
            guard let tabView, canPresentHoverPreview(for: id) else {
                if hoverPopover != nil || hoveredTabID != nil {
                    dismissHoverCard()
                }
                return
            }
            scrollState.hoverSuspendedAt = nil
            guard hoveredTabID != id
                || (hoverPresentationTask == nil && hoverPopover?.isShown != true) else { return }
            hoverPresentationTask?.cancel()
            hoverPresentationTask = nil
            hoverDismissTask?.cancel()
            hoverDismissTask = nil
            hoveredTabID = id
            if previewTabID == id, hoverPopover?.isShown == true {
                return
            }
            hoverPopover?.dismiss()
            hoverPopover = nil
            previewTabID = nil
            isCardHovered = false
            hoverPresentationTask = Task { @MainActor [weak tabView] in
                do {
                    try await Task.sleep(for: ReaderTabTokens.hoverDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                hoverPresentationTask = nil
                guard let tabView, hoveredTabID == id, canPresentHoverPreview(for: id) else { return }
                showHoverPanel(for: id, tabView: tabView)
            }
            return
        }

        guard hoveredTabID == id else { return }
        hoverPresentationTask?.cancel()
        hoverPresentationTask = nil
        hoveredTabID = nil
        scheduleHoverDismissal()
    }

    /// Pointer movement can begin a dwell; scroll-driven hover/layout events
    /// cannot, including phase-less mouse wheels. Recheck after the delay.
    private func canPresentHoverPreview(for id: UUID) -> Bool {
        guard model.tabs.activeID != id,
              !scrollState.isUserDriven,
              NSApp.currentEvent?.type != .scrollWheel else { return false }
        if let location = scrollState.hoverSuspendedAt {
            return NSEvent.mouseLocation != location
        }
        return true
    }

    private func showHoverPanel(for id: UUID, tabView: NSView) {
        guard canPresentHoverPreview(for: id),
              let preview = hoveredPreview,
              tabView.window != nil else {
            if hoveredTabID == id {
                dismissHoverCard()
            }
            return
        }
        let frame = tabView.visibleRect
        guard !frame.isEmpty else { return }
        let card = ReaderTabHoverCard(
            subject: preview.subject,
            preview: preview.preview,
            sender: preview.sender,
            receivedDate: preview.receivedDate
        )
        let popover = ReaderTabHoverPopover(card: card, cardHovered: $isCardHovered)
        hoverPopover = popover
        popover.present(tabFrame: frame, in: tabView)
        previewTabID = id
    }

    private func scheduleHoverDismissal() {
        hoverDismissTask?.cancel()
        guard !isCardHovered else { return }
        hoverDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !isCardHovered, hoveredTabID == nil else { return }
            hoverPopover?.dismiss()
            hoverPopover = nil
            previewTabID = nil
            hoverDismissTask = nil
        }
    }

    private func dismissHoverCard() {
        hoverPresentationTask?.cancel()
        hoverPresentationTask = nil
        previewTabID = nil
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

/// Caches the small display projection needed by the strip. Known labels stay
/// with open messages even when their rows leave the current page; activation
/// must not shrink the previous tab to "No Subject" and relayout the strip.
/// Hover previews intentionally use the uncached, full projection below.
private final class ReaderTabMetadataCache {
    private var cachedListRevision: UInt64?
    private var cachedMessages: [MessageID] = []
    private var cachedDetailID: MessageID?
    private var cachedDetailSubject = ""
    private var cachedDetailSender: String?
    private var cachedDetailDate: Date?
    private var baseValues: [MessageID: ReaderTabMetadata] = [:]
    private var values: [MessageID: ReaderTabMetadata] = [:]

    func metadata(
        tabs: [ReaderTab],
        rows: [MessageRow],
        detail: MessageDetail?,
        listRevision: UInt64
    ) -> [MessageID: ReaderTabMetadata] {
        let messages = tabs.map(\.message)
        let listChanged = cachedListRevision != listRevision || cachedMessages != messages
        let detailID = detail?.id
        let detailSubject = detail?.envelope.subject ?? ""
        let detailSender = detail?.envelope.from.first.map {
            ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.address
        }
        let detailDate = detail?.envelope.headerDate ?? detail?.envelope.internalDate
        let detailChanged = cachedDetailID != detailID
            || cachedDetailSubject != detailSubject
            || cachedDetailSender != detailSender
            || cachedDetailDate != detailDate
        guard listChanged || detailChanged else {
            return values
        }

        if listChanged {
            let tabMessages = Set(messages)
            var base = baseValues.filter { tabMessages.contains($0.key) }
            base.reserveCapacity(tabMessages.count + 1)
            for row in rows where tabMessages.contains(row.id) {
                base[row.id] = ReaderTabMetadata(
                    subject: row.subject,
                    sender: row.from,
                    preview: row.preview,
                    receivedDate: row.date
                )
            }
            baseValues = base
            cachedListRevision = listRevision
            cachedMessages = messages
        }

        // Retain detail-only labels after activation moves elsewhere. Keep
        // body text out of this display cache; preview construction owns it.
        if let detail, cachedMessages.contains(detail.id), baseValues[detail.id] == nil {
            baseValues[detail.id] = ReaderTabMetadata(
                subject: detailSubject,
                sender: detailSender,
                preview: "",
                receivedDate: detailDate
            )
        }
        cachedDetailID = detailID
        cachedDetailSubject = detailSubject
        cachedDetailSender = detailSender
        cachedDetailDate = detailDate
        values = baseValues
        return values
    }
}

/// Intrinsic width measurement is stable for a tab identity until its subject,
/// display style, or preferred font changes. Keeping that result out of the
/// SwiftUI value tree avoids measuring every open title on parent invalidation.
private final class ReaderTabWidthCache {
    private struct Entry {
        let subject: String
        let width: CGFloat
    }

    private var cachedStyle: ReaderTabStyle?
    private var cachedFontName: String?
    private var cachedFontSize: CGFloat?
    private var cachedTabIDs: [UUID] = []
    private var widthsByTabID: [UUID: Entry] = [:]

    func widths(
        for tabs: [ReaderTab],
        metadata: [MessageID: ReaderTabMetadata],
        style: ReaderTabStyle
    ) -> [CGFloat] {
        let font = ReaderTabStylePolicy.showsSubject(for: style)
            ? NSFont.preferredFont(forTextStyle: .subheadline)
            : nil
        let fontName = font?.fontName
        let fontSize = font?.pointSize
        if cachedStyle != style
            || cachedFontName != fontName
            || cachedFontSize != fontSize {
            widthsByTabID.removeAll(keepingCapacity: true)
            cachedStyle = style
            cachedFontName = fontName
            cachedFontSize = fontSize
        }

        let tabIDs = tabs.map(\.id)
        if cachedTabIDs != tabIDs {
            let liveIDs = Set(tabIDs)
            widthsByTabID = widthsByTabID.filter { liveIDs.contains($0.key) }
            cachedTabIDs = tabIDs
        }

        var widths: [CGFloat] = []
        widths.reserveCapacity(tabs.count)
        for tab in tabs {
            let subject = metadata[tab.message]?.subject ?? ""
            if let entry = widthsByTabID[tab.id], entry.subject == subject {
                widths.append(entry.width)
                continue
            }
            let width = Self.width(for: subject, style: style, font: font)
            widthsByTabID[tab.id] = Entry(subject: subject, width: width)
            widths.append(width)
        }
        return widths
    }

    private static func width(
        for subject: String,
        style: ReaderTabStyle,
        font: NSFont?
    ) -> CGFloat {
        let displayTitle = subject.isEmpty ? "No Subject" : subject
        let titleWidth: CGFloat
        if ReaderTabStylePolicy.showsSubject(for: style), let font {
            titleWidth = ceil(
                (displayTitle as NSString).size(withAttributes: [.font: font]).width
            )
        } else {
            titleWidth = 0
        }
        let leadingWidth = ReaderTabStylePolicy.showsLeadingSlot(
            for: style,
            isHovered: false
        ) ? ReaderTabLayoutPolicy.leadingSlotWidth : 0
        let intrinsic = leadingWidth
            + titleWidth
            + (titleWidth > 0 ? ReaderTabLayoutPolicy.subjectItemSpacing : 0)
            + (titleWidth > 0 ? ReaderTabLayoutPolicy.subjectLeadingPadding : 0)
            + (titleWidth > 0 ? ReaderTabLayoutPolicy.subjectTrailingPadding : 0)
        return ReaderTabLayoutPolicy.tabWidth(intrinsic: intrinsic)
    }
}

/// Scroll phase is kept outside SwiftUI state so wheel motion does not rebuild
/// the strip. Width changes still reveal the active tab once user scrolling has
/// settled, while activation remains authoritative in the view modifier.
private final class ReaderTabScrollState {
    var isUserDriven = false
    var pendingReveal = false
    var hoverSuspendedAt: NSPoint?
}


/// Marker for native input routing in stacked layouts. Hover positioning uses
/// each tab's actual native view, not this viewport or estimated content offsets.
@MainActor
private struct ReaderTabWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderTabWindowProbeView {
        ReaderTabWindowProbeView()
    }

    func updateNSView(_ nsView: ReaderTabWindowProbeView, context: Context) {}
}

@MainActor
private final class ReaderTabWindowProbeView: NSView {}

private struct ReaderTabPreview: Identifiable {
    let id: UUID
    let subject: String
    let preview: String
    let sender: String?
    let receivedDate: Date?
}
