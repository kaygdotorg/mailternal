import Foundation
import Observation
import MailternalInterfaces
#if canImport(CloudKit)
import CloudKit
import CryptoKit
#endif

/// A customization family that can participate in workspace synchronization.
public enum WorkspaceSyncCategory: String, Codable, CaseIterable, Sendable {
    case workspace
    case appearance
    case actions
}

/// The side to retain when a category has divergent local and iCloud values.
public enum WorkspaceSyncChoice: Sendable {
    case local
    case cloud
}

/// A setting value that is safe to persist and synchronize.
///
/// Values are atomic per key. In particular, column order is represented by one
/// value rather than by independently merged column entries, so a consumer can
/// apply a complete order without observing a partially updated arrangement.
public enum WorkspaceSyncValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case data(Data)

    private enum CodingKeys: String, CodingKey {
        case kind
        case string
        case bool
        case integer
        case number
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode("string", forKey: .kind)
            try container.encode(value, forKey: .string)
        case .bool(let value):
            try container.encode("bool", forKey: .kind)
            try container.encode(value, forKey: .bool)
        case .integer(let value):
            try container.encode("integer", forKey: .kind)
            try container.encode(value, forKey: .integer)
        case .number(let value):
            try container.encode("number", forKey: .kind)
            try container.encode(value, forKey: .number)
        case .data(let value):
            try container.encode("data", forKey: .kind)
            try container.encode(value, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "string":
            self = .string(try container.decode(String.self, forKey: .string))
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case "integer":
            self = .integer(try container.decode(Int.self, forKey: .integer))
        case "number":
            self = .number(try container.decode(Double.self, forKey: .number))
        case "data":
            self = .data(try container.decode(Data.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown workspace sync value kind"
            )
        }
    }
}

/// One validated setting in a pairing import batch.
///
/// Pairing imports use one local commit for the complete batch. CloudKit
/// synchronization is intentionally a separate, non-blocking step so an
/// offline device can acknowledge durable local work.
public struct WorkspaceSyncImportValue: Sendable {
    public let key: String
    public let value: WorkspaceSyncValue
    public let category: WorkspaceSyncCategory

    public init(
        key: String,
        value: WorkspaceSyncValue,
        category: WorkspaceSyncCategory
    ) {
        self.key = key
        self.value = value
        self.category = category
    }
}


/// Errors surfaced by the durable workspace synchronization engine.
public enum WorkspaceSyncError: Error, LocalizedError, Sendable {
    case invalidContainerIdentifier
    case invalidKey
    case duplicateKeyAcrossCategories(String)
    case persistenceFailed(String)
    case cloudKitUnavailable
    case cloudKit(String)
    case malformedRecord(String)
    case conflictNotPending(WorkspaceSyncCategory)

    public var errorDescription: String? {
        switch self {
        case .invalidContainerIdentifier:
            return "The iCloud container identifier is invalid."
        case .invalidKey:
            return "Workspace sync keys must be non-empty and no longer than 4096 UTF-8 bytes."
        case .duplicateKeyAcrossCategories(let key):
            return "Workspace sync key '\(key)' is already assigned to another category."
        case .persistenceFailed(let message):
            return "Unable to persist workspace sync state: \(message)"
        case .cloudKitUnavailable:
            return "CloudKit is unavailable in this build."
        case .cloudKit(let message):
            return "iCloud workspace sync failed: \(message)"
        case .malformedRecord(let message):
            return "The iCloud workspace record is invalid: \(message)"
        case .conflictNotPending(let category):
            return "There is no pending \(category.rawValue) workspace conflict to resolve."
        }
    }
}

/// Durable iCloud synchronization for workspace, appearance, and action settings.
///
/// The controller owns only synchronization state. A consumer observes `values`
/// and decides how to apply received settings; a received value is never treated
/// as a new local edit. The state file contains no secrets or mailbox
/// credentials. AccountLinkID values may appear in non-secret shared workspace
/// keys. The supplied URL is a file URL in the app's durable support
/// directory, and the supplied container identifier must be backed by the same
/// CloudKit container entitlement on every participating Apple target.
@MainActor
@Observable
public final class WorkspaceSyncController {
    private static let stateVersion = 1
    private static let recordType = "MailternalWorkspaceSetting"
    private static let maxKeyBytes = 4_096
    private static let pageSize = 100
    private static let modifyBatchSize = 400

    private enum RecordField {
        static let schemaVersion = "schemaVersion"
        static let category = "category"
        static let key = "key"
        static let deleted = "deleted"
        static let value = "value"
        static let editTimestamp = "editTimestamp"
        static let deviceID = "deviceID"
    }

    private struct EditVersion: Codable, Equatable {
        var timestamp: Date
        var deviceID: String
    }

    private struct EntryID: Hashable, Codable, Comparable {
        var category: WorkspaceSyncCategory
        var key: String

        static func < (lhs: EntryID, rhs: EntryID) -> Bool {
            if lhs.category.rawValue != rhs.category.rawValue {
                return lhs.category.rawValue < rhs.category.rawValue
            }
            return lhs.key < rhs.key
        }
    }

    private struct PersistedEntry: Codable, Equatable {
        var category: WorkspaceSyncCategory
        var key: String
        var localValue: WorkspaceSyncValue?
        var localVersion: EditVersion?
        var cloudValue: WorkspaceSyncValue?
        var cloudVersion: EditVersion?

        var id: EntryID { EntryID(category: category, key: key) }
    }

    private struct PersistedQueueItem: Codable, Equatable {
        var category: WorkspaceSyncCategory
        var key: String

