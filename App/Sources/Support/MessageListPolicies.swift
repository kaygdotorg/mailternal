import Foundation
import MailternalInterfaces

/// Pure transition rules for the per-message email reading override.
enum EmailReadingOverridePolicy {
    static func next(effective: EmailReadingMode) -> EmailReadingMode {
        effective == .original ? .dark : .original
    }

    static func resetsOverride(oldID: MessageID?, newID: MessageID?) -> Bool {
        oldID != newID
    }
}

/// The menu's value model is deliberately independent of AppKit. This keeps
/// the Mail-style ordering, state-aware labels, and folder-tree construction
/// deterministic and directly testable.
enum MessageContextMenuPolicy {
    enum Action: Equatable, Sendable {
        case openInNewWindow
        case reply
        case replyAll
        case forward
        case markRead
        case markUnread
        case flag
        case unflag
        case moveToJunk
        case delete
        case archive
        case moveTo(FolderID)
        case copyLink
        case copySubject
        case viewRawSource
        case toggleEmailReadingOverride
    }

    struct Item: Equatable, Sendable {
        let title: String
        let action: Action?
        let isEnabled: Bool
        let toolTip: String?
        let children: [Item]

        var isSeparator: Bool {
            action == nil && title.isEmpty && children.isEmpty
        }

        fileprivate init(
            title: String,
            action: Action? = nil,
            isEnabled: Bool = true,
            toolTip: String? = nil,
            children: [Item] = []
        ) {
            self.title = title
            self.action = action
            self.isEnabled = isEnabled
            self.toolTip = toolTip
            self.children = children
        }
    }

    static func items(
        selection: Set<MessageID>,
        isReadStates: [MessageID: Bool],
        flagStates: [MessageID: Bool],
        folders: [FolderSummary],
        current: FolderID?
    ) -> [Item] {
        guard !selection.isEmpty else { return [] }
        let count = selection.count
        let countLabel = count.formatted(.number)
        let shouldMarkRead = selection.contains { !(isReadStates[$0] ?? false) }
        let shouldFlag = selection.contains { !(flagStates[$0] ?? false) }
        let currentFolder = folders.first { $0.id == current }
        let canMoveToJunk = folders.contains { $0.role == .junk } && currentFolder?.role != .junk

        return [
            Item(title: "Open in New Window", action: .openInNewWindow, isEnabled: count == 1),
            separator,
            Item(title: "Reply", action: .reply, isEnabled: false, toolTip: composerToolTip),
            Item(title: "Reply All", action: .replyAll, isEnabled: false, toolTip: composerToolTip),
            Item(title: "Forward", action: .forward, isEnabled: false, toolTip: composerToolTip),
            separator,
            Item(
                title: shouldMarkRead ? "Mark as Read" : "Mark as Unread",
                action: shouldMarkRead ? .markRead : .markUnread
            ),
            Item(title: shouldFlag ? "Flag" : "Unflag", action: shouldFlag ? .flag : .unflag),
            Item(
                title: count > 1 ? "Move \(countLabel) Messages to Junk" : "Move to Junk",
                action: .moveToJunk,
                isEnabled: canMoveToJunk
            ),
            Item(
                title: count > 1 ? "Delete \(countLabel) Messages" : "Delete",
                action: .delete
            ),
            separator,
            Item(
                title: count > 1 ? "Archive \(countLabel) Messages" : "Archive",
                action: .archive
            ),
            moveMenu(folders: folders, current: current),
            separator,
            Item(title: "Copy Link", action: .copyLink),
            Item(title: "Copy Subject", action: .copySubject),
        ]
    }

    private static let composerToolTip = "Available with the composer"
    private static let separator = Item(title: "")

    private static func moveMenu(
        folders: [FolderSummary],
        current: FolderID?
    ) -> Item {
        let destinations = folders.filter { $0.id != current }
        let tree = folderTree(destinations)
        return Item(
            title: "Move to",
            isEnabled: !tree.isEmpty,
            children: tree.map(makeTreeItem)
        )
    }

    private struct FolderTreeNode: Sendable {
        var segment: String
        var folder: FolderSummary?
        var children: [FolderTreeNode]
    }

    private static func folderTree(_ folders: [FolderSummary]) -> [FolderTreeNode] {
        var roots: [FolderTreeNode] = []
        for folder in folders {
            let segments = folder.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            insert(
                folder,
                segments: segments.isEmpty ? [folder.name] : segments,
                at: 0,
                into: &roots
            )
        }
        return roots.sorted(by: nodeOrdering)
    }

