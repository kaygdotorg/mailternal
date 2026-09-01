import AppKit
import SwiftUI
import MailternalInterfaces

struct MessageListPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if case .windowed(let since) = model.syncStatus.mode {
                WindowedModeBanner(since: since)
            }
            MessageTableRepresentable(
                rows: model.listRows,
                selectedID: model.selectedMessageID,
                epoch: model.listEpoch,
                onSelect: { model.selectMessage($0) },
                onPrefetch: { model.loadMoreIfNeeded(near: $0) },
                onCopySubject: { model.copySelectedSubject() }
            )
            .overlay {
                if model.isLoadingList, model.listRows.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else if model.folders.isEmpty == false, model.listRows.isEmpty, model.selectedFolderID != nil, !model.isPaging {
                    EmptyMailboxState(title: "No Messages", detail: "This folder is empty.")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 560)
    }
}

struct WindowedModeBanner: View {
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Search covers mail since \(MailDateFormat.syncedThrough(since))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.6))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIIdentifier.windowedBanner)
    }
}

struct MessageTableRepresentable: NSViewRepresentable {
    var rows: [MessageRow]
    var selectedID: MessageID?
    var epoch: UInt64
    var onSelect: (MessageID?) -> Void
    var onPrefetch: (Int) -> Void
    var onCopySubject: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MessageTableContainer {
        let container = MessageTableContainer()
        context.coordinator.bind(container: container, parent: self)
        return container
    }

    func updateNSView(_ nsView: MessageTableContainer, context: Context) {
        context.coordinator.update(container: nsView, parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MessageTableRepresentable?
        weak var tableView: NSTableView?
        private var epoch: UInt64 = 0
        private var rowIDs: [MessageID] = []

        func bind(container: MessageTableContainer, parent: MessageTableRepresentable) {
            self.parent = parent
            tableView = container.tableView
            container.tableView.delegate = self
            container.tableView.dataSource = self
            container.onVisibleRow = { [weak self] row in
                self?.parent?.onPrefetch(row)
            }
            container.tableView.menu = makeMenu()
        }

        func update(container: MessageTableContainer, parent: MessageTableRepresentable) {
            self.parent = parent
            let table = container.tableView
            let oldCount = rowIDs.count
            let newIDs = parent.rows.map(\.id)
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
            } else {
                let visible = table.rows(in: table.visibleRect)
                if visible.length > 0 {
                    table.reloadData(
                        forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
            syncSelection(in: table)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent?.rows.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            parent?.onPrefetch(row)
            let cell = tableView.makeView(withIdentifier: MessageCellView.identifier, owner: self) as? MessageCellView
                ?? MessageCellView()
            if let rowModel = parent?.rows[safe: row] {
                cell.apply(rowModel)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            tableView.makeView(withIdentifier: MessageRowChrome.identifier, owner: self) as? MessageRowChrome
                ?? MessageRowChrome()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 72 }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let row = tableView.selectedRow
            if row >= 0, let id = parent?.rows[safe: row]?.id {
                if parent?.selectedID != id {
                    parent?.onSelect(id)
                }
            } else if parent?.selectedID != nil {
                parent?.onSelect(nil)
            }
        }

        private func syncSelection(in tableView: NSTableView) {
            guard let selectedID = parent?.selectedID,
                  let index = parent?.rows.firstIndex(where: { $0.id == selectedID })
            else {
                if tableView.selectedRow != -1 {
                    tableView.deselectAll(nil)
                }
                return
            }
            if tableView.selectedRow != index {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy Subject", action: #selector(copySubject(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            return menu
        }

        @objc private func copySubject(_ sender: Any?) {
            parent?.onCopySubject()
        }
    }
}

@MainActor
final class MessageTableContainer: NSView {
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    var onVisibleRow: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.setAccessibilityIdentifier(UIIdentifier.messageTable)
        tableView.rowHeight = 72
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.focusRingType = .none
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
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
}

@MainActor
final class MessageRowChrome: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("MessageRowChrome")
    private let selectionLayer = CALayer()
    private let hoverLayer = CALayer()
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        identifier = Self.identifier
        hoverLayer.cornerRadius = AppShapeScale.row
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        selectionLayer.cornerRadius = AppShapeScale.row
        selectionLayer.cornerCurve = .continuous
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(selectionLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: 8, dy: 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = inset
        selectionLayer.frame = inset
        CATransaction.commit()
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
        hoverLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverLayer.opacity = isSelected ? 0 : 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverLayer.opacity = 0
        }
    }

    override var isSelected: Bool {
        get { super.isSelected }
        set {
            super.isSelected = newValue
            refreshChrome()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshChrome()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    private func refreshChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.cgColor
                : nil
            hoverLayer.opacity = isSelected ? 0 : hoverLayer.opacity
        }
    }
}

@MainActor
final class MessageCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    private let unreadDot = NSView()
    private let fromLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let paperclip = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 4
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        fromLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        paperclip.translatesAutoresizingMaskIntoConstraints = false
        fromLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.lineBreakMode = .byTruncatingTail
        previewLabel.lineBreakMode = .byTruncatingTail
        dateLabel.lineBreakMode = .byClipping
        previewLabel.textColor = .secondaryLabelColor
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        paperclip.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Has attachments")
        paperclip.contentTintColor = .tertiaryLabelColor
        paperclip.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        addSubview(unreadDot)
        addSubview(fromLabel)
        addSubview(subjectLabel)
        addSubview(previewLabel)
        addSubview(dateLabel)
        addSubview(paperclip)
        NSLayoutConstraint.activate([
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            unreadDot.centerYAnchor.constraint(equalTo: fromLabel.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            fromLabel.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: 8),
            fromLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            dateLabel.centerYAnchor.constraint(equalTo: fromLabel.centerYAnchor),
            fromLabel.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),
            subjectLabel.leadingAnchor.constraint(equalTo: fromLabel.leadingAnchor),
            subjectLabel.topAnchor.constraint(equalTo: fromLabel.bottomAnchor, constant: 2),
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
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ row: MessageRow) {
        fromLabel.stringValue = row.from
        fromLabel.font = .systemFont(ofSize: MessageTypography.bodyPointSize, weight: row.isRead ? .regular : .semibold)
        subjectLabel.stringValue = row.subject
        subjectLabel.font = .systemFont(ofSize: 12, weight: row.isRead ? .regular : .medium)
        subjectLabel.textColor = row.isRead ? .secondaryLabelColor : .labelColor
        previewLabel.stringValue = row.preview
        previewLabel.font = .systemFont(ofSize: 12)
        dateLabel.stringValue = MailDateFormat.listRow(row.date)
        dateLabel.font = .systemFont(ofSize: 11, weight: row.isRead ? .regular : .medium)
        paperclip.isHidden = !row.hasAttachments
        unreadDot.layer?.backgroundColor = row.isRead ? NSColor.clear.cgColor : NSColor.controlAccentColor.cgColor
        unreadDot.toolTip = row.isRead ? nil : "Unread"
        unreadDot.setAccessibilityElement(true)
        unreadDot.setAccessibilityIdentifier(UIIdentifier.unreadDot)
        unreadDot.setAccessibilityLabel("Unread")
        unreadDot.setAccessibilityHidden(row.isRead)
        setAccessibilityLabel("\(row.from), \(row.subject), \(MailDateFormat.listRow(row.date))")
        setAccessibilityRole(.staticText)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