        var id: EntryID { EntryID(category: category, key: key) }
    }

    private struct PersistedState: Codable {
        var version: Int
        var deviceID: String
        var cloudAccountID: String?
        var isEnabled: Bool
        var enabledCategories: Set<WorkspaceSyncCategory>
        var pendingConflicts: Set<WorkspaceSyncCategory>
        var categoriesRequiringChoice: Set<WorkspaceSyncCategory>
        var lastEditAt: Date?
        var lastSync: Date?
        var entries: [PersistedEntry]
        var queue: [PersistedQueueItem]
    }

    private struct State: Equatable {
        var deviceID: String
        var isEnabled: Bool
        var cloudAccountID: String?
        var enabledCategories: Set<WorkspaceSyncCategory>
        var pendingConflicts: Set<WorkspaceSyncCategory>
        var categoriesRequiringChoice: Set<WorkspaceSyncCategory>
        var lastEditAt: Date?
        var lastSync: Date?
        var entries: [EntryID: PersistedEntry]
        var queue: Set<EntryID>
    }

    private enum ReplicatedState: Equatable {
        case absent
        case tombstone
        case value(WorkspaceSyncValue)
    }

    private struct RemoteEntry {
        var id: EntryID
        var value: WorkspaceSyncValue?
        var version: EditVersion
        #if canImport(CloudKit)
        var record: CKRecord
        #endif
    }

    private struct SaveOutcome {
        var saved: Set<EntryID> = []
        var failure: String?
    }

    private var state: State
    private let storageURL: URL
    private let containerIdentifier: String
    private var revision: UInt64 = 0
    @ObservationIgnored private var syncTask: Task<Void, Error>?
    private var syncRequested = false

    /// Whether this device participates in workspace synchronization.
    public private(set) var isEnabled: Bool
    /// Categories this device has selected for synchronization.
    public private(set) var enabledCategories: Set<WorkspaceSyncCategory>
    /// Categories whose local and cloud values await an explicit choice.
    public private(set) var pendingConflicts: Set<WorkspaceSyncCategory>
    /// Most recent synchronization or persistence error, suitable for a UI.
    public private(set) var lastError: String?
    /// Time at which the last complete synchronization was durably recorded.
    public private(set) var lastSync: Date?
    /// Locally selected values, including values received from iCloud after adoption.
    public private(set) var values: [String: WorkspaceSyncValue]

    /// Creates a controller backed by `storageURL` and a private CloudKit database.
    ///
    /// Construction is intentionally non-throwing so a settings screen can still
    /// open when an old state file is damaged. Such a failure is exposed through
    /// `lastError`; the damaged file is not overwritten until a successful edit
    /// is made.
    public init(storageURL: URL, containerIdentifier: String) {
        self.storageURL = storageURL
        self.containerIdentifier = containerIdentifier

        let loaded: State
        var loadError: String?
        do {
            loaded = try Self.loadState(from: storageURL)
            loadError = nil
        } catch {
            loaded = State(
                deviceID: UUID().uuidString.lowercased(),
                isEnabled: false,
                enabledCategories: Set(WorkspaceSyncCategory.allCases),
                pendingConflicts: [],
                categoriesRequiringChoice: [],
                lastEditAt: nil,
                lastSync: nil,
                entries: [:],
                queue: []
            )
            loadError = "Unable to load workspace sync state: \(Self.describe(error))"
        }

        self.state = loaded
        self.isEnabled = loaded.isEnabled
        self.enabledCategories = loaded.enabledCategories
        self.pendingConflicts = loaded.pendingConflicts
        self.lastError = loadError
        self.lastSync = loaded.lastSync
        self.values = Self.publicValues(from: loaded.entries)
    }

    /// Enables or disables the per-device master switch.
    ///
    /// Disabling is local-only: local values, cloud snapshots, and the outgoing
    /// queue remain intact. Re-enabling performs a fresh fetch for every selected
    /// category and records conflicts before either side is adopted.
    public func setEnabled(_ enabled: Bool) async throws {
        guard enabled != state.isEnabled else {
            if enabled {
                do {
                    try await synchronizeThrowing()
                } catch {
                    record(error)
                    throw error
                }
            }
            return
        }

        var candidate = state
        candidate.isEnabled = enabled
        if enabled {
            candidate.categoriesRequiringChoice.formUnion(candidate.enabledCategories)
        }
        try commit(candidate)

        guard enabled else { return }
        do {
            try await synchronizeThrowing()
        } catch {
            record(error)
            throw error
        }
    }

    /// Enables or disables one synchronization category on this device.
    ///
    /// Re-enabling a category fetches its authoritative private-database state.
    /// A differing category with an explicit local state is left untouched and
    /// appears in `pendingConflicts` until `resolve(_:using:)` is called.
    public func setCategory(
        _ category: WorkspaceSyncCategory,
        enabled: Bool
    ) async throws {
        guard enabled != state.enabledCategories.contains(category) else {
            if enabled, state.isEnabled {
                do {
                    try await synchronizeThrowing()
                } catch {
                    record(error)
                    throw error
                }
            }
            return
        }

        var candidate = state
        if enabled {
            candidate.enabledCategories.insert(category)
            candidate.categoriesRequiringChoice.insert(category)
        } else {
            candidate.enabledCategories.remove(category)
            candidate.pendingConflicts.remove(category)
            candidate.categoriesRequiringChoice.insert(category)
        }
        try commit(candidate)

        guard enabled, state.isEnabled else { return }
        do {
            try await synchronizeThrowing()
        } catch {
            record(error)
            throw error
        }
    }

