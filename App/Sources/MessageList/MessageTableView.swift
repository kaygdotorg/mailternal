import AppKit
import SwiftUI
import MailternalInterfaces

struct MessageListPane: View {
    @Bindable var model: AppModel
    @Environment(ActionSettings.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleShowsAccount = false
    @State private var titleBottom: CGFloat = 0

    private var listDissolvePolicy: MailWindowDissolvePolicy {
        // The header keeps its title-only bottom edge. Status appears inside
        // that footprint by lifting the H1, not by moving the rows or fade.
        // The first row rests at the ramp's end in both states.
        .messageList.withTopOrigin(max(titleBottom, MailWindowTopDissolvePolicy.titlebarDepth))
    }

    private var listTitle: String {
        titleShowsAccount
            ? model.listTitleAccountName
            : (model.selectedFolder?.name ?? "Messages")
    }

    /// Multiple selection is the one status that belongs to the user's
    /// immediate action, so it takes precedence over background work. The
    /// folder activity remains sourced from the live sync stream.
    private var listSubtitle: String? {
        if model.selectedMessageIDs.count > 1 {
            return FolderActivityPolicy.selectionSubtitle(
                for: model.selectedMessageIDs.count
            )
        }
        guard let folder = model.selectedFolder else { return nil }
        return FolderActivityPolicy.subtitle(for: folder)
    }

    private var titleAnimation: Animation? {
        reduceMotion ? nil : MailMotion.disclosure
    }
    /// The status line shares one stable Text identity so numericText remains
    /// eligible for changing numeric portions, while the same content update
    /// animation gives state/word replacements a consistent native fallback.
    /// A nil status renders as an empty Text slot; FolderHeaderLayout still
    /// reports the title-only footprint and uses the measured line height only
    /// to lift the title into that existing footprint.
    private var headerStatusAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24)
    }


    var body: some View {
        ZStack(alignment: .top) {
            MessageTableRepresentable(
                rows: model.listRows,
                selectedID: model.selectedMessageID,
                selectedIDs: model.selectedMessageIDs,
                messageLinks: model.messageDeepLinks,
                folders: model.folders,
                accounts: model.accountConfigs,
                currentFolder: model.selectedFolderID,
                configuration: model.effectiveListConfiguration,
                epoch: model.listEpoch,
                lineCount: model.appearance.messageListLines,
                showsSenderIcons: model.appearance.showsSenderIcons,
                faviconRevision: model.faviconRevision,
                faviconForDomain: { model.favicon(forSenderDomain: $0) },
                accent: model.appearance.accent,
                leading: actions.leadingSwipe,
                trailing: actions.trailingSwipe,
                topRestDepth: listDissolvePolicy.restDepth(safeAreaTop: 0),
                listScrollOffset: model.selectedFolderID.flatMap {
                    model.listScrollOffsets[$0]
                },
                hasMorePages: model.listCursor != nil,
                isPaging: model.isPaging,
                isLoadingList: model.isLoadingList,
                onWarmup: { domains in
                    Task { await model.warmupFavicons(forSenderDomains: domains) }
                },
                onSelect: { ids, anchor in
                    model.noteListInteraction()
                    model.selectMessages(ids, anchor: anchor)
                },
                onContextMenu: { model.noteListInteraction() },
                onOpenMessages: { ids, permanent in
                    model.openMessages(ids, permanent: permanent)
                },
                onSelectAll: { model.selectAllMessages() },
                onPrefetch: { model.loadMoreIfNeeded(near: $0) },
                onCopySubject: { ids in model.copySubjects(for: ids) },
                onCopyDeepLink: { ids in
                    Task { await model.copyDeepLinks(for: ids) }
                },
                onAction: { kind, ids in model.perform(kind, on: ids) },
                onMove: { ids, folder in model.move(ids: ids, to: folder) },
                onOpenMessageWindow: { model.openMessageWindow($0) },
                onListScroll: { folder, offset in
                    guard model.selectedFolderID == folder else { return }
                    model.listScrollOffsets[folder] = offset
                },
                onColumnOrder: {
                    model.noteListInteraction()
                    model.setListColumnOrder($0)
                },
                onColumnWidth: { column, width in
                    model.noteListInteraction()
                    model.setListColumnWidth(column, width: width)
                },
                onSort: {
                    model.noteListInteraction()
                    model.setListSort($0)
                }
            )
            .mailWindowDissolve(listDissolvePolicy)
            Button {
                model.noteListInteraction()
                withAnimation(titleAnimation) {
                    titleShowsAccount.toggle()
                }
            } label: {
                // One Text whose string changes, not two Texts swapped by
                // identity: an `.id` swap inside a plain button label left
                // the old title on screen on macOS 26 (the click fired and
                // the state flipped; only the label never re-rendered).
                FolderHeaderLayout(subtitleIsVisible: listSubtitle != nil) {
                    Text(listTitle)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Keep this Text mounted across idle/activity and
                    // single/multiple-selection changes. The stable identity
                    // keeps numericText eligible instead of letting an
                    // insertion/removal transition take precedence.
                    Text(listSubtitle ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .animation(headerStatusAnimation, value: listSubtitle)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            // Status grows upward inside the title-only footprint, preserving
            // the established air before the first row and its scroll position.
            .padding(.bottom, PaneHeaderInsetPolicy.listTitleBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(listSubtitle ?? "")
            .accessibilityIdentifier(UIIdentifier.messageListTitle)
            .onGeometryChange(for: CGFloat.self) { proxy in
                // Measure the stable header footprint from the physical
                // window top, not its locally proposed size.
                proxy.frame(in: .global).maxY - PaneHeaderInsetPolicy.listTitleBottomPadding
            } action: { titleBottom = $0
                #if DEBUG
                if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
                    QALaunch.log("list-title bottom=\($0) rest=\(listDissolvePolicy.restDepth(safeAreaTop: 0))")
                }
                #endif
            }
        }
        .overlay {
            if model.isLoadingList, model.listRows.isEmpty {
                ProgressView()
                    .controlSize(.small)
            } else if model.folders.isEmpty == false, model.listRows.isEmpty, model.selectedFolderID != nil, !model.isPaging {
                EmptyMailboxState(title: "No Messages", detail: "This folder is empty.")
            }
        }
        // No chrome sits above this column, so its rows own the whole height:
        // they travel to the window's physical top edge and dissolve at it.
        // The measured title height moves that origin below the title while
        // keeping the title itself outside the scrolling mask.
        .ignoresSafeArea(.container, edges: .top)
}
}

/// Keeps the list's resting edge fixed while a status line lifts the title.
/// Its reported height is deliberately title-only: status changes must not
/// move the first row, change the dissolve origin, or reset list scrolling.
/// The actual subtitle line is measured during placement, so wrapped titles
/// remain native text and the H1 moves up by that line's height plus 1 pt.
private struct FolderHeaderLayout: Layout {
    let subtitleIsVisible: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let title = subviews.first else { return .zero }
        let titleSize = title.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // The upper air belongs to the stable title-only header footprint,
        // not to the optional status line.
        return CGSize(
            width: titleSize.width,
            height: PaneHeaderInsetPolicy.headerTopPadding + titleSize.height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let title = subviews.first else { return }
        let textProposal = ProposedViewSize(width: bounds.width, height: nil)
        let titleSize = title.sizeThatFits(textProposal)
        let subtitle = subviews.count > 1 ? subviews[1] : nil
        let subtitleHeight = subtitle?.sizeThatFits(textProposal).height ?? 0
        let statusSpace = subtitleIsVisible ? subtitleHeight + 1 : 0

        title.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - titleSize.height - statusSpace),
            anchor: .topLeading,
            proposal: textProposal
        )
        // Place the stable status view even while empty; the layout controls
        // whether the measured line consumes any header space.
        subtitle?.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - subtitleHeight),
            anchor: .topLeading,
            proposal: textProposal
        )
    }
}

