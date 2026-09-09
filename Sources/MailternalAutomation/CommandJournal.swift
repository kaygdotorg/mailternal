import Foundation

public enum JournalRecordStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case running
    case completed
    case failed
}

/// Bounded metadata retained for a command. It intentionally does not retain
/// the command payload: credentials, bodies, drafts, and search text must not
/// become durable history.
public struct CommandJournalRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let origin: CommandOrigin
    public let action: String
    public let targetIDs: [String]
    public let createdAt: Date
    public var resolvedAt: Date?
    public var status: JournalRecordStatus
    public var outcome: String?
    public var error: String?

    public init(
        id: UUID = UUID(), origin: CommandOrigin, action: String,
        targetIDs: [String] = [], createdAt: Date = Date(),
        status: JournalRecordStatus = .pending, resolvedAt: Date? = nil,
        outcome: String? = nil, error: String? = nil
    ) {
        self.id = id; self.origin = origin; self.action = action
        self.targetIDs = targetIDs; self.createdAt = createdAt; self.status = status
        self.resolvedAt = resolvedAt; self.outcome = outcome; self.error = error
    }
}

public enum CommandJournalError: LocalizedError, Equatable, Sendable {
    case unreadable(String)
    case missing(UUID)
    case invalidTransition(UUID, JournalRecordStatus)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message): "The command journal could not be opened: \(message)"
        case .missing(let id): "The command journal entry \(id.uuidString) is no longer available."
        case .invalidTransition(let id, let status): "Command \(id.uuidString) cannot transition from \(status.rawValue)."
        case .persistence(let message): "The command journal could not be saved: \(message)"
        }
    }
}