    /// Resolves a pending category conflict and performs the chosen transition.
    ///
    /// Choosing `.local` versions only divergent local keys (and creates a
    /// tombstone for a cloud-only key), then queues those records for iCloud.
    /// Choosing `.cloud` adopts the fetched cloud snapshot without creating an
    /// edit and drops local-only keys. Persistence happens before publication;
    /// an iCloud failure leaves the chosen local state and queue durable.
    public func resolve(
        _ category: WorkspaceSyncCategory,
        using choice: WorkspaceSyncChoice
    ) async throws {
        guard state.pendingConflicts.contains(category) else {
            let error = WorkspaceSyncError.conflictNotPending(category)
            record(error)
            throw error
        }

        var candidate = state
        let ids = Set(candidate.entries.keys.filter { $0.category == category })
        for id in ids.sorted() {
            guard var entry = candidate.entries[id] else { continue }
            switch choice {
            case .local:
                guard Self.localState(entry) != Self.cloudState(entry) else {
                    reconcileMatchingEntry(id, in: &candidate)
                    continue
                }
                let version = nextEditVersion(for: id, in: &candidate)
                entry.localVersion = version
                // A missing local entry means local absence. The only durable
                // representation that can make cloud match that choice is a
                // category-scoped tombstone. `localValue == nil` is that tombstone.
                candidate.entries[id] = entry
                candidate.queue.insert(id)
            case .cloud:
                guard let cloudVersion = entry.cloudVersion else {
                    candidate.entries.removeValue(forKey: id)
                    candidate.queue.remove(id)
                    continue
                }
                entry.localVersion = cloudVersion
                entry.localValue = entry.cloudValue
                candidate.entries[id] = entry
                candidate.queue.remove(id)
            }
        }

        candidate.pendingConflicts.remove(category)
        candidate.categoriesRequiringChoice.remove(category)
        try commit(candidate)

        guard state.isEnabled, state.enabledCategories.contains(category) else { return }
        do {
            try await synchronizeThrowing()
        } catch {
            record(error)
            throw error
        }
    }

    /// Persists one local value or category-specific deletion tombstone.
    ///
    /// The edit is visible immediately after durable local persistence. If the
    /// category participates, synchronization is attempted next; CloudKit
    /// failures are thrown and the outgoing edit remains queued for retry.
    public func setValue(
        _ value: WorkspaceSyncValue?,
        for key: String,
        category: WorkspaceSyncCategory
    ) async throws {
        guard Self.isValidKey(key) else {
            let error = WorkspaceSyncError.invalidKey
            record(error)
            throw error
        }
        let id = EntryID(category: category, key: key)
        guard !state.entries.keys.contains(where: { $0.key == key && $0.category != category }) else {
            let error = WorkspaceSyncError.duplicateKeyAcrossCategories(key)
            record(error)
            throw error
        }

        var candidate = state
        var entry = candidate.entries[id] ?? PersistedEntry(
            category: category,
            key: key,
            localValue: nil,
            localVersion: nil,
            cloudValue: nil,
            cloudVersion: nil
        )
        guard entry.localVersion == nil || entry.localValue != value else { return }
        entry.localValue = value
        entry.localVersion = nextEditVersion(for: id, in: &candidate)
        candidate.entries[id] = entry
        candidate.queue.insert(id)
        try commit(candidate)

        guard state.isEnabled,
              state.enabledCategories.contains(category),
              !state.pendingConflicts.contains(category)
        else { return }

        do {
            try await synchronizeThrowing()
        } catch {
            record(error)
            throw error
        }
    }

    /// Commits a complete pairing settings batch locally without contacting
    /// CloudKit. Each accepted value is queued for a later synchronization;
    /// callers should launch `synchronize()` after this method returns.
    ///
    /// Validation happens before the single durable commit, so malformed input
    /// cannot leave a partially imported settings map.
    public func importLocalValues(_ imports: [WorkspaceSyncImportValue]) async throws {
        guard !imports.isEmpty else { return }
        var categoriesByKey: [String: WorkspaceSyncCategory] = [:]

        for item in imports {
            guard Self.isValidKey(item.key) else {
                throw WorkspaceSyncError.invalidKey
            }
            guard categoriesByKey[item.key] == nil else {
                throw WorkspaceSyncError.persistenceFailed(
                    "Duplicate workspace setting key \(item.key)"
                )
            }
            categoriesByKey[item.key] = item.category
        }
        if let conflict = state.entries.keys.first(where: { id in
            categoriesByKey[id.key].map { $0 != id.category } ?? false
        }) {
            throw WorkspaceSyncError.duplicateKeyAcrossCategories(conflict.key)
        }

        var candidate = state
        for item in imports.sorted(by: {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.key < $1.key
        }) {
            let id = EntryID(category: item.category, key: item.key)
            var entry = candidate.entries[id] ?? PersistedEntry(
                category: item.category,
                key: item.key,
                localValue: nil,
                localVersion: nil,
                cloudValue: nil,
                cloudVersion: nil
            )
            guard entry.localVersion == nil || entry.localValue != item.value else { continue }
            entry.localValue = item.value
            entry.localVersion = nextEditVersion(for: id, in: &candidate)
            candidate.entries[id] = entry
            candidate.queue.insert(id)
        }
        guard candidate != state else { return }
        try Task.checkCancellation()
        try commit(candidate)
    }