extension MailListColumn {
    var title: String {
        switch self {
        case .read: "Read"
        case .flagged: "Flagged"
        case .attachments: "Attachments"
        case .sender: "Sender"
        case .subject: "Subject"
        case .date: "Date"
        }
    }

    var sortField: MailListSort.Field {
        switch self {
        case .read: .read
        case .flagged: .flagged
        case .attachments: .attachments
        case .sender: .sender
        case .subject: .subject
        case .date: .date
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .read, .flagged, .attachments: 36
        case .sender: 180
        case .subject: 320
        case .date: 132
        }
    }
}

struct MessageTableRepresentable: NSViewRepresentable {
    var rows: [MessageRow]
    var selectedID: MessageID?
    var selectedIDs: Set<MessageID>
    var messageLinks: [MessageID: String]
    var folders: [FolderSummary]
    var accounts: [AccountConfig]
    var currentFolder: FolderID?
    var configuration: MailListConfiguration
    var epoch: UInt64
    var lineCount: Int
    var showsSenderIcons: Bool
    var faviconRevision: UInt64
    var faviconForDomain: (String) -> NSImage?
    var accent: AccentSource
    var leading: [SwipeActionKind]
    var trailing: [SwipeActionKind]
    var topRestDepth: CGFloat
    var listScrollOffset: CGFloat?
    var hasMorePages: Bool
    var isPaging: Bool
    var isLoadingList: Bool
    var onWarmup: ([String]) -> Void
    var onSelect: (Set<MessageID>, MessageID?) -> Void
    var onContextMenu: () -> Void
    var onOpenMessages: ([MessageID], Bool) -> Void
    var onSelectAll: () -> Void
    var onPrefetch: (Int) -> Void
    var onCopySubject: (Set<MessageID>) -> Void
    var onCopyDeepLink: (Set<MessageID>) -> Void
    var onAction: (SwipeActionKind, Set<MessageID>) -> Void
    var onMove: (Set<MessageID>, FolderID) -> Void
    var onOpenMessageWindow: (MessageID) -> Void
    var onListScroll: (FolderID, CGFloat) -> Void
    var onColumnOrder: ([MailListColumn]) -> Void
    var onColumnWidth: (MailListColumn, Double) -> Void
    var onSort: (MailListSort) -> Void


    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MessageTableContainer {
        let container = MessageTableContainer(topRestDepth: topRestDepth)
        context.coordinator.bind(container: container, parent: self)
        return container
    }

