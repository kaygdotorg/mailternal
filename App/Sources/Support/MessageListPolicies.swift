import Foundation
import MailternalInterfaces

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
                title: count > 1 ? "Move \(count) Messages to Junk" : "Move to Junk",
                action: .moveToJunk,
                isEnabled: canMoveToJunk
            ),
            Item(
                title: count > 1 ? "Delete \(count) Messages" : "Delete",
                action: .delete
            ),
            separator,
            Item(
                title: count > 1 ? "Archive \(count) Messages" : "Archive",
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

/// The exact pasteboard payload used for dragging messages to a mailbox.
enum MessageLinkPasteboard {
    static let type = "org.kayg.mailternal.message-links"

    static func encode(_ links: [String]) -> Data {
        (try? JSONEncoder().encode(links)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }
}

/// Reader state shown instead of a single-message detail when the list has a
/// multi-selection. Keeping this copy in a policy makes the state testable
/// without constructing a SwiftUI view.
enum MessageReaderStatePolicy {
    static func emptyStateTitle(selectionCount: Int) -> String? {
        selectionCount > 1 ? "\(selectionCount) Messages Selected" : nil
    }

    static func emptyStateDetail(selectionCount: Int) -> String? {
        selectionCount > 1 ? "Choose one message to read it." : nil
    }
}