    /// Replaces one account's local shared-workspace identity with the
    /// transferred canonical link. Layout keys and canonical reading links are
    /// migrated without touching mailbox rows, messages, or attachment data.
    ///
    /// The old account-scoped keys receive durable tombstones so a stale
    /// CloudKit record cannot be adopted back under the old identity. Both the
    /// migrated values and those tombstones are queued for the next sync.
    public func remapAccountLinkID(
        from source: AccountLinkID,
        to destination: AccountLinkID
    ) async throws {
        guard source != destination else { return }
        try Task.checkCancellation()

        let entries = state.entries.values.sorted { $0.id < $1.id }
        var targetIDs: [EntryID: EntryID] = [:]
        for entry in entries {
            guard let remappedKey = MailListLayoutStore.remappedAccountLinkID(
                in: entry.key,
                from: source,
                to: destination
            ) else { continue }
            let target = EntryID(category: entry.category, key: remappedKey)
            guard target != entry.id else { continue }
            guard !state.entries.keys.contains(where: {
                $0.key == remappedKey && $0.category != entry.category
            }) else {
                throw WorkspaceSyncError.duplicateKeyAcrossCategories(remappedKey)
            }
            targetIDs[entry.id] = target
        }

        var candidate = state
        for entry in entries {
            let remappedKey = targetIDs[entry.id]?.key ?? entry.key
            let localValue = Self.remappedWorkspaceValue(
                entry.localValue,
                from: source,
                to: destination
            )
            let cloudValue = Self.remappedWorkspaceValue(
                entry.cloudValue,
                from: source,
                to: destination
            )
            let keyChanged = remappedKey != entry.key
            let localChanged = localValue != entry.localValue
            let cloudChanged = cloudValue != entry.cloudValue
            guard keyChanged || localChanged || cloudChanged else { continue }

            if keyChanged {
                candidate.entries.removeValue(forKey: entry.id)

                var tombstone = entry
                tombstone.localValue = nil
                tombstone.localVersion = nextEditVersion(
                    for: entry.id,
                    in: &candidate
                )
                // The old key must retain its old cloud snapshot so its
                // deletion can be written with the correct optimistic version.
                candidate.entries[entry.id] = tombstone
                candidate.queue.insert(entry.id)

                let target = targetIDs[entry.id]!
                // A retry encounters the old key's migration tombstone.
                // Preserve an explicit canonical value/reset rather than
                // overwriting it with that tombstone.
                if candidate.entries[target]?.localVersion != nil {
                    continue
                }
                var migrated = entry
                migrated.key = target.key
                if entry.localVersion != nil {
                    // Carry an explicit local value or tombstone to the
                    // canonical identity; neither may resurrect stale cloud
                    // state under the new key.
                    migrated.localValue = localValue
                    migrated.localVersion = nextEditVersion(
                        for: target,
                        in: &candidate
                    )
                    migrated.cloudValue = nil
                    migrated.cloudVersion = nil
                    candidate.entries[target] = migrated
                    candidate.queue.insert(target)
                    continue
                }
                guard let cloudValue else {
                    continue
                }
                migrated.localValue = cloudValue
                migrated.localVersion = nextEditVersion(
                    for: target,
                    in: &candidate
                )
                migrated.cloudValue = nil
                migrated.cloudVersion = nil
                candidate.entries[target] = migrated
                candidate.queue.insert(target)
                continue
            }

            var updated = entry
            if localChanged, entry.localVersion != nil {
                updated.localValue = localValue
                updated.localVersion = nextEditVersion(
                    for: entry.id,
                    in: &candidate
                )
                candidate.queue.insert(entry.id)
            } else if entry.localVersion != nil,
                      cloudChanged,
                      entry.localValue != nil {
                // The local value is already canonical, but the remembered
                // cloud snapshot still uses the old spelling. Requeue it so a
                // subsequent fetch cannot win with that stale identity.
                updated.localVersion = nextEditVersion(
                    for: entry.id,
                    in: &candidate
                )
                updated.cloudValue = nil
                updated.cloudVersion = nil
                candidate.queue.insert(entry.id)
            } else if entry.localVersion == nil,
                      cloudChanged,
                      let cloudValue {
                // Promote a cloud-only link rewrite to a local edit so
                // the canonical value is uploaded instead of being
                // re-adopted from the old remote snapshot.
                updated.localValue = cloudValue
                updated.localVersion = nextEditVersion(
                    for: entry.id,
                    in: &candidate
                )
                updated.cloudValue = nil
                updated.cloudVersion = nil
                candidate.queue.insert(entry.id)
            } else if cloudChanged, updated.cloudVersion != nil,
                      updated.localVersion == nil {
                updated.cloudValue = cloudValue
            }
            candidate.entries[entry.id] = updated
        }

        guard candidate != state else { return }
        try Task.checkCancellation()
        try commit(candidate)
    }


    /// Synchronizes selected categories without interrupting the caller.
    ///
    /// This method reports network, account, entitlement, malformed-record, and
    /// persistence failures in `lastError`; it never drops queued edits. Callers
    /// that need a throwing operation boundary can use any mutating method, which
    /// performs the same synchronization and rethrows its error.
    public func synchronize() async {
        do {
            try await synchronizeThrowing()
        } catch is CancellationError {
            return
        } catch {
            record(error)
        }
    }

    private func synchronizeThrowing() async throws {
        syncRequested = true
        if let syncTask {
            try await syncTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            try await self.runSynchronization()
        }
        syncTask = task
        try await task.value
    }

    private func runSynchronization() async throws {
        while syncRequested {
            try Task.checkCancellation()
            syncRequested = false
            guard state.isEnabled else { continue }
            #if canImport(CloudKit)
            try await prepareCloudAccount()
            #endif

            let categories = state.enabledCategories
                .sorted { $0.rawValue < $1.rawValue }
            for category in categories {
                try Task.checkCancellation()
                try await synchronizeCategory(category)
            }

            guard state.isEnabled else { continue }
            var candidate = state
            candidate.lastSync = Date()
            if candidate != state {
                try commit(candidate)
            }
        }
    }