    func updateNSView(_ nsView: MessageTableContainer, context: Context) {
        context.coordinator.update(container: nsView, parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: MessageTableRepresentable?
        private var lineCount = MessageListLayout.defaultLineCount
        private var showsSenderIcons = false
        private var faviconRevision: UInt64 = 0
        private var warmedDomains = Set<String>()
        weak var container: MessageTableContainer?
        fileprivate weak var tableView: MessageTableKeyView?
        private var epoch: UInt64 = 0
        private var rowIDs: [MessageID] = []
        private var renderedFolder: FolderID?
        private var pendingScrollOffset: CGFloat?
        private var restorePrefetchRowCount: Int?
        private var canPersistScroll = false
        private var configuration = MailListConfiguration.default
        private var applyingColumns = false

        private var rowLineCount: Int {
            configuration.presentation == .columns ? 1 : lineCount
        }

        func bind(container: MessageTableContainer, parent: MessageTableRepresentable) {
            self.parent = parent
            self.container = container
            tableView = container.tableView
            configuration = parent.configuration
            lineCount = MessageListLayout.normalizedLineCount(parent.lineCount)
            showsSenderIcons = parent.showsSenderIcons
            faviconRevision = parent.faviconRevision
            applyingColumns = true
            container.apply(configuration: configuration)
            applyingColumns = false
            container.tableView.rowHeight = MessageListLayout.rowHeight(for: rowLineCount)
            container.updateAccent(parent.accent)
            container.tableView.delegate = self
            container.tableView.dataSource = self
            container.onVisibleRow = { [weak self] row in
                guard let self else { return }
                self.parent?.onPrefetch(row)
                if let table = self.tableView, let parent = self.parent {
                    self.warmVisibleFavicons(in: table, parent: parent)
                }
            }
            container.onScrollOffset = { [weak self] offset in
                guard let self, self.canPersistScroll,
                      let parent = self.parent,
                      let folder = parent.currentFolder
                else { return }
                parent.onListScroll(folder, offset)
            }
            container.onKeyCommand = { [weak self] command in
                self?.handleKeyCommand(command)
            }
            container.onSelectAll = { [weak self] in
                self?.parent?.onSelectAll()
            }
            container.tableView.onListInteraction = { [weak self] in
                self?.parent?.onContextMenu()
            }
            container.tableView.menu = makeMenu()
            container.tableView.target = self
            container.tableView.doubleAction = #selector(handleDoubleAction(_:))
        }

        @objc private func handleDoubleAction(_ sender: NSTableView) {
            // NSTableView can route keyboard activation through its
            // doubleAction target. Only a real double-click may promote a
            // transient reader tab to permanent.
            guard NSApp.currentEvent?.clickCount ?? 0 >= 2 else { return }
            guard let parent else { return }
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard let messageID = parent.rows[safe: row]?.id else { return }
            parent.onOpenMessages([messageID], true)
        }

        func update(container: MessageTableContainer, parent: MessageTableRepresentable) {
            self.parent = parent
            canPersistScroll = false
            let configurationChanged = configuration != parent.configuration
            let columnsChanged = configuration.presentation != parent.configuration.presentation
                || configuration.columnOrder != parent.configuration.columnOrder
                || configuration.hiddenColumns != parent.configuration.hiddenColumns
                || configuration.columnWidths != parent.configuration.columnWidths
                || configuration.sort != parent.configuration.sort
            configuration = parent.configuration
            if columnsChanged {
                applyingColumns = true
                container.apply(configuration: configuration)
                applyingColumns = false
            }
            container.updateTopRestDepth(parent.topRestDepth)
            let table = container.tableView
            let folderChanged = renderedFolder != parent.currentFolder
            let epochChanged = parent.epoch != epoch
            if folderChanged || epochChanged {
                pendingScrollOffset = parent.listScrollOffset.map { max($0, 0) }
                restorePrefetchRowCount = nil
            }
            renderedFolder = parent.currentFolder
            // SwiftUI observes AccentSource and the favicon revision; resolve
            // both at this AppKit bridge so reused rows update in place.
            let accentChanged = container.updateAccent(parent.accent)
            let showsSenderIconsChanged = parent.showsSenderIcons != showsSenderIcons
            showsSenderIcons = parent.showsSenderIcons
            let faviconChanged = parent.faviconRevision != faviconRevision
            faviconRevision = parent.faviconRevision
            let oldCount = rowIDs.count
            let newIDs = parent.rows.map(\.id)
            let newLineCount = MessageListLayout.normalizedLineCount(parent.lineCount)
            let lineCountChanged = newLineCount != lineCount
            lineCount = newLineCount

            if epochChanged || configurationChanged {
                epoch = parent.epoch
                rowIDs = newIDs
                table.reloadData()
            } else if newIDs.count > oldCount, newIDs.starts(with: rowIDs) {
                rowIDs = newIDs
                let added = IndexSet(integersIn: oldCount..<newIDs.count)
                table.insertRows(at: added, withAnimation: [])
            } else if newIDs != rowIDs {
                rowIDs = newIDs
                table.reloadData()
            } else if accentChanged || showsSenderIconsChanged {
                reloadVisibleRows(in: table)
            }

            if faviconChanged {
                reloadRowsWithFavicons(in: table, parent: parent)
            }

            if lineCountChanged || configurationChanged {
                let origin = table.enclosingScrollView?.contentView.bounds.origin
                // `rowHeight` is the table's fallback geometry and is also
                // used while the delegate is rebuilding reused cells. Keep it
                // in lockstep with the delegate's answer so a live line-count
                // change cannot leave a row at the previous setting's height.
                table.rowHeight = MessageListLayout.rowHeight(for: rowLineCount)
                if table.numberOfRows > 0 {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
                }
                reloadVisibleRows(in: table)
                if let origin, let scrollView = table.enclosingScrollView {
                    scrollView.contentView.setBoundsOrigin(origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            warmVisibleFavicons(in: table, parent: parent)
            restorePendingScrollOffset(in: container)
            syncSelection(in: table)
            canPersistScroll = pendingScrollOffset == nil
        }

        private func restorePendingScrollOffset(in container: MessageTableContainer) {
            guard let offset = pendingScrollOffset else { return }
            guard container.restoreScrollOffset(offset) else {
                // A deep target can be outside the first page's document
                // geometry. Keep persistence disabled while a page is
                // in-flight or can still be started; the next row update
                // retries restoration after that page arrives.
                guard let parent else {
                    container.clampScrollOffset(offset)
                    pendingScrollOffset = nil
                    return
                }
                if let requestedAtCount = restorePrefetchRowCount {
                    guard !parent.isPaging else { return }
                    restorePrefetchRowCount = nil
                    guard parent.rows.count > requestedAtCount else {
                        // The restore-driven request settled without extending
                        // the document (failure or an empty final page). Do not
                        // retry the same cursor forever.
                        container.clampScrollOffset(offset)
                        pendingScrollOffset = nil
                        return
                    }
                }
                guard !parent.rows.isEmpty else {
                    // The initial page may still be loading even though no
                    // cursor exists yet. Keep the target until that request
                    // settles; an actually empty exhausted list is clamped.
                    if !parent.isLoadingList {
                        container.clampScrollOffset(offset)
                        pendingScrollOffset = nil
                    }
                    return
                }
                guard !parent.isPaging, !parent.isLoadingList else {
                    // The request is already in flight (including the
                    // initial page), so wait for its state update before
                    // deciding whether another page is needed.
                    return
                }
                guard parent.hasMorePages else {
                    // Pagination is exhausted, so this target is genuinely
                    // unreachable. Persist the nearest reachable position
                    // instead of leaving scroll persistence disabled forever.
                    container.clampScrollOffset(offset)
                    pendingScrollOffset = nil
                    return
                }
                restorePrefetchRowCount = parent.rows.count
                parent.onPrefetch(parent.rows.count - 1)
                return
            }
            pendingScrollOffset = nil
        }

        private func reloadVisibleRows(in table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
            )
        }
        private func reloadRowsWithFavicons(
            in table: NSTableView,
            parent: MessageTableRepresentable
        ) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            let indexes = IndexSet(
                (visible.location..<(visible.location + visible.length)).filter { row in
                    guard let message = parent.rows[safe: row],
                          let domain = SenderDomainPolicy.domain(from: message.senderAddress)
                    else { return false }
                    return parent.faviconForDomain(domain) != nil
                }
            )
            guard !indexes.isEmpty else { return }
            table.reloadData(
                forRowIndexes: indexes,
                columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
            )
        }

        private func warmVisibleFavicons(in table: NSTableView, parent: MessageTableRepresentable) {
            guard parent.showsSenderIcons else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            var domains = Set<String>()
            for row in visible.location..<(visible.location + visible.length) {
                guard let message = parent.rows[safe: row],
                      let domain = SenderDomainPolicy.domain(from: message.senderAddress),
                      parent.faviconForDomain(domain) == nil,
                      !warmedDomains.contains(domain)
                else { continue }
                domains.insert(domain)
            }
            guard !domains.isEmpty else { return }
            warmedDomains.formUnion(domains)
            parent.onWarmup(domains.sorted())
        }

        private func apply(_ rowModel: MessageRow, to cell: MessageCellView, parent: MessageTableRepresentable) {
            let domain = SenderDomainPolicy.domain(from: rowModel.senderAddress)
            cell.apply(
                rowModel,
                lineCount: lineCount,
                showsSenderIcons: parent.showsSenderIcons,
                favicon: domain.flatMap { parent.faviconForDomain($0) }
            )
        }

        private func apply(
            _ rowModel: MessageRow,
            to cell: MessageColumnCellView,
            column: MailListColumn,
            parent: MessageTableRepresentable
        ) {
            let domain = SenderDomainPolicy.domain(from: rowModel.senderAddress)
            cell.apply(
                rowModel,
                column: column,
                showsSenderIcon: parent.showsSenderIcons,
                favicon: domain.flatMap { parent.faviconForDomain($0) }
            )
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let tableColumn,
               tableColumn === tableView.tableColumns.first(where: { !$0.isHidden }) {
                parent?.onPrefetch(row)
            }
            guard let parent, let rowModel = parent.rows[safe: row] else { return nil }
            if configuration.presentation == .columns,
               let tableColumn,
               let column = MailListColumn(rawValue: tableColumn.identifier.rawValue) {
                let cell = tableView.makeView(
                    withIdentifier: MessageColumnCellView.identifier(for: column),
                    owner: self
                ) as? MessageColumnCellView
                    ?? MessageColumnCellView(identifier: MessageColumnCellView.identifier(for: column))
                cell.updateAccentColor(container?.accentColor)
                apply(rowModel, to: cell, column: column, parent: parent)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: MessageCellView.identifier, owner: self) as? MessageCellView
                ?? MessageCellView()
            cell.updateAccentColor(container?.accentColor)
            apply(rowModel, to: cell, parent: parent)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: MessageRowChrome.identifier, owner: self) as? MessageRowChrome
                ?? MessageRowChrome()
            rowView.updateAccentColor(container?.accentColor)
            return rowView
        }

        func tableView(
            _ tableView: NSTableView,
            rowActionsForRow row: Int,
            edge: NSTableView.RowActionEdge
        ) -> [NSTableViewRowAction] {
            guard let rowModel = parent?.rows[safe: row] else { return [] }
            let kinds: [SwipeActionKind]
            switch edge {
            case .leading:
                kinds = parent?.leading ?? []
            case .trailing:
                kinds = parent?.trailing ?? []
            @unknown default:
                return []
            }

            return kinds.map { kind in
                let title = kind.title(isRead: rowModel.isRead, isFlagged: rowModel.isFlagged)
                let action = NSTableViewRowAction(style: kind.style, title: title) { [weak self] _, _ in
                    self?.parent?.onAction(kind, [rowModel.id])
                }
                action.backgroundColor = kind.backgroundColor
                action.image = NSImage(
                    systemSymbolName: kind.systemImage(isRead: rowModel.isRead, isFlagged: rowModel.isFlagged),
                    accessibilityDescription: title
                )
                return action
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            MessageListLayout.rowHeight(for: rowLineCount)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard configuration.presentation == .columns,
                  let column = MailListColumn(rawValue: tableColumn.identifier.rawValue),
                  let parent
            else { return }
            let field = column.sortField
            let direction: MailListSort.Direction
            if configuration.sort.field == field {
                direction = configuration.sort.direction == .ascending ? .descending : .ascending
            } else {
                direction = field == .date ? .descending : .ascending
            }
            parent.onSort(MailListSort(field: field, direction: direction))
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard !applyingColumns,
                  configuration.presentation == .columns,
                  let tableView,
                  let parent
            else { return }
            let order = tableView.tableColumns.compactMap {
                MailListColumn(rawValue: $0.identifier.rawValue)
            }
            guard order.count == MailListColumn.allCases.count else { return }
            parent.onColumnOrder(order)
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !applyingColumns,
                  configuration.presentation == .columns,
                  let parent
            else { return }
            let column = notification.userInfo?.values
                .compactMap { $0 as? NSTableColumn }
                .first
            guard let column,
                  let field = MailListColumn(rawValue: column.identifier.rawValue),
                  column.width.isFinite,
                  column.width > 0
            else { return }
            parent.onColumnWidth(field, Double(column.width))
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, let parent else { return }
            // A contextual click may cause NSTableView to move its native
            // highlight before asking for the menu. Keep that transient
            // AppKit selection out of the model: menu invocations carry their
            // own immutable clicked-row selection below.
            guard !tableView.receivedContextMenuEvent else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { index in
                parent.rows[safe: index]?.id
            })
            let selectionEvent = tableView.consumeSelectionEvent()
            var modifiers: NSEvent.ModifierFlags = []
            if let selectionEvent {
                if selectionEvent.command { modifiers.insert(.command) }
                if selectionEvent.shift { modifiers.insert(.shift) }
            }
            let isUserSelectionEvent = MessageTableSelectionPolicy.classification(for: selectionEvent) == .user
            let isMouseSelectionEvent = MessageTableSelectionPolicy.isMouseSelection(selectionEvent)
            let clickedID = isMouseSelectionEvent
                ? parent.rows[safe: tableView.clickedRow]?.id
                : nil
            let opensReader = isUserSelectionEvent
                && MessageTableSelectionPolicy.opensReader(for: selectionEvent)
                && modifiers.isDisjoint(with: [.command, .shift])
            if isMouseSelectionEvent, modifiers.contains(.command), let clickedID {
                var selection = parent.selectedIDs
                if ids.contains(clickedID) {
                    selection.insert(clickedID)
                } else {
                    selection.remove(clickedID)
                }
                let anchor = selection.contains(clickedID) ? clickedID : selection.first
                guard selection != parent.selectedIDs || anchor != parent.selectedID else { return }
                parent.onSelect(selection, anchor)
                return
            }
            let anchor = clickedID.flatMap { ids.contains($0) ? $0 : nil }
                ?? parent.rows[safe: tableView.selectedRow]?.id
            guard ids != parent.selectedIDs || anchor != parent.selectedID else { return }
            if opensReader, ids.count == 1, let id = ids.first {
                // Commit the AppKit selection before opening the reader. Reader
                // publication can rebuild surrounding SwiftUI hosts; keeping
                // model/native selection synchronized lets the deferred
                // responder restoration preserve arrow-key navigation.
                parent.onSelect(ids, anchor)
                parent.onOpenMessages([id], false)
                restoreListFocus(after: tableView)
            } else {
                parent.onSelect(ids, anchor)
            }
        }

        private var lastScrolledSelectionID: MessageID?
        private var selectionScrollGeneration: UInt64 = 0
        private var focusRestoreGeneration: UInt64 = 0

        private func restoreListFocus(after tableView: NSTableView) {
            focusRestoreGeneration &+= 1
            let generation = focusRestoreGeneration
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self,
                      generation == self.focusRestoreGeneration,
                      let tableView,
                      let window = tableView.window
                else { return }
                if window.firstResponder !== tableView {
                    window.makeFirstResponder(tableView)
                }
            }
        }

        private func syncSelection(in tableView: NSTableView) {
            guard let parent else { return }
            let selectedIndexes = IndexSet(
                parent.rows.indices.filter { parent.selectedIDs.contains(parent.rows[$0].id) }
            )
            if tableView.selectedRowIndexes != selectedIndexes {
                tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
            }

            guard let selectedID = parent.selectedID,
                  parent.rows.contains(where: { $0.id == selectedID })
            else {
                lastScrolledSelectionID = nil
                selectionScrollGeneration &+= 1
                return
            }
            // A new selection (click, deep link, restoration) is brought into
            // view exactly once; index shifts from backfill prepends and
            // reloads must not yank an established scroll position. Defer the
            // row scroll one run-loop turn so reader content can commit first.
            if lastScrolledSelectionID != selectedID {
                lastScrolledSelectionID = selectedID
                selectionScrollGeneration &+= 1
                let generation = selectionScrollGeneration
                DispatchQueue.main.async { [weak self, weak tableView] in
                    guard let self,
                          generation == self.selectionScrollGeneration,
                          self.parent?.selectedID == selectedID,
                          let tableView,
                          let index = self.parent?.rows.firstIndex(where: { $0.id == selectedID })
                    else { return }
                    tableView.scrollRowToVisible(index)
                }
            }
        }

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard let parent, let rowID = parent.rows[safe: row]?.id else { return nil }
            let ids: Set<MessageID> = parent.selectedIDs.contains(rowID) ? parent.selectedIDs : [rowID]
            let orderedIDs = ids.sorted(by: { $0.rawValue < $1.rawValue })
            let payload = orderedIDs.map { id in
                parent.messageLinks[id] ?? MessageLinkPasteboard.encodeMessageID(id)
            }
            let item = NSPasteboardItem()
            item.setData(
                MessageLinkPasteboard.encode(payload),
                forType: NSPasteboard.PasteboardType(MessageLinkPasteboard.type)
            )
            return item
        }