    private static func insert(
        _ folder: FolderSummary,
        segments: [String],
        at index: Int,
        into nodes: inout [FolderTreeNode]
    ) {
        guard let segment = segments[safe: index] else { return }
        let nodeIndex: Int
        if let existing = nodes.firstIndex(where: { $0.segment == segment }) {
            nodeIndex = existing
        } else {
            nodes.append(FolderTreeNode(segment: segment, folder: nil, children: []))
            nodeIndex = nodes.index(before: nodes.endIndex)
        }
        if index == segments.index(before: segments.endIndex) {
            nodes[nodeIndex].folder = folder
        } else {
            insert(folder, segments: segments, at: index + 1, into: &nodes[nodeIndex].children)
        }
    }

    private static func makeTreeItem(_ node: FolderTreeNode) -> Item {
        Item(
            title: node.folder?.name ?? node.segment,
            action: node.folder.map { .moveTo($0.id) },
            children: node.children.sorted(by: nodeOrdering).map(makeTreeItem)
        )
    }

    private static func nodeOrdering(_ lhs: FolderTreeNode, _ rhs: FolderTreeNode) -> Bool {
        let lhsRank = nodeRoleRank(lhs)
        let rhsRank = nodeRoleRank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.segment.localizedStandardCompare(rhs.segment) == .orderedAscending
    }

    private static func nodeRoleRank(_ node: FolderTreeNode) -> Int {
        let own = node.folder.map(roleRank) ?? Int.max
        return node.children.map(nodeRoleRank).min().map { min(own, $0) } ?? own
    }

    private static func roleRank(_ folder: FolderSummary) -> Int {
        switch folder.role {
        case .inbox: 0
        case .drafts: 1
        case .sent: 2
        case .archive: 3
        case .junk: 4
        case .trash: 5
        case .none: 6
        }
    }
}
/// Pure policy for the message actions shown in the window toolbar. AppKit
/// translates these values into `NSToolbarItem`s and `NSMenuItem`s; keeping the
/// ordering and enablement here makes customization and validation testable
/// without constructing a window.
enum MessageToolbarPolicy {
    enum Identifier: String, CaseIterable, Sendable {
        case archive = "Mailternal.message.archive"
        case trash = "Mailternal.message.trash"
        case flag = "Mailternal.message.flag"
        case source = "Mailternal.message.source"
        case colorScheme = "Mailternal.message.colorScheme"
        case overflow = "Mailternal.message.overflow"
    }

    struct VisibleItem: Equatable, Sendable {
        let identifier: Identifier
        let title: String
        let imageName: String
        let isEnabled: Bool
        let isOn: Bool

        init(
            identifier: Identifier,
            title: String,
            imageName: String,
            isEnabled: Bool,
            isOn: Bool = false
        ) {
            self.identifier = identifier
            self.title = title
            self.imageName = imageName
            self.isEnabled = isEnabled
            self.isOn = isOn
        }
    }

    static let defaultItemIdentifiers: [Identifier] = [
        .archive,
        .trash,
        .flag,
        .source,
        .colorScheme,
        .overflow,
    ]

    static let allowedItemIdentifiers: [Identifier] = defaultItemIdentifiers

    static func visibleItems(
        selection: Set<MessageID>,
        flagStates: [MessageID: Bool],
        effectiveEmailReadingMode: EmailReadingMode = .original,
        isShowingRawSource: Bool = false
    ) -> [VisibleItem] {
        let count = selection.count
        let plural = count > 1 ? " \(count.formatted(.number)) Messages" : ""
        let shouldFlag = selection.contains { !(flagStates[$0] ?? false) }
        let enabled = !selection.isEmpty
        let singleSelection = count == 1
        return [
            VisibleItem(
                identifier: .archive,
                title: "Archive\(plural)",
                imageName: "archivebox",
                isEnabled: enabled
            ),
            VisibleItem(
                identifier: .trash,
                title: "Trash\(plural)",
                imageName: "trash",
                isEnabled: enabled
            ),
            VisibleItem(
                identifier: .flag,
                title: "\(shouldFlag ? "Flag" : "Unflag")\(plural)",
                imageName: shouldFlag ? "flag" : "flag.slash",
                isEnabled: enabled
            ),
            VisibleItem(
                identifier: .source,
                title: "Source",
                imageName: "chevron.left.forwardslash.chevron.right",
                isEnabled: singleSelection,
                isOn: isShowingRawSource
            ),
            VisibleItem(
                identifier: .colorScheme,
                title: "Email Colour Scheme",
                imageName: effectiveEmailReadingMode == .original ? "sun.max" : "moon",
                isEnabled: singleSelection
            ),
        ]
    }