    private func synchronizeCategory(_ category: WorkspaceSyncCategory) async throws {
        while true {
            try Task.checkCancellation()
            guard state.isEnabled, state.enabledCategories.contains(category) else { return }
            let startRevision = revision
            let remote = try await fetchRemote(category: category)
            guard state.isEnabled, state.enabledCategories.contains(category) else { return }
            guard startRevision == revision else {
                syncRequested = true
                return
            }

            var candidate = state
            try merge(remote: remote, category: category, into: &candidate)
            if candidate != state {
                try commit(candidate)
            }
            guard state.isEnabled,
                  state.enabledCategories.contains(category),
                  !state.pendingConflicts.contains(category)
            else { return }

            let uploadRevision = revision
            let outcome = try await saveQueued(category: category, remote: remote)
            guard uploadRevision == revision else { continue }

            if !outcome.saved.isEmpty {
                var uploaded = state
                for id in outcome.saved {
                    guard var entry = uploaded.entries[id],
                          let localVersion = entry.localVersion
                    else { continue }
                    entry.cloudVersion = localVersion
                    entry.cloudValue = entry.localValue
                    uploaded.entries[id] = entry
                    uploaded.queue.remove(id)
                }
                try commit(uploaded)
            }
            if let failure = outcome.failure {
                throw WorkspaceSyncError.cloudKit(failure)
            }
            return
        }
    }

    private func merge(
        remote: [EntryID: RemoteEntry],
        category: WorkspaceSyncCategory,
        into candidate: inout State
    ) throws {
        let existingIDs = candidate.entries.keys.filter { $0.category == category }
        for id in existingIDs {
            guard var entry = candidate.entries[id] else { continue }
            entry.cloudValue = nil
            entry.cloudVersion = nil
            candidate.entries[id] = entry
        }
        for id in remote.keys where candidate.entries.keys.contains(where: {
            $0.key == id.key && $0.category != category
        }) {
            throw WorkspaceSyncError.duplicateKeyAcrossCategories(id.key)
        }
        for (id, remoteEntry) in remote {
            if var entry = candidate.entries[id] {
                entry.cloudValue = remoteEntry.value
                entry.cloudVersion = remoteEntry.version
                candidate.entries[id] = entry
            } else {
                candidate.entries[id] = PersistedEntry(
                    category: id.category,
                    key: id.key,
                    localValue: nil,
                    localVersion: nil,
                    cloudValue: remoteEntry.value,
                    cloudVersion: remoteEntry.version
                )
            }
        }

        let ids = Set(candidate.entries.keys.filter { $0.category == category })
        let requiresChoice = candidate.categoriesRequiringChoice.contains(category)
        let categoryAlreadyPending = candidate.pendingConflicts.contains(category)
        let hasExplicitLocalState = ids.contains { candidate.entries[$0]?.localVersion != nil }
        let differs = ids.contains { id in
            guard let entry = candidate.entries[id] else { return false }
            return Self.localState(entry) != Self.cloudState(entry)
        }

        if categoryAlreadyPending {
            if !differs {
                candidate.pendingConflicts.remove(category)
                candidate.categoriesRequiringChoice.remove(category)
                reconcileMatchingEntries(ids, in: &candidate)
            }
            return
        }

        if requiresChoice && differs && hasExplicitLocalState {
            candidate.pendingConflicts.insert(category)
            candidate.categoriesRequiringChoice.remove(category)
            return
        }

        for id in ids.sorted() {
            guard let entry = candidate.entries[id] else { continue }
            let local = Self.localState(entry)
            let cloud = Self.cloudState(entry)
            guard local != cloud else {
                reconcileMatchingEntry(id, in: &candidate)
                continue
            }

            guard let localVersion = entry.localVersion else {
                adoptCloud(id, in: &candidate)
                continue
            }
            guard let cloudVersion = entry.cloudVersion else {
                candidate.queue.insert(id)
                continue
            }

            switch Self.compare(localVersion, cloudVersion) {
            case .orderedDescending:
                candidate.queue.insert(id)
            case .orderedAscending:
                adoptCloud(id, in: &candidate)
            case .orderedSame:
                if Self.compareTie(local, cloud) == .orderedDescending {
                    candidate.queue.insert(id)
                } else {
                    adoptCloud(id, in: &candidate)
                }
            }
        }
        candidate.pendingConflicts.remove(category)
        candidate.categoriesRequiringChoice.remove(category)
        removeEmptyEntries(in: &candidate)
    }

    private func reconcileMatchingEntries(
        _ ids: Set<EntryID>,
        in candidate: inout State
    ) {
        for id in ids.sorted() {
            reconcileMatchingEntry(id, in: &candidate)
        }
        removeEmptyEntries(in: &candidate)
    }

    private func reconcileMatchingEntry(_ id: EntryID, in candidate: inout State) {
        guard let entry = candidate.entries[id] else { return }
        guard let localVersion = entry.localVersion else {
            if entry.cloudVersion != nil {
                adoptCloud(id, in: &candidate)
            }
            return
        }
        guard let cloudVersion = entry.cloudVersion else {
            candidate.queue.insert(id)
            return
        }
        switch Self.compare(localVersion, cloudVersion) {
        case .orderedAscending:
            adoptCloud(id, in: &candidate)
        case .orderedDescending:
            candidate.queue.insert(id)
        case .orderedSame:
            candidate.queue.remove(id)
        }
    }