        /// AppKit can close the menu before dispatching its item action.
        /// Each item owns the selection it describes, independent of tracking.
        private struct MenuInvocation {
            let action: MessageContextMenuPolicy.Action
            let selection: Set<MessageID>
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuDidClose(_ menu: NSMenu) {
            tableView?.resetContextMenuTracking()
        }

        private var clickedMessageID: MessageID? {
            guard let tableView else { return nil }
            let row: Int
            if let contextMenuRow = tableView.contextMenuRow {
                row = contextMenuRow
            } else if tableView.receivedContextMenuEvent {
                // A mouse menu opened outside a row has no target. Do not
                // fall through to a stale clicked or selected row.
                return nil
            } else {
                // Keyboard-invoked menus do not call menu(for:), so target
                // the current table selection.
                row = tableView.selectedRow
            }
            guard row >= 0, let message = parent?.rows[safe: row] else { return nil }
            return message.id
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let parent, let clickedMessageID else { return }
            // Opening a menu is list interaction, but its clicked-row payload
            // must not become the reader selection.
            parent.onContextMenu()
            let selection = MessageContextMenuPolicy.selectionForContextMenu(
                clicked: clickedMessageID,
                selected: parent.selectedIDs
            )
            let readStates = Dictionary(
                uniqueKeysWithValues: selection.compactMap { id in
                    parent.rows.first { $0.id == id }.map { (id, $0.isRead) }
                }
            )
            let flagStates = Dictionary(
                uniqueKeysWithValues: selection.compactMap { id in
                    parent.rows.first { $0.id == id }.map { (id, $0.isFlagged) }
                }
            )
            let policyItems = MessageContextMenuPolicy.items(
                selection: selection,
                isReadStates: readStates,
                flagStates: flagStates,
                folders: parent.folders,
                current: parent.currentFolder,
                accounts: parent.accounts
            )
#if DEBUG
            if ProcessInfo.processInfo.environment["MAILTERNAL_QA_MENU"] == "1" {
                let titles = policyItems.flatMap { item in
                    [item.title] + item.children.map(\.title)
                }
                QALaunch.log("context-menu titles=\(titles.joined(separator: " | "))")
            }
#endif
            for item in policyItems {
                addMenuItem(item, selection: selection, to: menu)
            }
        }