/// An actor-backed, atomic JSON journal. Pending and running records survive
/// restarts without a bound; the last 1000 terminal records (completed or
/// failed) are retained.
public actor CommandJournal {
    private let fileURL: URL
    private var records: [CommandJournalRecord]
    private var loadFailure: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.records = []
            self.loadFailure = nil
            return
        }
        do {
            let loaded = try decoder.decode(
                [CommandJournalRecord].self,
                from: Data(contentsOf: fileURL)
            )
            self.records = loaded
            self.loadFailure = nil
        } catch {
            self.records = []
            self.loadFailure = error.localizedDescription
        }
    }

    /// Reload after acquiring the exclusive runtime lease. A GUI process can
    /// be initialized while the previous engine is still completing commands;
    /// its initial snapshot must not overwrite that owner's final records.
    public func reload() throws {
        do {
            let current = FileManager.default.fileExists(atPath: fileURL.path)
                ? try decoder.decode([CommandJournalRecord].self, from: Data(contentsOf: fileURL))
                : []
            records = current
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
            throw CommandJournalError.unreadable(error.localizedDescription)
        }
    }

    /// Resolves metadata left by an interrupted owner after the new runtime
    /// has acquired the lease and reloaded the durable journal. Payloads are
    /// intentionally unavailable, so these records are never replayed and
    /// their terminal text does not claim whether the mail operation reached a
    /// server.
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        try ensureWritable()
        let interrupted = records.filter {
            $0.status == .pending || $0.status == .running
        }
        guard !interrupted.isEmpty else { return 0 }
        let resolvedAt = Date()
        var updated = records
        for index in updated.indices where
            updated[index].status == .pending || updated[index].status == .running {
            updated[index].status = .failed
            updated[index].resolvedAt = resolvedAt
            updated[index].outcome = "interrupted"
            updated[index].error =
                "The prior runtime stopped before completion; durable mail operations may still complete."
        }
        updated = Self.boundedRecords(updated)
        try persist(updated)
        records = updated
        return interrupted.count
    }

    /// Reads fail when the on-disk journal could not be loaded. Returning an
    /// empty snapshot would make corruption indistinguishable from no history.
    public func snapshot() throws -> [CommandJournalRecord] {
        try ensureReadable()
        return records
    }

    /// Only accepted work is pending. Failed commands are terminal and are
    /// retained as metadata, but they are never replayable.
    public func pending() throws -> [CommandJournalRecord] {
        try ensureReadable()
        return records.filter { $0.status == .pending || $0.status == .running }
    }

    public func append(
        origin: CommandOrigin,
        action: String,
        targetIDs: [String] = []
    ) throws -> CommandJournalRecord {
        try ensureWritable()
        let record = CommandJournalRecord(origin: origin, action: action, targetIDs: targetIDs)
        var updated = records
        updated.append(record)
        try persist(updated)
        records = updated
        return record
    }

    @discardableResult
    public func begin(_ id: UUID) throws -> CommandJournalRecord {
        try transition(id, to: .running, outcome: nil, error: nil)
    }

    @discardableResult
    public func complete(_ id: UUID, outcome: String? = nil) throws -> CommandJournalRecord {
        try transition(id, to: .completed, outcome: outcome, error: nil)
    }

    @discardableResult
    public func fail(_ id: UUID, error: String) throws -> CommandJournalRecord {
        try transition(id, to: .failed, outcome: nil, error: error)
    }

    private func transition(
        _ id: UUID,
        to status: JournalRecordStatus,
        outcome: String?,
        error: String?
    ) throws -> CommandJournalRecord {
        try ensureWritable()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw CommandJournalError.missing(id)
        }
        guard records[index].status == .pending || records[index].status == .running else {
            throw CommandJournalError.invalidTransition(id, records[index].status)
        }

        var updated = records
        updated[index].status = status
        updated[index].resolvedAt = status == .completed || status == .failed ? Date() : nil
        updated[index].outcome = outcome
        updated[index].error = error
        updated = Self.boundedRecords(updated, preservingTerminalID: id)

        try persist(updated)
        records = updated
        return updated[indexOf: id]
    }

    private static func boundedRecords(
        _ records: [CommandJournalRecord],
        preservingTerminalID terminalID: UUID? = nil
    ) -> [CommandJournalRecord] {
        let terminal = records.enumerated().filter {
            $0.element.status == .completed || $0.element.status == .failed
        }
        guard terminal.count > 1_000 else { return records }
        let ordered = terminal.sorted {
            let leftDate = $0.element.resolvedAt ?? $0.element.createdAt
            let rightDate = $1.element.resolvedAt ?? $1.element.createdAt
            if leftDate == rightDate { return $0.offset < $1.offset }
            return leftDate < rightDate
        }
        var keep = Set(ordered.suffix(1_000).map { $0.element.id })
        if let terminalID, !keep.contains(terminalID) {
            keep.insert(terminalID)
            if let evicted = ordered.first(where: {
                keep.contains($0.element.id) && $0.element.id != terminalID
            }) {
                keep.remove(evicted.element.id)
            }
        }
        return records.filter {
            $0.status == .pending || $0.status == .running || keep.contains($0.id)
        }
    }

    private func ensureReadable() throws {
        if let loadFailure {
            throw CommandJournalError.unreadable(loadFailure)
        }
    }

    private func ensureWritable() throws {
        try ensureReadable()
    }

    private func persist(_ records: [CommandJournalRecord]) throws {
        do {
            let fileManager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(records)
            let temporaryURL = directory.appendingPathComponent(
                ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                // Create the staging file private from its first filesystem
                // appearance; only the final replacement is visible as the
                // journal path.
                guard fileManager.createFile(
                    atPath: temporaryURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let stagedHandle = try FileHandle(forWritingTo: temporaryURL)
                do {
                    try stagedHandle.write(contentsOf: data)
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: temporaryURL.path
                    )
                    try stagedHandle.synchronize()
                    try stagedHandle.close()
                } catch {
                    try? stagedHandle.close()
                    throw error
                }
                if fileManager.fileExists(atPath: fileURL.path) {
                    _ = try fileManager.replaceItemAt(
                        fileURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: fileURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        } catch {
            throw CommandJournalError.persistence(error.localizedDescription)
        }
    }
}

private extension Array where Element == CommandJournalRecord {
    subscript(indexOf id: UUID) -> Element {
        first(where: { $0.id == id })!
    }
}