    private func adoptCloud(_ id: EntryID, in candidate: inout State) {
        guard let entry = candidate.entries[id],
              let cloudVersion = entry.cloudVersion
        else {
            candidate.entries.removeValue(forKey: id)
            candidate.queue.remove(id)
            return
        }
        var adopted = entry
        adopted.localVersion = cloudVersion
        adopted.localValue = entry.cloudValue
        candidate.entries[id] = adopted
        candidate.queue.remove(id)
    }
    private func removeEmptyEntries(in candidate: inout State) {
        let emptyIDs = candidate.entries.compactMap { id, entry in
            entry.localVersion == nil && entry.cloudVersion == nil ? id : nil
        }
        for id in emptyIDs {
            candidate.entries.removeValue(forKey: id)
            candidate.queue.remove(id)
        }
    }

    private func saveQueued(
        category: WorkspaceSyncCategory,
        remote: [EntryID: RemoteEntry]
    ) async throws -> SaveOutcome {
        #if canImport(CloudKit)
        let ids = state.queue
            .filter { $0.category == category }
            .sorted()
        guard !ids.isEmpty else { return SaveOutcome() }

        var outcome = SaveOutcome()
        let uploadRevision = revision
        var offset = 0
        while offset < ids.count {
            try Task.checkCancellation()
            guard state.isEnabled, state.enabledCategories.contains(category),
                  revision == uploadRevision else { break }
            let end = min(offset + Self.modifyBatchSize, ids.count)
            let batchIDs = Array(ids[offset..<end])
            let records = try batchIDs.map { id -> CKRecord in
                guard let entry = state.entries[id], entry.localVersion != nil else {
                    throw WorkspaceSyncError.malformedRecord("Queued key is missing its local edit")
                }
                return try makeRecord(for: entry, existing: remote[id]?.record)
            }
            let batchOutcome = try await modify(records: records, ids: batchIDs)
            outcome.saved.formUnion(batchOutcome.saved)
            if outcome.failure == nil {
                outcome.failure = batchOutcome.failure
            }
            offset = end
            if batchOutcome.failure != nil {
                // The operation may have partially succeeded. Persisting those
                // successes is safe; leaving every failed key queued is safer
                // than treating a transport failure as an acknowledgement.
                break
            }
        }
        return outcome
        #else
        _ = category
        _ = remote
        throw WorkspaceSyncError.cloudKitUnavailable
        #endif
    }

    #if canImport(CloudKit)
    @ObservationIgnored
    private lazy var cloudContainer = CKContainer(identifier: containerIdentifier)

    private var privateDatabase: CKDatabase { cloudContainer.privateCloudDatabase }

    /// A private database follows the signed-in iCloud account. Never upload
    /// the previous account's local workspace into a new account implicitly.
    private func prepareCloudAccount() async throws {
        try validateContainerIdentifier()
        let accountID = try await cloudContainer.userRecordID().recordName
        guard state.isEnabled, state.cloudAccountID != accountID else { return }
        var candidate = state
        candidate.cloudAccountID = accountID
        candidate.pendingConflicts.removeAll()
        candidate.categoriesRequiringChoice.formUnion(WorkspaceSyncCategory.allCases)
        try commit(candidate)
    }

    private func fetchRemote(category: WorkspaceSyncCategory) async throws -> [EntryID: RemoteEntry] {
        try validateContainerIdentifier()
        let query = CKQuery(
            recordType: Self.recordType,
            predicate: NSPredicate(format: "category == %@", category.rawValue)
        )
        let desiredKeys: [CKRecord.FieldKey] = [
            RecordField.schemaVersion,
            RecordField.category,
            RecordField.key,
            RecordField.deleted,
            RecordField.value,
            RecordField.editTimestamp,
            RecordField.deviceID
        ]
        var cursor: CKQueryOperation.Cursor?
        var result: [EntryID: RemoteEntry] = [:]

        while true {
            try Task.checkCancellation()
            if let continuation = cursor {
                let page = try await privateDatabase.records(
                    continuingMatchFrom: continuation,
                    desiredKeys: desiredKeys,
                    resultsLimit: Self.pageSize
                )
                for (recordID, recordResult) in page.matchResults {
                    let record = try recordResult.get()
                    let remote = try parse(record: record, recordID: recordID, category: category)
                    if result.updateValue(remote, forKey: remote.id) != nil {
                        throw WorkspaceSyncError.malformedRecord("Duplicate key in category \(category.rawValue)")
                    }
                }
                cursor = page.queryCursor
            } else {
                let page = try await privateDatabase.records(
                    matching: query,
                    inZoneWith: nil,
                    desiredKeys: desiredKeys,
                    resultsLimit: Self.pageSize
                )
                for (recordID, recordResult) in page.matchResults {
                    let record = try recordResult.get()
                    let remote = try parse(record: record, recordID: recordID, category: category)
                    if result.updateValue(remote, forKey: remote.id) != nil {
                        throw WorkspaceSyncError.malformedRecord("Duplicate key in category \(category.rawValue)")
                    }
                }
                cursor = page.queryCursor
            }
            guard cursor != nil else { break }
        }
        return result
    }

