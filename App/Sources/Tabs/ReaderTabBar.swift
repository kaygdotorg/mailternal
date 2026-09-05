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
    init(model: AppModel) {
        self.model = model
    }

    @State private var hoveredTabID: UUID?
    @State private var hoverDismissTask: Task<Void, Never>?
    @State private var hoverPopover: ReaderTabHoverPopover?
    @State private var isCardHovered = false
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var tabBarView: NSView?
    @FocusState private var focusedTabID: UUID?
    @State private var pendingReaderFocusIdentifier: String?

    var body: some View {
        let _ = os_signpost(
            .event,
            log: readerTabBarSignpostLog,
            name: "ReaderTabBar.body"
        )
        if !model.tabs.tabs.isEmpty && !model.isSearchPresented {
            GeometryReader { geometry in
                let widths = model.tabs.tabs.map { tabWidth(for: $0) }
                let contentWidth = ReaderTabLayoutPolicy.contentWidth(tabWidths: widths)
                tabViewport(
                    width: max(0, geometry.size.width),
                    widths: widths,
                    contentWidth: contentWidth
                )
                .frame(width: geometry.size.width, height: ReaderTabLayoutPolicy.rowHeight)
                .coordinateSpace(name: "reader-tab-bar")
                .onPreferenceChange(ReaderTabFramePreferenceKey.self) { frames in
                    tabFrames = frames
                    if let hoveredTabID {
                        showHoverPanel(for: hoveredTabID)
                    }
                }
                .background(
                    ReaderTabWindowProbe { view in
                        tabBarView = view
                    }
                )
            }
            .padding(.leading, ReaderTabLayoutPolicy.leadingInset)
            .frame(height: ReaderTabLayoutPolicy.rowHeight)
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
            .onChange(of: focusSnapshot) { oldSnapshot, newSnapshot in
                guard let oldActiveID = oldSnapshot.activeID,
                      oldSnapshot.tabIDs.contains(oldActiveID),
                      !newSnapshot.tabIDs.contains(oldActiveID),
                      newSnapshot.activeID != nil else {
                    return
                }
                let targetIdentifier = pendingReaderFocusIdentifier ?? focusedReaderTargetIdentifier()
                pendingReaderFocusIdentifier = nil
                restoreReaderFocus(to: targetIdentifier)
            }
            .onDisappear {
                dismissHoverCard()
                if model.tabs.tabs.isEmpty && !model.isSearchPresented {
                    restoreMessageListFocus()
                }
            }
        }
    }

    private func tabViewport(
        width: CGFloat,
        widths: [CGFloat],
        contentWidth: CGFloat
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ReaderTabLayoutPolicy.tabSpacing) {
                    ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                        let width = index < widths.count
                            ? widths[index]
: ReaderTabLayoutPolicy.minimumTabWidth
                        ReaderTabItem(
                            model: model,
                            tab: tab,
                            subject: subject(for: tab),
                            sender: sender(for: tab),
                            width: width,
                            onHoverChanged: { hovering in
                                updateHover(for: tab.id, hovering: hovering)
                            },
                            onClose: closeTab,
                            focusedTabID: $focusedTabID
                        )
                        .id(tab.id)
                        .background {
                            GeometryReader { itemGeometry in
                                Color.clear.preference(
                                    key: ReaderTabFramePreferenceKey.self,
                                    value: [
                                        tab.id: itemGeometry.frame(in: .named("reader-tab-bar"))
                                    ]
                                )
                            }
                        }
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
                .padding(.trailing, ReaderTabLayoutPolicy.rightFadeWidth)
                .frame(minWidth: max(width, contentWidth), alignment: .leading)
            }
            .focusEffectDisabled(true)
            .frame(width: width, height: ReaderTabLayoutPolicy.rowHeight)
            .mask {
                if ReaderTabLayoutPolicy.showsFade(
                    contentWidth: contentWidth,
                    viewportWidth: width
                ) {
                    GeometryReader { maskGeometry in
                        let fadeStart = max(
                            0,
                            min(
                                1,
                                1 - ReaderTabLayoutPolicy.rightFadeWidth / max(maskGeometry.size.width, 1)
                            )
                        )
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: fadeStart),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                } else {
                    Color.white
                }
            }
            .onChange(of: model.tabs.activeID) { _, activeID in
                guard let activeID else { return }
                proxy.scrollTo(activeID, anchor: .center)
            }
        }
    }

    private func tabWidth(for tab: ReaderTab) -> CGFloat {
        let title = subject(for: tab).isEmpty ? "No Subject" : subject(for: tab)
        let titleWidth: CGFloat
        if ReaderTabStylePolicy.showsSubject(for: model.appearance.tabStyle) {
            let font = NSFont.preferredFont(forTextStyle: .subheadline)
            titleWidth = ceil(
                (title as NSString).size(withAttributes: [.font: font]).width
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
        return preview(for: tab)
    }

    private func subject(for tab: ReaderTab) -> String {
        if let row = model.listRows.first(where: { $0.id == tab.message }) {
            return row.subject
        }
        if model.detail?.id == tab.message {
            return model.detail?.envelope.subject ?? ""
        }
        return ""
    }

    private func sender(for tab: ReaderTab) -> String? {
        if let row = model.listRows.first(where: { $0.id == tab.message }) {
            return row.from
        }
        if let detail = model.detail, detail.id == tab.message {
            return detail.envelope.from.first.map {
                ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.address
            }
        }
        return nil
    }

    private func preview(for tab: ReaderTab) -> ReaderTabPreview {
        if let row = model.listRows.first(where: { $0.id == tab.message }) {
            return ReaderTabPreview(
                id: tab.id,
                subject: row.subject.isEmpty ? "No Subject" : row.subject,
                preview: row.preview,
                sender: row.from,
                receivedDate: row.date
            )
        }
        if let detail = model.detail, detail.id == tab.message {
            let body = detail.bodyText
                ?? detail.sanitizedHTML.map(Self.plainText(fromHTML:))
                ?? ""
            let sender = detail.envelope.from.first.map {
                ($0.displayName?.isEmpty == false ? $0.displayName : nil) ?? $0.address
            }
            return ReaderTabPreview(
                id: tab.id,
                subject: detail.envelope.subject.isEmpty ? "No Subject" : detail.envelope.subject,
                preview: body,
                sender: sender,
                receivedDate: detail.envelope.headerDate ?? detail.envelope.internalDate
            )
        }
        return ReaderTabPreview(
            id: tab.id,
            subject: subject(for: tab).isEmpty ? "No Subject" : subject(for: tab),
            preview: "",
            sender: nil,
            receivedDate: nil
        )
    }

    private func updateHover(for id: UUID, hovering: Bool) {
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
            showHoverPanel(for: id)
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

    private func showHoverPanel(for id: UUID) {
        guard canPresentHoverPreview(for: id),
              let preview = hoveredPreview,
              let frame = tabFrames[id],
              let anchor = tabBarView else {
            if hoveredTabID == id {
                dismissHoverCard()
            }
            return
        }
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

    private var focusSnapshot: ReaderTabFocusSnapshot {
        ReaderTabFocusSnapshot(
            tabIDs: model.tabs.tabs.map(\.id),
            activeID: model.tabs.activeID
        )
    }

    private func focusedReaderTargetIdentifier() -> String? {
        guard let window = tabBarView?.window ?? NSApp.keyWindow,
              let contentView = window.contentView,
              let viewer = Self.findView(
                  withAccessibilityIdentifier: UIIdentifier.messageViewer,
                  in: contentView
              ),
              let responder = window.firstResponder as? NSView,
              responder === viewer || responder.isDescendant(of: viewer) else {
            return nil
        }

        var target: NSView? = responder
        while let view = target {
            let identifier = view.accessibilityIdentifier()
            if !identifier.isEmpty {
                return identifier
            }
            target = view.superview
        }
        return nil
    }

    private func restoreReaderFocus(to identifier: String?) {
        Task { @MainActor in
            // Wait for the replacement reader's hierarchy to be installed
            // before resolving its accessibility target.
            await Task.yield()
            guard let window = tabBarView?.window ?? NSApp.keyWindow,
                  let contentView = window.contentView else {
                return
            }
            let target = identifier.flatMap {
                Self.findView(
                    withAccessibilityIdentifier: $0,
                    in: contentView
                )
            } ?? Self.findView(
                withAccessibilityIdentifier: UIIdentifier.messageViewer,
                in: contentView
            )
            guard let target, target.window === window else { return }
            window.makeFirstResponder(target)
        }
    }


    private func restoreMessageListFocus() {
        guard let window = tabBarView?.window ?? NSApp.keyWindow,
              let contentView = window.contentView else {
            return
        }
        DispatchQueue.main.async { [weak window, weak contentView] in
            guard let window,
                  let contentView,
                  let table = Self.findView(
                    withAccessibilityIdentifier: UIIdentifier.messageTable,
                    in: contentView
                  ),
                  table.window === window else {
                return
            }
            window.makeFirstResponder(table)
        }
    }

    private static func findView(
        withAccessibilityIdentifier identifier: String,
        in view: NSView
    ) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews.reversed() {
            if let match = findView(
                withAccessibilityIdentifier: identifier,
                in: subview
            ) {
                return match
            }
        }
        return nil
    }

    private func closeTab(_ id: UUID) {
        if model.tabs.activeID == id {
            pendingReaderFocusIdentifier = focusedReaderTargetIdentifier()
            model.closeActiveTabOrWindow()
        } else {
            model.tabs.close(id)
        }
    }

    private static func plainText(fromHTML html: String) -> String {

        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
private struct ReaderTabFocusSnapshot: Equatable {
    let tabIDs: [UUID]
    let activeID: UUID?
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

private struct ReaderTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