        private func addMenuItem(
            _ policyItem: MessageContextMenuPolicy.Item,
            selection: Set<MessageID>,
            to menu: NSMenu,
            indentationLevel: Int = 0
        ) {
            if policyItem.isSeparator {
                menu.addItem(.separator())
                return
            }
            // Account groups are visual headers, not disabled submenus:
            // AppKit propagates a disabled parent's state to every descendant.
            if policyItem.action == nil,
               !policyItem.isEnabled,
               !policyItem.children.isEmpty {
                let header = NSMenuItem(title: policyItem.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.indentationLevel = indentationLevel
                menu.addItem(header)
                for child in policyItem.children {
                    addMenuItem(child, selection: selection, to: menu, indentationLevel: indentationLevel + 1)
                }
                return
            }
            let menuItem = NSMenuItem(
                title: policyItem.title,
                action: policyItem.children.isEmpty ? #selector(performMenuAction(_:)) : nil,
                keyEquivalent: ""
            )
            menuItem.target = policyItem.children.isEmpty ? self : nil
            menuItem.indentationLevel = indentationLevel
            menuItem.isEnabled = policyItem.isEnabled
            menuItem.toolTip = policyItem.toolTip
            menuItem.representedObject = policyItem.action.map {
                MenuInvocation(action: $0, selection: selection)
            }
            if !policyItem.children.isEmpty {
                let submenu = NSMenu()
                for child in policyItem.children {
                    addMenuItem(child, selection: selection, to: submenu)
                }
                menuItem.submenu = submenu
            }
            menu.addItem(menuItem)
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let invocation = sender.representedObject as? MenuInvocation,
                  let parent else { return }
            let selection = invocation.selection
            guard !selection.isEmpty else { return }
            switch invocation.action {
            case .openInNewTab:
                let orderedIDs = MessageContextMenuPolicy.orderedSelection(
                    selection,
                    rowOrder: parent.rows.lazy.map(\.id)
                )
                guard !orderedIDs.isEmpty else { return }
                parent.onOpenMessages(orderedIDs, true)
            case .openInNewWindow:
                guard selection.count == 1, let id = selection.first else { return }
                parent.onOpenMessageWindow(id)
            case .reply, .replyAll, .forward, .viewRawSource, .toggleEmailReadingOverride:
                break
            case .markRead, .markUnread:
                parent.onAction(.toggleRead, selection)
            case .flag, .unflag:
                parent.onAction(.toggleFlag, selection)
            case .moveToJunk:
                guard let junk = parent.folders.first(where: { $0.role == .junk }) else { return }
                parent.onMove(selection, junk.id)
            case .delete:
                parent.onAction(.trash, selection)
            case .archive:
                parent.onAction(.archive, selection)
            case .moveTo(let folder):
                parent.onMove(selection, folder)
            case .copyLink:
                parent.onCopyDeepLink(selection)
            case .copySubject:
                parent.onCopySubject(selection)
            }
        }

        private func handleKeyCommand(_ command: MessageTableKeyCommand) {
            guard let parent else { return }
            if case .selectAll = command {
                parent.onSelectAll()
                return
            }
            let ids: Set<MessageID>
            if parent.selectedIDs.isEmpty {
                ids = Set(tableView?.selectedRowIndexes.compactMap { parent.rows[safe: $0]?.id } ?? [])
            } else {
                ids = parent.selectedIDs
            }
            guard !ids.isEmpty else { return }
            switch command {
            case .selectAll:
                break
            case .delete:
                parent.onAction(.trash, ids)
            case .toggleRead:
                parent.onAction(.toggleRead, ids)
            case .toggleFlag:
                parent.onAction(.toggleFlag, ids)
            }
        }
}
}


fileprivate enum MessageTableKeyCommand {
    case selectAll
    case delete
    case toggleRead
    case toggleFlag
}

@MainActor
fileprivate final class MessageTableKeyView: NSTableView {
    var onKeyCommand: ((MessageTableKeyCommand) -> Void)?
    var onListInteraction: (() -> Void)?
    fileprivate private(set) var receivedContextMenuEvent = false
    fileprivate private(set) var contextMenuRow: Int?
    private var contextMenuSelection: IndexSet?
    private var pendingSelectionEvent: MessageTableSelectionEvent?
    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onListInteraction?()
        }
        return becameFirstResponder
    }
    override func rightMouseDown(with event: NSEvent) {
        onListInteraction?()
        contextMenuSelection = selectedRowIndexes
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        contextMenuRow = row >= 0 ? row : nil
        receivedContextMenuEvent = true
        // Let AppKit present the contextual menu, but mark the gesture before
        // NSTableView can move its native selection. The coordinator ignores
        // that transient selection and restores the prior highlight on close.
        super.rightMouseDown(with: event)
    }


    override func menu(for event: NSEvent) -> NSMenu? {
        onListInteraction?()
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        contextMenuRow = row >= 0 ? row : nil
        receivedContextMenuEvent = true

        // NSTableView's implementation draws its contextual clicked-row
        // highlight before presenting the menu. Returning the configured menu
        // directly keeps clicked-row targeting without that extra ring.
        return self.menu
    }

    fileprivate func resetContextMenuTracking() {
        if let contextMenuSelection {
            // Keep model selection and the visible native highlight aligned
            // after AppKit's contextual-click bookkeeping has finished.
            selectRowIndexes(contextMenuSelection, byExtendingSelection: false)
        }
        contextMenuSelection = nil
        contextMenuRow = nil
        receivedContextMenuEvent = false
    }

    fileprivate func consumeSelectionEvent() -> MessageTableSelectionEvent? {
        defer { pendingSelectionEvent = nil }
        return pendingSelectionEvent
    }

    override func mouseDown(with event: NSEvent) {
        onListInteraction?()
        defer { pendingSelectionEvent = nil }
        pendingSelectionEvent = mouseSelectionEvent(for: event, kind: .mouseDown)
        // NSTableView normally becomes first responder as part of a click, but
        // the custom row views and SwiftUI host can leave focus elsewhere.
        // Claim it before AppKit performs selection so arrows work immediately.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pendingSelectionEvent = nil }
        pendingSelectionEvent = mouseSelectionEvent(for: event, kind: .mouseUp)
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onListInteraction?()
        defer { pendingSelectionEvent = nil }
        pendingSelectionEvent = selectionEvent(for: event, phase: .down)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onKeyCommand?(.selectAll)
            return
        }
        if event.keyCode == 51, modifiers.isEmpty || modifiers == .command {
            onKeyCommand?(.delete)
            return
        }
        if modifiers.contains([.command, .shift]) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "u":
                onKeyCommand?(.toggleRead)
                return
            case "l":
                onKeyCommand?(.toggleFlag)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        defer { pendingSelectionEvent = nil }
        pendingSelectionEvent = selectionEvent(for: event, phase: .up)
        super.keyUp(with: event)
    }

    private enum KeyPhase {
        case down
        case up
    }

    private func selectionEvent(
        for event: NSEvent,
        phase: KeyPhase
    ) -> MessageTableSelectionEvent {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        guard let key = Self.navigationKey(for: event.keyCode) else {
            return MessageTableSelectionEvent(kind: .other, command: command, shift: shift)
        }
        let kind: MessageTableSelectionEvent.Kind = phase == .down
            ? .keyDown(key)
            : .keyUp(key)
        return MessageTableSelectionEvent(kind: kind, command: command, shift: shift)
    }

    private func mouseSelectionEvent(
        for event: NSEvent,
        kind: MessageTableSelectionEvent.Kind
    ) -> MessageTableSelectionEvent {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return MessageTableSelectionEvent(
            kind: kind,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift)
        )
    }


    private static func navigationKey(for keyCode: UInt16) -> MessageTableNavigationKey? {
        switch keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default: return nil
        }
    }
}