    private func parse(
        record: CKRecord,
        recordID: CKRecord.ID,
        category: WorkspaceSyncCategory
    ) throws -> RemoteEntry {
        guard record.recordType == Self.recordType,
              record.recordID == recordID,
              let schemaVersion = (record[RecordField.schemaVersion] as? NSNumber)?.intValue,
              schemaVersion == Self.stateVersion,
              let categoryValue = record[RecordField.category] as? String,
              categoryValue == category.rawValue,
              let key = record[RecordField.key] as? String,
              Self.isValidKey(key),
              let deleted = (record[RecordField.deleted] as? NSNumber)?.boolValue,
              let timestamp = record[RecordField.editTimestamp] as? Date,
              let deviceID = record[RecordField.deviceID] as? String,
              !deviceID.isEmpty
        else {
            throw WorkspaceSyncError.malformedRecord(record.recordID.recordName)
        }

        let id = EntryID(category: category, key: key)
        guard Self.recordName(for: id) == record.recordID.recordName else {
            throw WorkspaceSyncError.malformedRecord("Record identity does not match its key")
        }
        let value: WorkspaceSyncValue?
        if deleted {
            value = nil
        } else {
            guard let data = record[RecordField.value] as? Data else {
                throw WorkspaceSyncError.malformedRecord("Missing value for \(key)")
            }
            do {
                value = try JSONDecoder().decode(WorkspaceSyncValue.self, from: data)
            } catch {
                throw WorkspaceSyncError.malformedRecord("Unreadable value for \(key): \(Self.describe(error))")
            }
        }
        return RemoteEntry(
            id: id,
            value: value,
            version: EditVersion(timestamp: timestamp, deviceID: deviceID),
            record: record
        )
    }

