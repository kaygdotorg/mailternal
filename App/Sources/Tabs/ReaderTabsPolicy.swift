import Foundation

/// Pure ordering rules for the reader tab strip. Keeping these decisions free of
/// Observation and AppKit makes the tab state deterministic and easy to test.
enum ReaderTabsPolicy {
    static func insertionIndex(tabCount: Int, activeIndex: Int?) -> Int {
        guard tabCount > 0 else { return 0 }
        guard let activeIndex else { return tabCount }
        return min(max(activeIndex + 1, 0), tabCount)
    }

    static func insertionIndex<T>(in tabs: [T], activeID: UUID?, id: (T) -> UUID) -> Int {
        insertionIndex(
            tabCount: tabs.count,
            activeIndex: activeID.flatMap { active in tabs.firstIndex { id($0) == active } }
        )
    }

    /// Chooses the next active tab after a close. MRU wins; order is only the
    /// deterministic fallback when a restored snapshot has no MRU entry.
    static func nextActiveAfterClosing(
        closedID: UUID,
        tabs: [ReaderTab],
        mru: [UUID]
    ) -> UUID? {
        let remaining = Set(tabs.map(\.id).filter { $0 != closedID })
        guard !remaining.isEmpty else { return nil }
        if let next = mru.first(where: { $0 != closedID && remaining.contains($0) }) {
            return next
        }
        return tabs.first(where: { $0.id != closedID })?.id
    }

    static func closeOthers<T>(in tabs: [T], keeping id: UUID, idOf: (T) -> UUID) -> [T] {
        tabs.filter { idOf($0) == id }
    }

    static func closeToRight<T>(in tabs: [T], of id: UUID, idOf: (T) -> UUID) -> [T] {
        guard let index = tabs.firstIndex(where: { idOf($0) == id }) else { return tabs }
        return Array(tabs.prefix(index + 1))
    }

    /// The last reader-tab close also closes the main window on the same
    /// command invocation. An empty reader reached by any other route may
    /// leave the window open, so callers evaluate this after removing a tab.
    static func shouldCloseWindow(afterClosingTabsRemaining count: Int) -> Bool {
        count == 0
    }

    static func movedIndex(from oldIndex: Int, to requestedIndex: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(requestedIndex, 0), count - 1)
    }

    /// Converts a tab-bar drop on `targetIndex` into the destination index
    /// after removing the source. Removing an earlier source shifts the target
    /// left by one; doing this at the policy seam keeps drag geometry thin.
    static func dropDestination(
        sourceIndex: Int,
        targetIndex: Int,
        afterTarget: Bool,
        count: Int
    ) -> Int {
        guard sourceIndex != targetIndex else { return sourceIndex }
        let requested = afterTarget ? targetIndex + 1 : targetIndex
        let adjusted = sourceIndex < targetIndex ? requested - 1 : requested
        return movedIndex(from: sourceIndex, to: adjusted, count: count)
    }

    static func adjacentID<T>(in tabs: [T], activeID: UUID?, forward: Bool, id: (T) -> UUID) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        guard let activeID, let index = tabs.firstIndex(where: { id($0) == activeID }) else {
            return id(tabs[0])
        }
        let offset = forward ? 1 : -1
        let next = (index + offset + tabs.count) % tabs.count
        return id(tabs[next])
    }
}
