import Foundation
import GRDB

/// GRDB 7 storage layer for Mailternal (spec: sync.md Storage).
///
/// One WAL `DatabasePool` is the single writer queue. All mutations go through
/// `DatabasePool.write`; ValueObservation delivers after commit. List reads are
/// keyset-paginated; FTS is an external-content table kept consistent by triggers.
public final class MailStore: Sendable {
    /// Default attachment-cache cap: 2 GiB (spec: sync.md Attachment cache).
    public static let defaultAttachmentCacheCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    let dbPool: DatabasePool
    let cachesDirectory: URL
    let attachmentCacheCapBytes: Int64
    let pins: PinTracker
    private let observationQueue = DispatchQueue(label: "mailternal.store.observation")

    /// Opens (or creates) the store at `databaseURL` with attachment files under `cachesDirectory`.
    public init(
        databaseURL: URL,
        cachesDirectory: URL,
        attachmentCacheCapBytes: Int64 = MailStore.defaultAttachmentCacheCapBytes
    ) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        try Schema.migrator.migrate(pool)

        self.dbPool = pool
        self.cachesDirectory = cachesDirectory
        self.attachmentCacheCapBytes = max(0, attachmentCacheCapBytes)
        self.pins = PinTracker()

        try FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cachesDirectory.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func write<T: Sendable>(_ updates: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbPool.write(updates)
    }

    func read<T: Sendable>(_ values: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await dbPool.read(values)
    }

