import AppKit
import SwiftUI
import MailternalInterfaces

/// The main-window reader's single tab row. It owns no message state: opening,
/// activation, persistence, and mutation all stay on AppModel/ReaderTabs.
struct ReaderTabBar: View {
    @Bindable var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTabID: UUID?
    @State private var hoverCandidateID: UUID?
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var readerHasFocus: Bool

    @Namespace private var glassNamespace

    @State private var tabFrames: [UUID: CGRect] = [:]

    var body: some View {
        if model.tabs.active != nil {
            GeometryReader { geometry in
                let contentWidth = max(0, geometry.size.width)
                let viewportWidth = max(
                    0,
                    contentWidth
                        - ReaderTabLayoutPolicy.actionsClusterWidth
                        - ReaderTabLayoutPolicy.tabSpacing
                )
                let tabWidth = ReaderTabLayoutPolicy.tabWidth(
                    availableWidth: viewportWidth,
                    tabCount: model.tabs.tabs.count
                )
                let tabsContentWidth = ReaderTabLayoutPolicy.contentWidth(
                    availableWidth: viewportWidth,
                    tabCount: model.tabs.tabs.count
                )
                ZStack(alignment: .topLeading) {
                    GlassEffectContainer(spacing: ReaderTabLayoutPolicy.tabSpacing) {
                        HStack(spacing: 0) {
                            tabViewport(
                                width: viewportWidth,
                                tabWidth: tabWidth,
                                contentWidth: tabsContentWidth,
                                glassNamespace: glassNamespace
                            )
                            ReaderActionsCluster(model: model)
                        }
                    }
                    .frame(width: geometry.size.width, height: ReaderTabLayoutPolicy.rowHeight)
                }
                .frame(width: geometry.size.width, height: ReaderTabLayoutPolicy.rowHeight)
                // The preview is deliberately an overlay of the complete tab
                // row, rather than a child of the scrolling tab content. This
                // keeps its coordinate origin at the row's top and lets it
                // paint over the reader below the strip.
                .overlay(alignment: .topLeading) {
                    if let preview = hoveredPreview,
                       let frame = tabFrames[preview.id] {
                        ReaderTabHoverCard(
                            subject: preview.subject,
                            preview: preview.preview,
                            sender: preview.sender,
                            receivedDate: preview.receivedDate
                        )
                        .offset(
                            x: cardX(for: frame, in: geometry.size.width),
                            y: ReaderTabLayoutPolicy.rowHeight + 4
                        )
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                        .zIndex(10)
                        .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "reader-tab-bar")
                .onPreferenceChange(ReaderTabFramePreferenceKey.self) { frames in
                    tabFrames = frames
                }
                .animation(reduceMotion ? MailMotion.disclosure : MailMotion.hover, value: hoveredTabID)
            }
            .padding(.horizontal, MessageViewerLayoutPolicy.horizontalPadding)


            .frame(height: ReaderTabLayoutPolicy.rowHeight)
            .zIndex(hoveredPreview == nil ? 0 : 1)
            .accessibilityIdentifier(UIIdentifier.readerTabBar)
            .focusable()
            .focusEffectDisabled(true)
            .focused($readerHasFocus)
            .onChange(of: model.tabs.activeID) { _, activeID in
                readerHasFocus = activeID != nil
            }
            .onDisappear {
                hoverTask?.cancel()
                hoverTask = nil
                hoverCandidateID = nil
                hoveredTabID = nil
            }
        }
    }

    private func tabViewport(
        width: CGFloat,
        tabWidth: CGFloat,
        contentWidth: CGFloat,
        glassNamespace: Namespace.ID
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ReaderTabLayoutPolicy.tabSpacing) {
                    ForEach(model.tabs.tabs) { tab in
                        ReaderTabItem(
                            model: model,
                            tab: tab,
                            subject: subject(for: tab),
                            width: tabWidth,
                            glassNamespace: glassNamespace,
                            onHoverChanged: { hovering in
                                updateHover(for: tab.id, hovering: hovering)
                            },
                            onClose: closeTab
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
                                afterTarget: location.x > tabWidth / 2,
                                count: model.tabs.tabs.count
                            )
                            model.tabs.move(sourceID, to: destination)
                            return true
                        }
                    }
                }
                .padding(.leading, 0)
                .padding(.trailing, ReaderTabLayoutPolicy.rightFadeWidth)
                .frame(minWidth: contentWidth, alignment: .leading)
            }
            .focusEffectDisabled(true)
            .frame(width: width, height: ReaderTabLayoutPolicy.rowHeight)
            .overlay(alignment: .trailing) {
                if ReaderTabLayoutPolicy.showsFade(
                    contentWidth: contentWidth,
                    viewportWidth: width
                ) {
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(nsColor: .windowBackgroundColor)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: ReaderTabLayoutPolicy.rightFadeWidth)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: model.tabs.activeID) { _, activeID in
                guard let activeID else { return }
                withAnimation(reduceMotion ? MailMotion.disclosure : MailMotion.hover) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }
            .task(id: model.tabs.activeID) {
                guard let activeID = model.tabs.activeID else { return }
                await Task.yield()
                withAnimation(reduceMotion ? MailMotion.disclosure : MailMotion.hover) {
                    proxy.scrollTo(activeID, anchor: .center)
                }
            }

        }
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
        guard hovering else {
            guard hoverCandidateID == id || hoveredTabID == id else { return }
            if hoverCandidateID == id {
                hoverCandidateID = nil
            }
            hoverTask?.cancel()
            hoverTask = nil
            withAnimation(reduceMotion ? MailMotion.disclosure : MailMotion.hover) {
                if hoveredTabID == id { hoveredTabID = nil }
            }
            return
        }

        // onContinuousHover emits active phases repeatedly. Keep the
        // candidate stable so those phases do not restart the dwell timer.
        guard hoveredTabID != id, hoverCandidateID != id else { return }
        hoverTask?.cancel()
        hoverCandidateID = id
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: ReaderTabTokens.hoverDelay)
            guard !Task.isCancelled, hoverCandidateID == id else { return }
            withAnimation(reduceMotion ? MailMotion.disclosure : MailMotion.hover) {
                hoveredTabID = id
            }
        }
    }

    private func closeTab(_ id: UUID) {
        let wasActive = model.tabs.activeID == id
        if wasActive {
            model.closeActiveTabOrWindow()
            readerHasFocus = model.tabs.activeID != nil
        } else {
            model.tabs.close(id)
        }
    }


    private func cardX(for frame: CGRect, in width: CGFloat) -> CGFloat {
        let cardWidth = ReaderTabTokens.previewWidth
        return min(
            max(frame.midX - cardWidth / 2, 8),
            max(8, width - cardWidth - 8)
        )
    }

    private static func plainText(fromHTML html: String) -> String {
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
