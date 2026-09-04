import Foundation
import MailternalInterfaces

/// Pure derivation and mutation rules for the cache settings tree.
///
/// The view deliberately keeps no policy of its own: an account checkbox is
/// the aggregate of its folders, and All is the aggregate of every folder.
/// Empty collections are unchecked, which also makes an empty cache tree
/// naturally non-actionable.
enum CacheTreePolicy {
    /// Groups folders by their owning account and sorts each account's folders
    /// by localized path so the cache tree has deterministic, account-local
    /// ordering.
    static func foldersByAccount(_ folders: [FolderSummary]) -> [AccountID: [FolderSummary]] {
        Dictionary(grouping: folders, by: \.accountID)
            .mapValues { accountFolders in
                accountFolders.sorted {
                    let pathOrder = $0.path.localizedStandardCompare($1.path)
                    if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
                    return $0.id.rawValue < $1.id.rawValue
                }
            }
    }

    enum State: Equatable, Sendable {
        case checked
        case mixed
        case unchecked

        var isChecked: Bool { self == .checked }

        /// Checked collections are cleared; mixed and unchecked collections
        /// fill so selecting an aggregate always selects every child.
        var toggledValue: Bool { self != .checked }
    }

    typealias CheckState = State
    typealias TriState = State

    static func state(forFlags values: [Bool]) -> State {
        guard let first = values.first else { return .unchecked }
        return values.dropFirst().contains(where: { $0 != first })
            ? .mixed
            : first ? .checked : .unchecked
    }

    static func state(for folders: [FolderSummary]) -> State {
        state(forFlags: folders.map(\.keepLocally))
    }

    static func accountState(for folders: [FolderSummary]) -> State {
        state(for: folders)
    }

    static func allState(for foldersByAccount: [AccountID: [FolderSummary]]) -> State {
        state(for: foldersByAccount.values.flatMap { $0 })
    }

    static func desiredValue(for state: State) -> Bool {
        state.toggledValue
    }

    /// Returns one write per folder for an account checkbox activation.
    static func folderUpdates(
        for state: State,
        folders: [FolderSummary]
    ) -> [FolderID: Bool] {
        let value = desiredValue(for: state)
        return Dictionary(uniqueKeysWithValues: folders.map { ($0.id, value) })
    }

    /// Returns one write per folder for an All checkbox activation.
    static func folderUpdates(
        for state: State,
        foldersByAccount: [AccountID: [FolderSummary]]
    ) -> [FolderID: Bool] {
        let folders = foldersByAccount.values.flatMap { $0 }
        return folderUpdates(for: state, folders: folders)
    }
    static func countCaption(for folder: FolderSummary) -> String {
        let cachedCount = folder.keepLocally ? folder.totalCount : 0
        return "\(cachedCount) / \(folder.totalCount)"
    }

    /// Folders with pending user toggles applied on top of the store's values.
    static func applyingPending(
        _ pending: [FolderID: Bool],
        to folders: [FolderSummary]
    ) -> [FolderSummary] {
        guard !pending.isEmpty else { return folders }
        return folders.map { folder in
            guard let keep = pending[folder.id], keep != folder.keepLocally else { return folder }
            var updated = folder
            updated.keepLocally = keep
            return updated
        }
    }
}
