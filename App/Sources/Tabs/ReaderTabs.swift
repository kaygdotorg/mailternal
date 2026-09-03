import Foundation
import Observation
import MailternalInterfaces

/// Main-window reader tabs. Detached message windows intentionally do not use
/// this state object.
@Observable
final class ReaderTabs {
    var tabs: [ReaderTab]
    var activeID: UUID?
    @ObservationIgnored var onChange: (() -> Void)?

    private(set) var mruIDs: [UUID]
    @ObservationIgnored private var scrollOffsets: [UUID: CGFloat]

    var active: ReaderTab? {
        guard let activeID else { return nil }
        return tabs.first { $0.id == activeID }
    }

    init(
        tabs: [ReaderTab] = [],
        activeID: UUID? = nil,
        mruIDs: [UUID] = [],
        scrollOffsets: [UUID: CGFloat] = [:]
    ) {
        var unique: [ReaderTab] = []
        var foundTransient = false
        for tab in tabs {
            if let duplicateIndex = unique.firstIndex(where: { $0.message == tab.message }) {
                // A permanent record wins over a transient duplicate while
                // retaining the first record's strip position.
                if unique[duplicateIndex].isTransient && !tab.isTransient {
                    unique[duplicateIndex] = tab
                }
                continue
            }
            guard !tab.isTransient || !foundTransient else { continue }
            unique.append(tab)
            foundTransient = foundTransient || tab.isTransient
        }
        self.tabs = unique
        self.scrollOffsets = scrollOffsets.filter { entry in
            unique.contains { tab in tab.id == entry.key }
        }
        let validIDs = Set(unique.map(\.id))
        var normalizedMRU: [UUID] = []
        for id in mruIDs where validIDs.contains(id) && !normalizedMRU.contains(id) {
            normalizedMRU.append(id)
        }
        for id in unique.map(\.id) where !normalizedMRU.contains(id) {
            normalizedMRU.append(id)
        }
        self.mruIDs = normalizedMRU
        self.activeID = activeID.flatMap { validIDs.contains($0) ? $0 : nil }
            ?? normalizedMRU.first
            ?? unique.first?.id
    }

    func open(_ message: MessageID, permanent: Bool) {
        if let existingIndex = tabs.firstIndex(where: { $0.message == message }) {
            let id = tabs[existingIndex].id
            let promoted = permanent && tabs[existingIndex].isTransient
            if promoted {
                tabs[existingIndex].isTransient = false
            }
            activate(id)
            if promoted { notify() }
            return
        }

        if !permanent, let transientIndex = tabs.firstIndex(where: \.isTransient) {
            let tab = tabs[transientIndex]
            tabs[transientIndex].message = message
            scrollOffsets.removeValue(forKey: tab.id)
            activate(tab.id)
            notify()
            return
        }

        let tab = ReaderTab(id: UUID(), message: message, isTransient: !permanent)
        let index = ReaderTabsPolicy.insertionIndex(in: tabs, activeID: activeID, id: \.id)
        tabs.insert(tab, at: index)
        activeID = tab.id
        touchMRU(tab.id)
        notify()
    }

