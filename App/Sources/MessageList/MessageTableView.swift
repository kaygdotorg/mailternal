import AppKit
import SwiftUI
import MailternalInterfaces

struct MessageListPane: View {
    @Bindable var model: AppModel
    @Environment(ActionSettings.self) private var actions
    @State private var titleShowsAccount = false
    @State private var titleHeight: CGFloat = 0

    private var listDissolvePolicy: MailWindowDissolvePolicy {
        // The button measurement includes its 12pt bottom padding and the
        // font's descent. Starting the mask here puts its clear stop at the
        // H1 baseline; the 52pt ramp then reaches opaque content below it.
        .messageList.withTopOrigin(max(titleHeight - 18, 0))
    }

    private var listTitle: String {
        titleShowsAccount
            ? model.listTitleAccountName
            : (model.selectedFolder?.name ?? "Messages")
    }

    var body: some View {
        ZStack(alignment: .top) {
            MessageTableRepresentable(
                rows: model.listRows,
                selectedID: model.selectedMessageID,
                selectedIDs: model.selectedMessageIDs,
                messageLinks: model.messageDeepLinks,
                folders: model.folders,
                currentFolder: model.selectedFolderID,
                epoch: model.listEpoch,
                lineCount: model.appearance.messageListLines,
                accent: model.appearance.accent,
                leading: actions.leadingSwipe,
                trailing: actions.trailingSwipe,
                topRestDepth: listDissolvePolicy.restDepth(safeAreaTop: 0),
                onSelect: { ids, anchor in model.selectMessages(ids, anchor: anchor) },
                onSelectAll: { model.selectAllMessages() },
                onPrefetch: { model.loadMoreIfNeeded(near: $0) },
                onCopySubject: { ids in model.copySubjects(for: ids) },
                onCopyDeepLink: { ids in
                    Task { await model.copyDeepLinks(for: ids) }
                },
                onAction: { kind, ids in model.perform(kind, on: ids) },
                onMove: { ids, folder in model.move(ids: ids, to: folder) },
                onOpenMessageWindow: { model.openMessageWindow($0) }
            )
            .mailWindowDissolve(listDissolvePolicy)

            Button {
                withAnimation(MailMotion.disclosure) {
                    titleShowsAccount.toggle()
                }
            } label: {
                Text(listTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(listTitle)
                    .transition(.opacity)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(UIIdentifier.messageListTitle)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { titleHeight = $0 }
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

struct MessageTableRepresentable: NSViewRepresentable {
    var rows: [MessageRow]
    var selectedID: MessageID?
    var selectedIDs: Set<MessageID>
    var messageLinks: [MessageID: String]
    var folders: [FolderSummary]
    var currentFolder: FolderID?
    var epoch: UInt64
    var lineCount: Int
    var accent: AccentSource
    var leading: [SwipeActionKind]
    var trailing: [SwipeActionKind]
    var topRestDepth: CGFloat
    var onSelect: (Set<MessageID>, MessageID?) -> Void
    var onSelectAll: () -> Void
    var onPrefetch: (Int) -> Void
    var onCopySubject: (Set<MessageID>) -> Void
    var onCopyDeepLink: (Set<MessageID>) -> Void
    var onAction: (SwipeActionKind, Set<MessageID>) -> Void
    var onMove: (Set<MessageID>, FolderID) -> Void
    var onOpenMessageWindow: (MessageID) -> Void


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
        weak var container: MessageTableContainer?
        weak var tableView: NSTableView?
        private var epoch: UInt64 = 0
        private var rowIDs: [MessageID] = []

        func bind(container: MessageTableContainer, parent: MessageTableRepresentable) {
            self.parent = parent
            self.container = container
            tableView = container.tableView
            container.updateAccent(parent.accent)
            container.tableView.delegate = self
            container.tableView.dataSource = self
            container.onVisibleRow = { [weak self] row in
                self?.parent?.onPrefetch(row)
            }
            container.onKeyCommand = { [weak self] command in
                self?.handleKeyCommand(command)
            }
            container.onSelectAll = { [weak self] in
                self?.parent?.onSelectAll()
            }
            container.tableView.menu = makeMenu()
            container.tableView.target = self
            container.tableView.doubleAction = #selector(handleDoubleAction(_:))
        }

        @objc private func handleDoubleAction(_ sender: NSTableView) {
            guard let parent else { return }
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            guard let messageID = parent.rows[safe: row]?.id else { return }
            parent.onOpenMessageWindow(messageID)
        }

        func update(container: MessageTableContainer, parent: MessageTableRepresentable) {
            self.parent = parent
            container.updateTopRestDepth(parent.topRestDepth)
            let table = container.tableView
            // SwiftUI observes AccentSource; resolve it at this AppKit bridge
            // and refresh rows only when the canonical color actually changes.
            let accentChanged = container.updateAccent(parent.accent)
            let oldCount = rowIDs.count
            let newIDs = parent.rows.map(\.id)
            let newLineCount = MessageListLayout.normalizedLineCount(parent.lineCount)
            let lineCountChanged = newLineCount != lineCount
            lineCount = newLineCount

            if parent.epoch != epoch {
                epoch = parent.epoch
                rowIDs = newIDs
                table.reloadData()
                if table.numberOfRows > 0 {
                    table.scrollRowToVisible(0)
                }
            } else if newIDs.count > oldCount, newIDs.starts(with: rowIDs) {
                rowIDs = newIDs
                let added = IndexSet(integersIn: oldCount..<newIDs.count)
                table.insertRows(at: added, withAnimation: [])
            } else if newIDs != rowIDs {
                rowIDs = newIDs
                table.reloadData()
            } else if accentChanged {
                reloadVisibleRows(in: table)
            }

            if lineCountChanged {
                let origin = table.enclosingScrollView?.contentView.bounds.origin
                if table.numberOfRows > 0 {
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
                }
                reloadVisibleRows(in: table)
                if let origin, let scrollView = table.enclosingScrollView {
                    scrollView.contentView.setBoundsOrigin(origin)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
            syncSelection(in: table)
        }

        private func reloadVisibleRows(in table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                table.reloadData(
                    forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            parent?.onPrefetch(row)
            let cell = tableView.makeView(withIdentifier: MessageCellView.identifier, owner: self) as? MessageCellView
                ?? MessageCellView()
            cell.updateAccentColor(container?.accentColor)
            if let rowModel = parent?.rows[safe: row] {
                cell.apply(rowModel, lineCount: lineCount)
            }
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
            MessageListLayout.rowHeight(for: lineCount)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView, let parent else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { index in
                parent.rows[safe: index]?.id
            })
            let clickedID = parent.rows[safe: tableView.clickedRow]?.id
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.command), let clickedID {
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
            parent.onSelect(ids, anchor)
        }

        private var lastScrolledSelectionID: MessageID?
        private func syncSelection(in tableView: NSTableView) {
            guard let parent else { return }
            let selectedIndexes = IndexSet(
                parent.rows.indices.filter { parent.selectedIDs.contains(parent.rows[$0].id) }
            )
            if tableView.selectedRowIndexes != selectedIndexes {
                tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
            }

            guard let selectedID = parent.selectedID,
                  let index = parent.rows.firstIndex(where: { $0.id == selectedID })
            else {
                lastScrolledSelectionID = nil
                return
            }
            // A new selection (click, deep link, restoration) is brought into
            // view exactly once; index shifts from backfill prepends and
            // reloads must not yank an established scroll position.
            if lastScrolledSelectionID != selectedID {
                lastScrolledSelectionID = selectedID
                tableView.scrollRowToVisible(index)
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

        private var menuSelection: Set<MessageID>?

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuWillOpen(_ menu: NSMenu) {
            menuSelection = nil
        }

        func menuDidClose(_ menu: NSMenu) {
            menuSelection = nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let parent, let clickedMessageID else { return }
            let selection: Set<MessageID>
            if parent.selectedIDs.contains(clickedMessageID) {
                selection = parent.selectedIDs
            } else {
                selection = [clickedMessageID]
                parent.onSelect(selection, clickedMessageID)
            }
            menuSelection = selection
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
                current: parent.currentFolder
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
                addMenuItem(item, to: menu)
            }
        }

        private func addMenuItem(_ policyItem: MessageContextMenuPolicy.Item, to menu: NSMenu) {
            if policyItem.isSeparator {
                menu.addItem(.separator())
                return
            }
            let menuItem = NSMenuItem(
                title: policyItem.title,
                action: policyItem.children.isEmpty ? #selector(performMenuAction(_:)) : nil,
                keyEquivalent: ""
            )
            menuItem.target = policyItem.children.isEmpty ? self : nil
            menuItem.isEnabled = policyItem.isEnabled
            menuItem.toolTip = policyItem.toolTip
            menuItem.representedObject = policyItem.action
            if !policyItem.children.isEmpty {
                let submenu = NSMenu()
                for child in policyItem.children {
                    addMenuItem(child, to: submenu)
                }
                menuItem.submenu = submenu
            }
            menu.addItem(menuItem)
        }

        private var clickedMessageID: MessageID? {
            guard let tableView,
                  tableView.clickedRow >= 0,
                  let row = parent?.rows[safe: tableView.clickedRow] else { return nil }
            return row.id
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? MessageContextMenuPolicy.Action,
                  let parent else { return }
            let selection = menuSelection ?? [clickedMessageID].compactMap { $0 }.reduce(into: Set<MessageID>()) {
                $0.insert($1)
            }
            guard !selection.isEmpty else { return }
            switch action {
            case .openInNewWindow:
                guard selection.count == 1, let id = selection.first else { return }
                parent.onOpenMessageWindow(id)
            case .reply, .replyAll, .forward, .viewRawSource:
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

    override func keyDown(with event: NSEvent) {
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
}

@MainActor
final class MessageTableContainer: NSView {
    let scrollView = NSScrollView()
    fileprivate let tableView = MessageTableKeyView()
    fileprivate var onSelectAll: (() -> Void)?
    private(set) var accentColor: NSColor?
    var onVisibleRow: ((Int) -> Void)?
    fileprivate var onKeyCommand: ((MessageTableKeyCommand) -> Void)?

    init(topRestDepth: CGFloat = MailWindowDissolvePolicy.messageList.restDepth(safeAreaTop: 0)) {
        let frameRect = NSRect(origin: .zero, size: .zero)
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
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
        scrollView.borderType = .noBorder
        scrollView.contentView.backgroundColor = .clear
        // The pane's frame runs to the physical window top, so rows travel up
        // beneath the fixed title and dissolve in the mask's ramp on the way.
        // The scroll CONTENT stops at the ramp's end, so the first row comes
        // to rest below it and stays readable. `contentInsets` does that
        // without moving the view: the clip view keeps its full-bleed frame,
        // so no row geometry and no bottom edge moves. The automatic insets
        // would derive the same band from a safe area this pane has already
        // cleared, and overwrite it with zero. `scrollerInsets` follows the
        // content, because the scroller belongs beside the rows, not under the
        // title.
        let topRest = max(topRestDepth, 0)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topRest, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topRest, left: 0, bottom: 0, right: 0)
        scrollView.suppressSystemScrollEdgeEffect()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
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
    }

    func updateTopRestDepth(_ depth: CGFloat) {
        let topRest = max(depth, 0)
        guard abs(scrollView.contentInsets.top - topRest) > .ulpOfOne else { return }
        scrollView.contentInsets = NSEdgeInsets(top: topRest, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topRest, left: 0, bottom: 0, right: 0)
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
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?
                .updateAccentColor(color)
        }
        return true
    }
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
        messageCellView?.updateSelection(isSelected)
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
        messageCellView?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        messageCellView?.setHovered(false)
    }

    override var isSelected: Bool {
        get { super.isSelected }
        set {
            super.isSelected = newValue
            messageCellView?.updateSelection(newValue)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        messageCellView?.refreshChrome()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    func updateAccentColor(_ color: NSColor?) {
        messageCellView?.updateAccentColor(color)
    }

    private var messageCellView: MessageCellView? {
        subviews.first(where: { $0 is MessageCellView }) as? MessageCellView
    }
}

@MainActor
final class MessageCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    private let selectionLayer = CALayer()
    private let hoverLayer = CALayer()
    private let fromLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let flagIcon = NSImageView()
    private let paperclip = NSImageView()
    private var accentColor: NSColor?
    private var isSelectedRow = false
    private var isHovered = false
    private var subjectTopFromConstraint: NSLayoutConstraint!
    private var subjectTopRowConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        identifier = Self.identifier
        focusRingType = .none
        hoverLayer.opacity = 0
        hoverLayer.cornerCurve = .continuous
        selectionLayer.cornerCurve = .continuous
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(selectionLayer)
#if DEBUG
        assert(selectionLayer.superlayer === layer)
#endif
        fromLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
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
        paperclip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Has attachments")
        paperclip.contentTintColor = .tertiaryLabelColor
        paperclip.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        addSubview(fromLabel)
        addSubview(subjectLabel)
        addSubview(previewLabel)
        addSubview(dateLabel)
        addSubview(flagIcon)
        addSubview(paperclip)
        subjectTopFromConstraint = subjectLabel.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 2)
        subjectTopRowConstraint = subjectLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        NSLayoutConstraint.activate([
            fromLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
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
        let height = max(bounds.height - 6, 0)
        // Keep the capsule within the cell while swiping so both continuous
        // corners remain visible as the row moves with its content.
        let horizontalInset: CGFloat = 8
        let chromeFrame = CGRect(
            x: horizontalInset,
            y: 3,
            width: max(bounds.width - horizontalInset * 2, 0),
            height: height
        )
        let radius = min(height / 2, chromeFrame.width / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = chromeFrame
        selectionLayer.frame = chromeFrame
        hoverLayer.cornerRadius = isSwiped ? radius : AppShapeScale.row
        selectionLayer.cornerRadius = isSwiped ? radius : AppShapeScale.row
        CATransaction.commit()
    }

    private var isSwiped: Bool {
        let frameOffset = frame.minX
        let modelTransform = layer?.affineTransform().tx ?? 0
        let presentationTransform = layer?.presentation()?.affineTransform().tx ?? 0
        return abs(frameOffset) > 0.5
            || abs(modelTransform) > 0.5
            || abs(presentationTransform) > 0.5
    }

    func apply(_ row: MessageRow, lineCount: Int) {
        let visibility = MessageListLayout.fieldVisibility(for: lineCount)
        fromLabel.isHidden = !visibility.sender
        dateLabel.isHidden = !visibility.date
        previewLabel.isHidden = !visibility.preview
        previewLabel.maximumNumberOfLines = MessageListLayout.previewLineCount(for: lineCount)
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
