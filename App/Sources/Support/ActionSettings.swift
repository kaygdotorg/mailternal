import AppKit
import Observation
import SwiftUI

enum SwipeEdge {
    case leading
    case trailing
}

enum SwipeActionKind: String, CaseIterable, Codable, Identifiable {
    case archive
    case trash
    case toggleRead
    case toggleFlag

    var id: Self { self }

    var title: String {
        switch self {
        case .archive: "Archive"
        case .trash: "Trash"
        case .toggleRead: "Read/Unread"
        case .toggleFlag: "Flag/Unflag"
        }
    }

    func title(isRead: Bool, isFlagged: Bool) -> String {
        switch self {
        case .archive: "Archive"
        case .trash: "Trash"
        case .toggleRead: isRead ? "Unread" : "Read"
        case .toggleFlag: isFlagged ? "Unflag" : "Flag"
        }
    }

    var systemImage: String {
        switch self {
        case .archive: "archivebox"
        case .trash: "trash"
        case .toggleRead: "envelope"
        case .toggleFlag: "flag"
        }
    }

    func systemImage(isRead: Bool, isFlagged: Bool) -> String {
        switch self {
        case .archive: "archivebox"
        case .trash: "trash"
        case .toggleRead: isRead ? "envelope.badge" : "envelope.open"
        case .toggleFlag: isFlagged ? "flag.slash" : "flag"
        }
    }

    var style: NSTableViewRowAction.Style {
        switch self {
        case .archive, .trash: .destructive
        case .toggleRead, .toggleFlag: .regular
        }
    }
    
    var backgroundColor: NSColor {
        switch self {
        case .archive: .systemYellow
        case .trash: .systemRed
        case .toggleRead: .systemBlue
        case .toggleFlag: .systemOrange
        }
    }
}

@MainActor
@Observable
final class ActionSettings {
    static let defaultLeadingSwipe: [SwipeActionKind] = [.toggleRead]
    static let defaultTrailingSwipe: [SwipeActionKind] = [.archive, .trash]
    static let leadingSwipeLimit = 2
    static let trailingSwipeLimit = 3

    var leadingSwipe: [SwipeActionKind] {
        didSet {
            let normalized = Self.compact(leadingSwipe, maxCount: Self.leadingSwipeLimit)
            if normalized != leadingSwipe {
                leadingSwipe = normalized
                return
            }
            guard oldValue != leadingSwipe else { return }
            persist(leadingSwipe, key: Keys.leading)
        }
    }

    var trailingSwipe: [SwipeActionKind] {
        didSet {
            let normalized = Self.compact(trailingSwipe, maxCount: Self.trailingSwipeLimit)
            if normalized != trailingSwipe {
                trailingSwipe = normalized
                return
            }
            guard oldValue != trailingSwipe else { return }
            persist(trailingSwipe, key: Keys.trailing)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedLeading = Self.decode(defaults.string(forKey: Keys.leading))
        let storedTrailing = Self.decode(defaults.string(forKey: Keys.trailing))
        leadingSwipe = Self.compact(
            storedLeading ?? Self.defaultLeadingSwipe,
            maxCount: Self.leadingSwipeLimit
        )
        trailingSwipe = Self.compact(
            storedTrailing ?? Self.defaultTrailingSwipe,
            maxCount: Self.trailingSwipeLimit
        )

        if storedLeading != nil {
            persist(leadingSwipe, key: Keys.leading)
        }
        if storedTrailing != nil {
            persist(trailingSwipe, key: Keys.trailing)
        }
    }

    func swipeActions(for edge: SwipeEdge) -> [SwipeActionKind] {
        switch edge {
        case .leading: leadingSwipe
        case .trailing: trailingSwipe
        }
    }

    func setSwipeAction(_ action: SwipeActionKind?, at index: Int, edge: SwipeEdge) {
        switch edge {
        case .leading:
            leadingSwipe = Self.applying(action, at: index, to: leadingSwipe, maxCount: Self.leadingSwipeLimit)
        case .trailing:
            trailingSwipe = Self.applying(action, at: index, to: trailingSwipe, maxCount: Self.trailingSwipeLimit)
        }
    }

    nonisolated static func compact(_ actions: [SwipeActionKind], maxCount: Int) -> [SwipeActionKind] {
        guard maxCount > 0 else { return [] }
        var seen = Set<SwipeActionKind>()
        return actions.reduce(into: []) { result, action in
            guard result.count < maxCount, seen.insert(action).inserted else { return }
            result.append(action)
        }
    }

    nonisolated static func applying(
        _ action: SwipeActionKind?,
        at index: Int,
        to actions: [SwipeActionKind],
        maxCount: Int
    ) -> [SwipeActionKind] {
        guard index >= 0 else { return compact(actions, maxCount: maxCount) }
        var updated = actions
        if let action {
            updated.removeAll { $0 == action }
            let insertionIndex = min(index, updated.count)
            updated.insert(action, at: insertionIndex)
        } else if index < updated.count {
            updated.remove(at: index)
        }
        return compact(updated, maxCount: maxCount)
    }

    private static func decode(_ value: String?) -> [SwipeActionKind]? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        guard let rawValues = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return rawValues.compactMap(SwipeActionKind.init(rawValue:))
    }

    private func persist(_ actions: [SwipeActionKind], key: String) {
        let rawValues = actions.map(\.rawValue)
        guard let data = try? JSONEncoder().encode(rawValues) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    private enum Keys {
        static let leading = "mailternal.actions.swipe.leading"
        static let trailing = "mailternal.actions.swipe.trailing"
    }
}