    func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let changed = activeID != id || mruIDs.first != id
        activeID = id
        touchMRU(id)
        if changed { notify() }
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeID == id
        let next = wasActive
            ? ReaderTabsPolicy.nextActiveAfterClosing(closedID: id, tabs: tabs, mru: mruIDs)
            : activeID
        tabs.remove(at: index)
        mruIDs.removeAll { $0 == id }
        scrollOffsets.removeValue(forKey: id)
        activeID = next.flatMap { candidate in tabs.contains { $0.id == candidate } ? candidate : nil }
            ?? tabs.first?.id
        if wasActive, let activeID { touchMRU(activeID) }
        notify()
    }

    func closeOthers(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let removed = tabs.filter { $0.id != id }.map(\.id)
        tabs = tabs.filter { $0.id == id }
        removed.forEach { scrollOffsets.removeValue(forKey: $0) }
        activeID = id
        mruIDs = [id]
        notify()
    }

    func closeToRight(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.suffix(from: index + 1).map(\.id)
        guard !removed.isEmpty else { return }
        tabs = ReaderTabsPolicy.closeToRight(in: tabs, of: id, idOf: \.id)
        removed.forEach { scrollOffsets.removeValue(forKey: $0) }
        mruIDs.removeAll { removed.contains($0) }
        if activeID.map({ removed.contains($0) }) == true {
            activeID = id
            touchMRU(id)
        }
        notify()
    }

    func keep(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isTransient else { return }
        tabs[index].isTransient = false
        notify()
    }

    func move(_ id: UUID, to index: Int) {
        guard let oldIndex = tabs.firstIndex(where: { $0.id == id }), tabs.count > 1 else { return }
        let destination = ReaderTabsPolicy.movedIndex(from: oldIndex, to: index, count: tabs.count)
        guard destination != oldIndex else { return }
        let tab = tabs.remove(at: oldIndex)
        tabs.insert(tab, at: destination)
        notify()
    }

    func activateNext() {
        guard let id = ReaderTabsPolicy.adjacentID(in: tabs, activeID: activeID, forward: true, id: \.id) else { return }
        activate(id)
    }

    func activatePrevious() {
        guard let id = ReaderTabsPolicy.adjacentID(in: tabs, activeID: activeID, forward: false, id: \.id) else { return }
        activate(id)
    }

    @discardableResult
    func messageRemoved(_ message: MessageID) -> Bool {
        guard let id = tabs.first(where: { $0.message == message })?.id else { return false }
        close(id)
        return true
    }

    func scrollOffset(for id: UUID) -> CGFloat {
        scrollOffsets[id] ?? 0
    }

    func setScrollOffset(_ y: CGFloat, for id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard scrollOffsets[id] != y else { return }
        scrollOffsets[id] = y
        notify()
    }

    func snapshot(links: [UUID: String]) -> ReaderTabsSnapshot {
        ReaderTabsSnapshot(
            tabs: tabs.compactMap { tab in
                guard let link = links[tab.id] else { return nil }
                return .init(
                    id: tab.id,
                    link: link,
                    isTransient: tab.isTransient,
                    scrollOffset: scrollOffset(for: tab.id)
                )
            },
            activeID: activeID,
            mruIDs: mruIDs
        )
    }

    /// Replaces state after resolving persisted deep links. Invalid links are
    /// omitted by the caller; this method still enforces all tab invariants.
    func restore(
        _ snapshot: ReaderTabsSnapshot,
        messagesByTabID: [UUID: MessageID]
    ) {
        let restored = snapshot.tabs.compactMap { entry -> ReaderTab? in
            guard let message = messagesByTabID[entry.id] else { return nil }
            return ReaderTab(id: entry.id, message: message, isTransient: entry.isTransient)
        }
        let normalized = ReaderTabs(
            tabs: restored,
            activeID: snapshot.activeID,
            mruIDs: snapshot.mruIDs,
            scrollOffsets: Dictionary(uniqueKeysWithValues: snapshot.tabs.compactMap { entry in
                messagesByTabID[entry.id] == nil ? nil : (entry.id, entry.scrollOffset)
            })
        )
        tabs = normalized.tabs
        activeID = normalized.activeID
        mruIDs = normalized.mruIDs
        scrollOffsets = Dictionary(uniqueKeysWithValues: snapshot.tabs.compactMap { entry in
            normalized.tabs.contains { $0.id == entry.id } ? (entry.id, entry.scrollOffset) : nil
        })
        notify()
    }

    private func touchMRU(_ id: UUID) {
        mruIDs.removeAll { $0 == id }
        mruIDs.insert(id, at: 0)
    }

    private func notify() {
        onChange?()
    }
}

struct ReaderTab: Identifiable, Hashable, Codable {
    let id: UUID
    var message: MessageID
    var isTransient: Bool

    init(id: UUID = UUID(), message: MessageID, isTransient: Bool) {
        self.id = id
        self.message = message
        self.isTransient = isTransient
    }
}