@MainActor
final class MessageTableContainer: NSView {
    let scrollView = NSScrollView()
    fileprivate let tableView = MessageTableKeyView()
    fileprivate var onSelectAll: (() -> Void)?
    private(set) var accentColor: NSColor?
    var onVisibleRow: ((Int) -> Void)?
    var onScrollOffset: ((CGFloat) -> Void)?
    fileprivate var onKeyCommand: ((MessageTableKeyCommand) -> Void)?
    private var suppressScrollPersistence = false
    private var topRestDepth: CGFloat = 0
    private var presentsColumns = false
    private var scrollTopConstraint: NSLayoutConstraint!

    init(topRestDepth: CGFloat = MailWindowDissolvePolicy.messageList.restDepth(safeAreaTop: 0)) {
        let frameRect = NSRect(origin: .zero, size: .zero)
        super.init(frame: frameRect)
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        // Sidebar drops are in-process SwiftUI targets, so allow copy for
        // both local and external drag sessions.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.setAccessibilityIdentifier(UIIdentifier.messageTable)
        tableView.rowHeight = MessageListLayout.rowHeight(for: MessageListLayout.defaultLineCount)
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.focusRingType = .none
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        OverlayScrollerPolicy.apply(to: scrollView)
        scrollView.borderType = .noBorder
        scrollView.contentView.backgroundColor = .clear
        // The pane's frame runs to the physical window top, so rows travel up
        // beneath the fixed title and dissolve in the mask's ramp on the way.
        // The scroll CONTENT stops at the ramp's end, so the first row comes
        // to rest below it and stays readable. `contentInsets` does that
        // without moving the view: the clip view keeps its full-bleed frame,
        // so no row geometry and no bottom edge moves. The automatic insets
        // would derive the same band from a safe area this pane has already
        // cleared, and overwrite it with zero. NSScrollView already accounts
        // for `contentInsets.top` when positioning the scroller thumb, so
        // repeating `topRest` in `scrollerInsets` would displace it downward.
        let topRest = max(topRestDepth, 0)
        self.topRestDepth = topRest
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topRest, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets()
        scrollView.suppressSystemScrollEdgeEffect()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        scrollTopConstraint = scrollView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollTopConstraint,
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    /// Installs native AppKit columns with a visible 24-point header. Status
    /// columns show compact icons with complete accessibility labels; cards
    /// retain their single borderless column.
    func apply(configuration: MailListConfiguration) {
        presentsColumns = configuration.presentation == .columns
        updateTopRestDepth(topRestDepth)
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        if configuration.presentation == .cards {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
            tableView.headerView = nil
            tableView.allowsColumnReordering = false
            tableView.allowsColumnResizing = false
            scrollView.hasHorizontalScroller = false
            return
        }

        tableView.headerView = NSTableHeaderView(
            frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 24)
        )
        scrollView.hasHorizontalScroller = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        for item in configuration.columnOrder {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(item.rawValue))
            column.title = item.title
            column.minWidth = item == .subject ? 80 : 36
            column.maxWidth = item == .subject ? 2_000 : 800
            column.width = max(
                CGFloat(configuration.columnWidths[item] ?? Double(item.defaultWidth)),
                column.minWidth
            )
            column.resizingMask = [.userResizingMask, .autoresizingMask]
            column.isHidden = configuration.hiddenColumns.contains(item)
            tableView.addTableColumn(column)
            if item.sortField == configuration.sort.field {
                let symbol = configuration.sort.direction == .ascending
                    ? "chevron.up"
                    : "chevron.down"
                tableView.setIndicatorImage(
                    NSImage(systemSymbolName: symbol, accessibilityDescription: "Sorted"),
                    in: column
                )
            }
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollView.suppressSystemScrollEdgeEffect()
    }


    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func boundsChanged() {
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.length > 0 {
            onVisibleRow?(visible.location + visible.length - 1)
        }
        guard !suppressScrollPersistence else { return }
        onScrollOffset?(max(scrollView.contentView.bounds.origin.y, 0))
    }

    @discardableResult
    func restoreScrollOffset(_ offset: CGFloat) -> Bool {
        let clip = scrollView.contentView
        let target = max(offset, 0)
        let tolerance: CGFloat = 0.5
        if abs(clip.bounds.origin.y - target) <= tolerance {
            return true
        }
        if target == 0 {
            // Zero is always the list origin, even before the first page has
            // created a document tall enough to scroll.
            suppressScrollPersistence = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: 0))
            scrollView.reflectScrolledClipView(clip)
            suppressScrollPersistence = false
            return true
        }

        // Consult the current document geometry and ask AppKit where this
        // clip view can actually scroll before mutating it. During an early
        // page/layout pass, the document is shorter than the saved position
        // and AppKit constrains the proposed bounds to a temporary maximum.
        // Leave the request pending rather than persisting that position.
        let documentRect = clip.documentRect
        let maximumOriginY = documentRect.maxY - clip.bounds.height
        guard clip.bounds.height > .ulpOfOne,
              target >= documentRect.minY - tolerance,
              target <= maximumOriginY + tolerance
        else {
            return false
        }
        let proposedBounds = NSRect(
            origin: NSPoint(x: clip.bounds.origin.x, y: target),
            size: clip.bounds.size
        )
        let constrainedBounds = clip.constrainBoundsRect(proposedBounds)
        guard abs(constrainedBounds.origin.y - target) <= tolerance else {
            return false
        }

        suppressScrollPersistence = true
        clip.setBoundsOrigin(constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clip)
        suppressScrollPersistence = false
        return abs(clip.bounds.origin.y - target) <= tolerance
    }
    /// Moves an abandoned restore request to the furthest position currently
    /// reachable by the document, without feeding the adjustment back into
    /// persisted list-scroll state while restoration is being resolved.
    func clampScrollOffset(_ offset: CGFloat) {
        let clip = scrollView.contentView
        let maximumOriginY = max(0, clip.documentRect.maxY - clip.bounds.height)
        let target = min(max(offset, 0), maximumOriginY)
        suppressScrollPersistence = true
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        suppressScrollPersistence = false
    }


    /// Updating the measured title/status band must not turn a selection
    /// change into a scroll request. AppKit may adjust the clip origin when
    /// contentInsets changes, so restore that exact origin without feeding a
    /// synthetic scroll event back into the persisted per-folder offset.
    func updateTopRestDepth(_ depth: CGFloat) {
        topRestDepth = max(depth, 0)
        // The native header must sit below the fixed title, not behind its
        // dissolve. Cards retain full-bleed scrolling with a content inset.
        let topRest = presentsColumns ? 0 : topRestDepth
        let frameInset = presentsColumns ? topRestDepth : 0
        guard abs(scrollView.contentInsets.top - topRest) > .ulpOfOne
            || abs(scrollTopConstraint.constant - frameInset) > .ulpOfOne else { return }
        let clip = scrollView.contentView
        let origin = clip.bounds.origin
        suppressScrollPersistence = true
        scrollTopConstraint.constant = frameInset
        scrollView.contentInsets = NSEdgeInsets(top: topRest, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets()
        clip.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clip)
        suppressScrollPersistence = false
    }
    @discardableResult
    func updateAccent(_ source: AccentSource) -> Bool {
        let color = source.nsColor
        guard accentColor?.isEqual(color) != true else { return false }
        accentColor = color
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return true }
        for row in visible.location..<(visible.location + visible.length) {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? MessageRowChrome)?
                .updateAccentColor(color)
            for column in 0..<tableView.numberOfColumns {
                let view = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
                (view as? MessageCellView)?.updateAccentColor(color)
                (view as? MessageColumnCellView)?.updateAccentColor(color)
            }
        }
        return true
    }
}