    private func makeRecord(
        for entry: PersistedEntry,
        existing: CKRecord?
    ) throws -> CKRecord {
        guard let version = entry.localVersion else {
            throw WorkspaceSyncError.malformedRecord("Cannot upload an entry without a local version")
        }
        let id = entry.id
        let record = existing ?? CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: Self.recordName(for: id))
        )
        record[RecordField.schemaVersion] = NSNumber(value: Self.stateVersion)
        record[RecordField.category] = id.category.rawValue as NSString
        record[RecordField.key] = id.key as NSString
        record[RecordField.deleted] = NSNumber(value: entry.localValue == nil)
        record[RecordField.editTimestamp] = version.timestamp as NSDate
        record[RecordField.deviceID] = version.deviceID as NSString
        if let value = entry.localValue {
            let data: Data
            do {
                data = try JSONEncoder().encode(value)
            } catch {
                throw WorkspaceSyncError.cloudKit("Unable to encode value for \(id.key): \(Self.describe(error))")
            }
            record[RecordField.value] = data as NSData
        } else {
            record[RecordField.value] = nil
        }
        return record
    }

    private func modify(records: [CKRecord], ids: [EntryID]) async throws -> SaveOutcome {
        try Task.checkCancellation()
        let result: (
            saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
            deleteResults: [CKRecord.ID: Result<Void, any Error>]
        )
        do {
            result = try await privateDatabase.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkspaceSyncError.cloudKit(Self.describe(error))
        }

        var outcome = SaveOutcome()
        for (id, record) in zip(ids, records) {
            let saveResult = result.saveResults[record.recordID]
            switch saveResult {
            case .success:
                outcome.saved.insert(id)
            case .failure(let error):
                if outcome.failure == nil {
                    outcome.failure = Self.describe(error)
                }
            case nil:
                if outcome.failure == nil {
                    outcome.failure = "CloudKit returned no result for \(id.key)"
                }
            }
        }
        return outcome
    }
    #else
    private func fetchRemote(category: WorkspaceSyncCategory) async throws -> [EntryID: RemoteEntry] {
        _ = category
        throw WorkspaceSyncError.cloudKitUnavailable
    }
    #endif

    private func commit(_ candidate: State) throws {
        do {
            try Self.persist(candidate, to: storageURL)
        } catch {
            let persistenceError = WorkspaceSyncError.persistenceFailed(Self.describe(error))
            record(persistenceError)
            throw persistenceError
        }
        state = candidate
        revision &+= 1
        publish(candidate)
    }

    private func publish(_ candidate: State) {
        isEnabled = candidate.isEnabled
        enabledCategories = candidate.enabledCategories
        pendingConflicts = candidate.pendingConflicts
        lastSync = candidate.lastSync
        values = Self.publicValues(from: candidate.entries)
    }

    private func nextEditVersion(for id: EntryID, in candidate: inout State) -> EditVersion {
        let now = Date()
        let priorEdit = candidate.lastEditAt ?? .distantPast
        let localEdit = candidate.entries[id]?.localVersion?.timestamp ?? .distantPast
        let cloudEdit = candidate.entries[id]?.cloudVersion?.timestamp ?? .distantPast
        let floor = max(priorEdit, max(localEdit, cloudEdit))
        let timestamp = max(now, floor.addingTimeInterval(0.001))
        candidate.lastEditAt = timestamp
        return EditVersion(timestamp: timestamp, deviceID: candidate.deviceID)
    }

    private func validateContainerIdentifier() throws {
        guard containerIdentifier.hasPrefix("iCloud."),
              containerIdentifier.utf8.count <= 255
        else { throw WorkspaceSyncError.invalidContainerIdentifier }
    }

    private static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= maxKeyBytes &&
            !key.unicodeScalars.contains(where: { $0.value < 0x20 })
    }

    private static func localState(_ entry: PersistedEntry) -> ReplicatedState {
        guard entry.localVersion != nil else { return .absent }
        guard let value = entry.localValue else { return .tombstone }
        return .value(value)
    }

    private static func cloudState(_ entry: PersistedEntry) -> ReplicatedState {
        guard entry.cloudVersion != nil else { return .absent }
        guard let value = entry.cloudValue else { return .tombstone }
        return .value(value)
    }

    private enum Ordering {
        case orderedAscending
        case orderedSame
        case orderedDescending
    }

    private static func compare(_ lhs: EditVersion, _ rhs: EditVersion) -> Ordering {
        if lhs.timestamp < rhs.timestamp { return .orderedAscending }
        if lhs.timestamp > rhs.timestamp { return .orderedDescending }
        if lhs.deviceID < rhs.deviceID { return .orderedAscending }
        if lhs.deviceID > rhs.deviceID { return .orderedDescending }
        return .orderedSame
    }

    private static func compareTie(_ lhs: ReplicatedState, _ rhs: ReplicatedState) -> Ordering {
        let left = tieData(lhs)
        let right = tieData(rhs)
        if left.lexicographicallyPrecedes(right) { return .orderedAscending }
        if right.lexicographicallyPrecedes(left) { return .orderedDescending }
        return .orderedSame
    }

    private static func tieData(_ state: ReplicatedState) -> Data {
        switch state {
        case .absent:
            return Data([0])
        case .tombstone:
            return Data([1])
        case .value(let value):
            let encoded = (try? JSONEncoder().encode(value)) ?? Data()
            return Data([2]) + encoded
        }
    }

    private static func remappedWorkspaceValue(
        _ value: WorkspaceSyncValue?,
        from source: AccountLinkID,
        to destination: AccountLinkID
    ) -> WorkspaceSyncValue? {
        guard case .string(let raw) = value,
              let link = MailternalDeepLink(string: raw),
              link.accountLinkID == source,
              let remapped = link.replacingAccountLinkID(
                  with: destination
              ).formattedString else {
            return value
        }
        return .string(remapped)
    }


    private static func publicValues(
        from entries: [EntryID: PersistedEntry]
    ) -> [String: WorkspaceSyncValue] {
        var values: [String: WorkspaceSyncValue] = [:]
        for entry in entries.values {
            guard entry.localVersion != nil, let value = entry.localValue else { continue }
            values[entry.key] = value
        }
        return values
    }

    #if canImport(CloudKit)
    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func recordName(for id: EntryID) -> String {
        let digest = SHA256.hash(data: Data(id.key.utf8))
        let hex = String(unsafeUninitializedCapacity: 64) { buffer in
            var offset = 0
            for byte in digest {
                buffer[offset] = hexDigits[Int(byte >> 4)]
                buffer[offset + 1] = hexDigits[Int(byte & 0x0f)]
                offset += 2
            }
            return offset
        }
        return "v1-\(id.category.rawValue)-\(hex)"
    }
    #endif

    private static func loadState(from url: URL) throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return State(
                deviceID: UUID().uuidString.lowercased(),
                isEnabled: false,
                enabledCategories: Set(WorkspaceSyncCategory.allCases),
                pendingConflicts: [],
                categoriesRequiringChoice: [],
                lastEditAt: nil,
                lastSync: nil,
                entries: [:],
                queue: []
            )
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let persisted = try decoder.decode(PersistedState.self, from: data)
        guard persisted.version == stateVersion, !persisted.deviceID.isEmpty else {
            throw WorkspaceSyncError.persistenceFailed("Unsupported workspace state version")
        }
        var entries: [EntryID: PersistedEntry] = [:]
        var categoriesByKey: [String: WorkspaceSyncCategory] = [:]
        for entry in persisted.entries {
            guard Self.isValidKey(entry.key), entry.category == entry.id.category else {
                throw WorkspaceSyncError.persistenceFailed("Invalid persisted workspace key")
            }
            if let existingCategory = categoriesByKey[entry.key],
               existingCategory != entry.category {
                throw WorkspaceSyncError.duplicateKeyAcrossCategories(entry.key)
            }
            categoriesByKey[entry.key] = entry.category
            if entries.updateValue(entry, forKey: entry.id) != nil {
                throw WorkspaceSyncError.persistenceFailed("Duplicate persisted workspace key")
            }
        }
        var queue: Set<EntryID> = []
        for item in persisted.queue {
            guard entries[item.id] != nil else {
                throw WorkspaceSyncError.persistenceFailed("Queue references missing workspace key")
            }
            queue.insert(item.id)
        }
        return State(
            deviceID: persisted.deviceID,
            isEnabled: persisted.isEnabled,
            cloudAccountID: persisted.cloudAccountID,
            enabledCategories: persisted.enabledCategories,
            pendingConflicts: persisted.pendingConflicts,
            categoriesRequiringChoice: persisted.categoriesRequiringChoice,
            lastEditAt: persisted.lastEditAt,
            lastSync: persisted.lastSync,
            entries: entries,
            queue: queue
        )
    }

    private static func persist(_ state: State, to url: URL) throws {
        let persisted = PersistedState(
            version: stateVersion,
            deviceID: state.deviceID,
            cloudAccountID: state.cloudAccountID,
            isEnabled: state.isEnabled,
            enabledCategories: state.enabledCategories,
            pendingConflicts: state.pendingConflicts,
            categoriesRequiringChoice: state.categoriesRequiringChoice,
            lastEditAt: state.lastEditAt,
            lastSync: state.lastSync,
            entries: state.entries.values.sorted { $0.id < $1.id },
            queue: state.queue.sorted().map {
                PersistedQueueItem(category: $0.category, key: $0.key)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(persisted)
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil)
            } else {
                try fm.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func record(_ error: Error) {
        lastError = Self.describe(error)
    }

    private static func describe(_ error: Error) -> String {
        if let workspaceError = error as? WorkspaceSyncError,
           let description = workspaceError.errorDescription {
            return description
        }
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
}