    func observe<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncStream<T> {
        let pool = dbPool
        let queue = observationQueue
        return AsyncStream { continuation in
            let task = Task {
                let observation = ValueObservation.tracking(fetch)
                do {
                    let scheduler: ValueObservationScheduler = .async(onQueue: queue)
                    for try await value in observation.values(in: pool, scheduling: scheduler) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Accounts (non-secret AccountConfig only)

extension MailStore {
    /// Inserts or replaces non-secret account settings. Secrets never enter SQLite.
    public func upsertAccount(_ config: AccountConfig) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (
                        id, display_name, email_address, username,
                        imap_host, imap_port, imap_security
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        email_address = excluded.email_address,
                        username = excluded.username,
                        imap_host = excluded.imap_host,
                        imap_port = excluded.imap_port,
                        imap_security = excluded.imap_security
                    """,
                arguments: [
                    config.id.rawValue,
                    config.displayName,
                    config.emailAddress,
                    config.username,
                    config.imap.host,
                    config.imap.port,
                    config.imap.security.rawValue,
                ]
            )
        }
    }

    public func fetchAccount(_ id: AccountID) async throws -> AccountConfig? {
        try await read { db in
            try MailStore.fetchAccount(db, id: id)
        }
    }

    public func fetchAccounts() async throws -> [AccountConfig] {
        try await read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY id")
            return try rows.map { try MailStore.account(from: $0) }
        }
    }

    public func deleteAccount(_ id: AccountID) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [id.rawValue])
        }
    }

    static func fetchAccount(_ db: Database, id: AccountID) throws -> AccountConfig? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM accounts WHERE id = ?", arguments: [id.rawValue]) else {
            return nil
        }
        return try account(from: row)
    }

    static func account(from row: Row) throws -> AccountConfig {
        guard let security = IMAPEndpoint.Security(rawValue: row["imap_security"]) else {
            throw MailStoreError.accountNotFound
        }
        return AccountConfig(
            id: AccountID(rawValue: row["id"]),
            displayName: row["display_name"],
            emailAddress: row["email_address"],
            username: row["username"],
            imap: IMAPEndpoint(
                host: row["imap_host"],
                port: row["imap_port"],
                security: security
            )
        )
    }
}

// MARK: - Folders

extension MailStore {
    /// Creates or updates a folder. When `objectID` is present, identity follows
    /// OBJECTID/MAILBOXID across renames (spec: sync.md mailbox discovery).
    public func upsertFolder(
        account: AccountID,
        path: String,
        name: String,
        role: FolderRole,
        objectID: String?
    ) async throws -> FolderID {
        try await write { db in
            try MailStore.upsertFolder(db, account: account, path: path, name: name, role: role, objectID: objectID)
        }
    }

    public func fetchFolders(account: AccountID) async throws -> [FolderSummary] {
        try await read { db in
            try MailStore.fetchFolders(db, account: account)
        }
    }

    public func fetchFolderSummary(_ folder: FolderID) async throws -> FolderSummary? {
        try await read { db in
            try MailStore.fetchFolderSummary(db, folder: folder)
        }
    }

    /// Live sidebar observation: per-folder aggregate counts, never a whole-folder message query.
    public func observeFolders(account: AccountID) -> AsyncStream<[FolderSummary]> {
        observe { db in
            try MailStore.fetchFolders(db, account: account)
        }
    }

    public func observeCounts(in folder: FolderID) -> AsyncStream<FolderCounts> {
        observe { db in
            try MailStore.fetchCounts(db, folder: folder)
        }
    }

    static func upsertFolder(
        _ db: Database,
        account: AccountID,
        path: String,
        name: String,
        role: FolderRole,
        objectID: String?
    ) throws -> FolderID {
        if let objectID {
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM folders WHERE account_id = ? AND object_id = ?",
                arguments: [account.rawValue, objectID]
            ) {
                try db.execute(
                    sql: "UPDATE folders SET path = ?, name = ?, role = ? WHERE id = ?",
                    arguments: [path, name, role.rawValue, existing]
                )
                return FolderID(rawValue: existing)
            }
        }
        if let existing = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM folders WHERE account_id = ? AND path = ?",
            arguments: [account.rawValue, path]
        ) {
            try db.execute(
                sql: "UPDATE folders SET name = ?, role = ?, object_id = COALESCE(?, object_id) WHERE id = ?",
                arguments: [name, role.rawValue, objectID, existing]
            )
            return FolderID(rawValue: existing)
        }
        try db.execute(
            sql: """
                INSERT INTO folders (account_id, path, name, role, object_id)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [account.rawValue, path, name, role.rawValue, objectID]
        )
        return FolderID(rawValue: db.lastInsertedRowID)
    }

    static func fetchFolders(_ db: Database, account: AccountID) throws -> [FolderSummary] {
        let sql = """
            SELECT f.id, f.name, f.path, f.role,
                   (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id) AS total,
                   (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id AND m.is_read = 0) AS unread,
                   s.backfill_phase, s.progress, s.halted_through
            FROM folders f
            LEFT JOIN sync_state s ON s.generation_id = f.live_generation_id
            WHERE f.account_id = ?
            ORDER BY \(RoleOrder.sqlCase("f.role")), f.path COLLATE NOCASE
            """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [account.rawValue])
        return rows.map { folderSummary(from: $0) }
    }

    static func fetchFolderSummary(_ db: Database, folder: FolderID) throws -> FolderSummary? {
        let sql = """
            SELECT f.id, f.name, f.path, f.role,
                   (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id) AS total,
                   (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id AND m.is_read = 0) AS unread,
                   s.backfill_phase, s.progress, s.halted_through
            FROM folders f
            LEFT JOIN sync_state s ON s.generation_id = f.live_generation_id
            WHERE f.id = ?
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [folder.rawValue]) else {
            return nil
        }
        return folderSummary(from: row)
    }

    static func fetchCounts(_ db: Database, folder: FolderID) throws -> FolderCounts {
        let sql = """
            SELECT
              (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id) AS total,
              (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id AND m.is_read = 0) AS unread
            FROM folders f
            WHERE f.id = ?
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [folder.rawValue]) else {
            return FolderCounts(unread: 0, total: 0)
        }
        let total: Int = row["total"]
        let unread: Int = row["unread"]
        return FolderCounts(unread: unread, total: total)
    }

    static func folderSummary(from row: Row) -> FolderSummary {
        let role = FolderRole(rawValue: row["role"]) ?? .none
        let phase: String? = row["backfill_phase"]
        let progress: Double? = row["progress"]
        let halted: Double? = row["halted_through"]
        return FolderSummary(
            id: FolderID(rawValue: row["id"]),
            name: row["name"],
            path: row["path"],
            role: role,
            unreadCount: row["unread"],
            totalCount: row["total"],
            backfill: BackfillState.from(
                phase: phase,
                progress: progress,
                haltedThrough: halted
            )
        )
    }

    static func requireFolder(_ db: Database, _ folder: FolderID) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM folders WHERE id = ?", arguments: [folder.rawValue]) else {
            throw MailStoreError.folderNotFound
        }
        return row
    }
}

// MARK: - Test / maintenance inspection

extension MailStore {
    func tableNames() async throws -> Set<String> {
        try await read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            ))
        }
    }

    func triggerNames() async throws -> Set<String> {
        try await read { db in
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        }
    }

    func ftsCreateSQL() async throws -> String? {
        try await read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE name = ?",
                arguments: [Schema.ftsTable]
            )
        }
    }

    func ftsUnfilteredCount(matching query: String) async throws -> Int {
        try await read { db in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return 0 }
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH ?",
                arguments: [pattern]
            ) ?? 0
        }
    }

    func generationState(_ generation: MailboxGeneration) async throws -> GenerationState? {
        try await read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: """
                    SELECT state FROM generations
                    WHERE folder_id = ? AND uid_validity = ?
                    """,
                arguments: [generation.folder.rawValue, Int64(generation.uidValidity)]
            ) else { return nil }
            return GenerationState(rawValue: raw)
        }
    }

    func liveGenerationID(for folder: FolderID) async throws -> Int64? {
        try await read { db in
            try Int64.fetchOne(db, sql: "SELECT live_generation_id FROM folders WHERE id = ?", arguments: [folder.rawValue])
        }
    }

    func journalMode() async throws -> String {
        try await read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }
}