@MainActor
private protocol MessageTableChromeCell: AnyObject {
    func updateSelection(_ selected: Bool)
    func setHovered(_ hovered: Bool)
    func refreshChrome()
    func updateAccentColor(_ color: NSColor?)
}

@MainActor
final class MessageRowChrome: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("MessageRowChrome")
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        focusRingType = .none
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        cellViews.forEach { $0.updateSelection(isSelected) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        cellViews.forEach { $0.setHovered(true) }
    }

    override func mouseExited(with event: NSEvent) {
        cellViews.forEach { $0.setHovered(false) }
    }

    override var isSelected: Bool {
        get { super.isSelected }
        set {
            super.isSelected = newValue
            cellViews.forEach { $0.updateSelection(newValue) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cellViews.forEach { $0.refreshChrome() }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    func updateAccentColor(_ color: NSColor?) {
        cellViews.forEach { $0.updateAccentColor(color) }
    }

    private var cellViews: [MessageTableChromeCell] {
        subviews.compactMap { $0 as? MessageTableChromeCell }
    }
}

@MainActor
final class MessageCellView: NSTableCellView, MessageTableChromeCell {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    private let selectionLayer = CALayer()
    private let hoverLayer = CALayer()
    private let fromLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let senderGlyph = NSImageView()
    private let flagIcon = NSImageView()
    private let paperclip = NSImageView()
    private var accentColor: NSColor?
    private var isSelectedRow = false
    private var isHovered = false
    private var lineCount = MessageListLayout.defaultLineCount
    private var fromLeadingConstraint: NSLayoutConstraint!
    private var senderGlyphWidthConstraint: NSLayoutConstraint!
    private var senderGlyphHeightConstraint: NSLayoutConstraint!
    private var subjectTopFromConstraint: NSLayoutConstraint!
    private var subjectTopRowConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        identifier = Self.identifier
        focusRingType = .none
        // AppKit's native row highlight is disabled; keep the custom chrome
        // below every text and icon subview in a stable z-order.
        layer?.addSublayer(selectionLayer)
        layer?.addSublayer(hoverLayer)
        hoverLayer.opacity = 0
        hoverLayer.cornerCurve = .continuous
        selectionLayer.cornerCurve = .continuous
        fromLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        senderGlyph.translatesAutoresizingMaskIntoConstraints = false
        flagIcon.translatesAutoresizingMaskIntoConstraints = false
        paperclip.translatesAutoresizingMaskIntoConstraints = false
        fromLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.lineBreakMode = .byTruncatingTail
        previewLabel.usesSingleLineMode = false
        previewLabel.cell?.wraps = true
        previewLabel.cell?.isScrollable = false
        previewLabel.lineBreakMode = .byWordWrapping
        dateLabel.lineBreakMode = .byClipping
        previewLabel.textColor = .secondaryLabelColor
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        flagIcon.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Flagged")
        flagIcon.contentTintColor = .systemOrange
        flagIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        flagIcon.setAccessibilityElement(true)
        flagIcon.setAccessibilityLabel("Flagged")
        flagIcon.isHidden = true
        flagIcon.setAccessibilityHidden(true)
        senderGlyph.imageScaling = .scaleProportionallyUpOrDown
        senderGlyph.imageAlignment = .alignCenter
        senderGlyph.isHidden = true
        senderGlyph.setAccessibilityHidden(true)
        paperclip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Has attachments")
        paperclip.contentTintColor = .tertiaryLabelColor
        paperclip.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        addSubview(senderGlyph)
        addSubview(fromLabel)
        addSubview(subjectLabel)
        addSubview(previewLabel)
        addSubview(dateLabel)
        addSubview(flagIcon)
        addSubview(paperclip)
        subjectTopFromConstraint = subjectLabel.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 2)
        subjectTopRowConstraint = subjectLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        fromLeadingConstraint = fromLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        senderGlyphWidthConstraint = senderGlyph.widthAnchor.constraint(equalToConstant: 20)
        senderGlyphHeightConstraint = senderGlyph.heightAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            fromLeadingConstraint,
            senderGlyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MessageListIconPolicy.leadingInset),
            senderGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            senderGlyphWidthConstraint,
            senderGlyphHeightConstraint,
            fromLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dateLabel.centerYAnchor.constraint(equalTo: fromLabel.centerYAnchor),
            flagIcon.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -6),
            flagIcon.centerYAnchor.constraint(equalTo: dateLabel.centerYAnchor),
            flagIcon.widthAnchor.constraint(equalToConstant: 12),
            flagIcon.heightAnchor.constraint(equalToConstant: 12),
            fromLabel.trailingAnchor.constraint(lessThanOrEqualTo: flagIcon.leadingAnchor, constant: -8),
            subjectLabel.leadingAnchor.constraint(equalTo: fromLabel.leadingAnchor),
            subjectTopFromConstraint,
            paperclip.trailingAnchor.constraint(equalTo: dateLabel.trailingAnchor),
            paperclip.centerYAnchor.constraint(equalTo: subjectLabel.centerYAnchor),
            paperclip.widthAnchor.constraint(equalToConstant: 12),
            subjectLabel.trailingAnchor.constraint(lessThanOrEqualTo: paperclip.leadingAnchor, constant: -6),
            previewLabel.leadingAnchor.constraint(equalTo: fromLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: dateLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 2),
        ])
    }
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: MessageListLayout.rowHeight(for: lineCount)
        )
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateChromeGeometry()
    }

    func updateSelection(_ selected: Bool) {
        isSelectedRow = selected
        refreshChrome()
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        let targetOpacity: Float = hovered && !isSelectedRow ? 1 : 0
        if hovered {
            hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverLayer.opacity = targetOpacity
        }
    }

    func refreshChrome() {
        updateChromeGeometry()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = accentColor?.usingColorSpace(.sRGB)?.cgColor
            selectionLayer.backgroundColor = isSelectedRow ? accent : nil
            hoverLayer.opacity = isSelectedRow ? 0 : (isHovered ? 1 : 0)
        }
    }

    private func updateChromeGeometry() {
        // During a live preference update AppKit can lay out a reused cell
        // once with its old bounds. Capping to the policy height keeps the
        // selection and hover layers from drawing into the next row during
        // that transient layout.
        let contentHeight = MessageListLayout.rowHeight(for: lineCount)
        let height = max(min(bounds.height, contentHeight) - 6, 0)
        // The chrome keeps the row's continuous corner radius while swiping;
        // the inset keeps both corners visible as the row moves with its
        // content. Never restyle the shape mid-gesture.
        let horizontalInset: CGFloat = 8
        let chromeFrame = CGRect(
            x: horizontalInset,
            y: 3,
            width: max(bounds.width - horizontalInset * 2, 0),
            height: height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = chromeFrame
        selectionLayer.frame = chromeFrame
        hoverLayer.cornerRadius = AppShapeScale.row
        selectionLayer.cornerRadius = AppShapeScale.row
        CATransaction.commit()
    }


    func apply(
        _ row: MessageRow,
        lineCount: Int,
        showsSenderIcons: Bool = false,
        favicon: NSImage? = nil
    ) {
        let normalizedLineCount = MessageListLayout.normalizedLineCount(lineCount)
        if self.lineCount != normalizedLineCount {
            self.lineCount = normalizedLineCount
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
        let visibility = MessageListLayout.fieldVisibility(for: normalizedLineCount)
        let iconMetrics = MessageListIconPolicy.metrics(for: normalizedLineCount)
        senderGlyph.isHidden = !showsSenderIcons
        senderGlyph.image = showsSenderIcons
            ? SenderGlyph.nsImage(
                favicon: favicon,
                initials: SenderGlyph.initials(for: row.from),
                accent: accentColor ?? .controlAccentColor,
                diameter: iconMetrics.diameter
            )
            : nil
        fromLeadingConstraint.constant = showsSenderIcons
            ? iconMetrics.textLeading
            : 16
        senderGlyphWidthConstraint.constant = iconMetrics.diameter
        senderGlyphHeightConstraint.constant = iconMetrics.diameter
        fromLabel.isHidden = !visibility.sender
        dateLabel.isHidden = !visibility.date
        previewLabel.isHidden = !visibility.preview
        previewLabel.maximumNumberOfLines = MessageListLayout.previewLineCount(for: normalizedLineCount)
        previewLabel.lineBreakMode = visibility.preview ? .byWordWrapping : .byTruncatingTail
        NSLayoutConstraint.deactivate([subjectTopFromConstraint, subjectTopRowConstraint])
        NSLayoutConstraint.activate([
            visibility.sender ? subjectTopFromConstraint : subjectTopRowConstraint
        ])

        fromLabel.stringValue = row.from
        fromLabel.font = .systemFont(ofSize: MessageTypography.bodyPointSize, weight: row.isRead ? .regular : .semibold)
        subjectLabel.stringValue = row.subject
        subjectLabel.font = .systemFont(ofSize: 12, weight: row.isRead ? .regular : .medium)
        subjectLabel.textColor = row.isRead ? .secondaryLabelColor : .labelColor
        previewLabel.stringValue = row.preview
        previewLabel.font = .systemFont(ofSize: 12)
        dateLabel.stringValue = MailDateFormat.listRow(row.date)
        dateLabel.font = .systemFont(ofSize: 11, weight: row.isRead ? .regular : .medium)
        flagIcon.isHidden = !(row.isFlagged && visibility.date)
        flagIcon.setAccessibilityHidden(!row.isFlagged || !visibility.date)
        flagIcon.toolTip = row.isFlagged ? "Flagged" : nil
        paperclip.isHidden = !row.hasAttachments
        let flagDescription = row.isFlagged ? ", Flagged" : ""
        setAccessibilityLabel("\(row.from), \(row.subject), \(MailDateFormat.listRow(row.date))\(flagDescription)")
        setAccessibilityRole(.staticText)
    }
    func updateAccentColor(_ color: NSColor?) {
        accentColor = color
        refreshChrome()
    }

}

@MainActor
final class MessageColumnCellView: NSTableCellView, MessageTableChromeCell {
    private let selectionLayer = CALayer()
    private let hoverLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var labelLeadingConstraint: NSLayoutConstraint!
    private var iconLeadingConstraint: NSLayoutConstraint!
    private var iconWidthConstraint: NSLayoutConstraint!
    private var accentColor: NSColor?
    private var isSelectedRow = false
    private var isHovered = false

    static func identifier(for column: MailListColumn) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("MessageColumn.\(column.rawValue)")
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.masksToBounds = false
        focusRingType = .none
        layer?.addSublayer(selectionLayer)
        layer?.addSublayer(hoverLayer)
        selectionLayer.cornerCurve = .continuous
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        icon.setAccessibilityHidden(true)
        addSubview(icon)
        addSubview(label)
        iconLeadingConstraint = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        iconWidthConstraint = icon.widthAnchor.constraint(equalToConstant: 20)
        labelLeadingConstraint = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            iconLeadingConstraint,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            icon.heightAnchor.constraint(equalToConstant: 20),
            labelLeadingConstraint,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let frame = bounds.insetBy(dx: 2, dy: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = frame
        hoverLayer.frame = frame
        selectionLayer.cornerRadius = AppShapeScale.row
        hoverLayer.cornerRadius = AppShapeScale.row
        CATransaction.commit()
    }

    func apply(
        _ row: MessageRow,
        column: MailListColumn,
        showsSenderIcon: Bool,
        favicon: NSImage?
    ) {
        let iconName: String?
        let iconDescription: String
        let value: String
        let isIconVisible: Bool
        switch column {
        case .read:
            iconName = row.isRead ? "envelope.open" : "envelope"
            iconDescription = row.isRead ? "Read" : "Unread"
            value = row.isRead ? "Read" : "Unread"
            isIconVisible = true
        case .flagged:
            iconName = row.isFlagged ? "flag.fill" : "flag"
            iconDescription = row.isFlagged ? "Flagged" : "Not flagged"
            value = row.isFlagged ? "Flagged" : "Not flagged"
            isIconVisible = true
        case .attachments:
            iconName = row.hasAttachments ? "paperclip" : nil
            iconDescription = row.hasAttachments ? "Has attachments" : "No attachments"
            value = row.hasAttachments ? "Has attachments" : "No attachments"
            isIconVisible = row.hasAttachments
        case .sender:
            iconName = nil
            iconDescription = "Sender"
            value = row.from
            isIconVisible = showsSenderIcon
        case .subject:
            iconName = nil
            iconDescription = "Subject"
            value = row.subject
            isIconVisible = false
        case .date:
            iconName = nil
            iconDescription = "Date"
            value = MailDateFormat.listRow(row.date)
            isIconVisible = false
        }

        label.stringValue = value
        label.isHidden = column == .read || column == .flagged || column == .attachments
        label.alignment = column == .date ? .right : .left
        label.font = .systemFont(
            ofSize: column == .date ? 11 : 12,
            weight: row.isRead ? .regular : .semibold
        )
        label.textColor = row.isRead ? .secondaryLabelColor : .labelColor
        if column == .sender, showsSenderIcon {
            icon.image = SenderGlyph.nsImage(
                favicon: favicon,
                initials: SenderGlyph.initials(for: row.from),
                accent: accentColor ?? .controlAccentColor,
                diameter: 20
            )
        } else {
            icon.image = iconName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: iconDescription)
            }
            icon.contentTintColor = column == .flagged && row.isFlagged
                ? .systemOrange
                : .secondaryLabelColor
        }
        icon.isHidden = !isIconVisible
        iconWidthConstraint.constant = isIconVisible ? 20 : 0
        labelLeadingConstraint.constant = isIconVisible ? 32 : 8
        setAccessibilityLabel("\(column.title): \(value)")
        setAccessibilityRole(.staticText)
    }

    func updateSelection(_ selected: Bool) {
        isSelectedRow = selected
        refreshChrome()
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverLayer.opacity = hovered && !isSelectedRow ? 1 : 0
        }
    }

    func refreshChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.backgroundColor = isSelectedRow ? accentColor?.cgColor : nil
            hoverLayer.opacity = isSelectedRow ? 0 : (isHovered ? 1 : 0)
        }
    }

    func updateAccentColor(_ color: NSColor?) {
        accentColor = color
        refreshChrome()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