    static func overflowItems(
        selection: Set<MessageID>,
        isReadStates: [MessageID: Bool],
        flagStates: [MessageID: Bool],
        folders: [FolderSummary],
        current: FolderID?
    ) -> [MessageContextMenuPolicy.Item] {
        let contextItems = MessageContextMenuPolicy.items(
            selection: selection,
            isReadStates: isReadStates,
            flagStates: flagStates,
            folders: folders,
            current: current
        )
        let shouldMarkRead = selection.isEmpty || selection.contains {
            !(isReadStates[$0] ?? false)
        }
        let markTitle = shouldMarkRead ? "Mark as Read" : "Mark as Unread"
        let markAction: MessageContextMenuPolicy.Action = shouldMarkRead
            ? .markRead
            : .markUnread
        let fallbackMove = MessageContextMenuPolicy.Item(
            title: "Move to",
            isEnabled: false
        )
        let itemsByAction: (MessageContextMenuPolicy.Action) -> MessageContextMenuPolicy.Item? = {
            action in
            contextItems.first { $0.action == action }
        }
        let mark = itemsByAction(markAction) ?? MessageContextMenuPolicy.Item(
            title: markTitle,
            action: markAction,
            isEnabled: false
        )
        let junk = itemsByAction(.moveToJunk) ?? MessageContextMenuPolicy.Item(
            title: selection.count > 1
                ? "Move \(selection.count.formatted(.number)) Messages to Junk"
                : "Move to Junk",
            action: .moveToJunk,
            isEnabled: false
        )
        let move = contextItems.first { $0.title == "Move to" } ?? fallbackMove
        let open = itemsByAction(.openInNewWindow) ?? MessageContextMenuPolicy.Item(
            title: "Open in New Window",
            action: .openInNewWindow,
            isEnabled: false
        )
        let copyLink = itemsByAction(.copyLink) ?? MessageContextMenuPolicy.Item(
            title: "Copy Link",
            action: .copyLink,
            isEnabled: false
        )
        let copySubject = itemsByAction(.copySubject) ?? MessageContextMenuPolicy.Item(
            title: "Copy Subject",
            action: .copySubject,
            isEnabled: false
        )
        let raw = MessageContextMenuPolicy.Item(
            title: "Source",
            action: .viewRawSource,
            isEnabled: selection.count == 1
        )
        let colorScheme = MessageContextMenuPolicy.Item(
            title: "Email Colour Scheme",
            action: .toggleEmailReadingOverride,
            isEnabled: selection.count == 1
        )
        return [mark, junk, move, open, MessageContextMenuPolicy.Item(title: ""),
                copyLink, copySubject, raw, colorScheme]
    }
}


private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

/// The pasteboard payload used for dragging messages to a mailbox. Canonical
/// deep links are preferred; local IDs fill the payload for selected rows whose
/// links have not finished prefetching yet.
enum MessageLinkPasteboard {
    static let type = "org.kayg.mailternal.message-links"
    private static let messageIDPrefix = "mailternal-message-id:"

    static func encode(_ links: [String]) -> Data {
        (try? JSONEncoder().encode(links)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }

    static func encodeMessageID(_ id: MessageID) -> String {
        "\(messageIDPrefix)\(id.rawValue)"
    }

    static func decodeMessageID(_ value: String) -> MessageID? {
        guard value.hasPrefix(messageIDPrefix),
              let rawValue = Int64(value.dropFirst(messageIDPrefix.count)) else { return nil }
        return MessageID(rawValue: rawValue)
    }
}

/// Reader state shown instead of a single-message detail when the list has a
/// multi-selection. Keeping this copy in a policy makes the state testable
/// without constructing a SwiftUI view.
enum MessageReaderStatePolicy {
    static func emptyStateTitle(selectionCount: Int) -> String? {
        selectionCount > 1 ? "\(selectionCount.formatted(.number)) Messages Selected" : nil
    }

    static func emptyStateDetail(selectionCount: Int) -> String? {
        selectionCount > 1 ? "Choose one message to read it." : nil
    }
}
