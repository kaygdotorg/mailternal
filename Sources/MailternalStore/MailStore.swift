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

    /// Retires folders for `account` that are absent from this LIST pass.
    ///
    /// A stored folder is kept when a `seen` key matches it by `objectID` (when
    /// the folder has one) or else by `path`. Already-retired rows are ignored.
    /// Returns the folders newly marked retired so sync can cancel their work.
    ///
    /// Retire moves every generation to `retiring` and clears the live pointer;
    /// call `cleanupRetiredGenerations` to drop messages and FTS rows. Do not
    /// invoke this on a failed LIST — an empty `seen` set retires every folder.
    public func reconcileFolders(
        account: AccountID,
        seen: [FolderKey]
    ) async throws -> [FolderID] {
        try await write { db in
            try MailStore.reconcileFolders(db, account: account, seen: seen)
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
                    sql: "UPDATE folders SET path = ?, name = ?, role = ?, retired = 0 WHERE id = ?",
                    arguments: [path, name, role.rawValue, existing]
                )
                return FolderID(rawValue: existing)
            }
        }
        if let existing = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM folders WHERE account_id = ? AND path = ? AND retired = 0",
            arguments: [account.rawValue, path]
        ) {
            try db.execute(
                sql: """
                    UPDATE folders SET name = ?, role = ?, object_id = COALESCE(?, object_id), retired = 0
                    WHERE id = ?
                    """,
                arguments: [name, role.rawValue, objectID, existing]
            )
            return FolderID(rawValue: existing)
        }
        try db.execute(
            sql: """
                INSERT INTO folders (account_id, path, name, role, object_id, retired)
                VALUES (?, ?, ?, ?, ?, 0)
                """,
            arguments: [account.rawValue, path, name, role.rawValue, objectID]
        )
        return FolderID(rawValue: db.lastInsertedRowID)
    }

    static func reconcileFolders(
        _ db: Database,
        account: AccountID,
        seen: [FolderKey]
    ) throws -> [FolderID] {
        let seenObjectIDs = Set(seen.compactMap(\.objectID))
        let seenPaths = Set(seen.map(\.path))
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, path, object_id FROM folders WHERE account_id = ? AND retired = 0",
            arguments: [account.rawValue]
        )
        var retired: [FolderID] = []
        for row in rows {
            let id: Int64 = row["id"]
            let path: String = row["path"]
            let objectID: String? = row["object_id"]
            let matched: Bool
            if let objectID, !objectID.isEmpty, seenObjectIDs.contains(objectID) {
                matched = true
            } else {
                matched = seenPaths.contains(path)
            }
            if !matched {
                let folder = FolderID(rawValue: id)
                try retireFolder(db, folder)
                retired.append(folder)
            }
        }
        return retired
    }

    static func retireFolder(_ db: Database, _ folder: FolderID) throws {
        try db.execute(
            sql: "UPDATE folders SET retired = 1, live_generation_id = NULL WHERE id = ?",
            arguments: [folder.rawValue]
        )
        try db.execute(
            sql: """
                UPDATE generations SET state = ?
                WHERE folder_id = ? AND state IN (?, ?)
                """,
            arguments: [
                GenerationState.retiring.rawValue,
                folder.rawValue,
                GenerationState.live.rawValue,
                GenerationState.replacement.rawValue,
            ]
        )
        try db.execute(
            sql: "DELETE FROM seen_queue WHERE folder_id = ?",
            arguments: [folder.rawValue]
        )
    }

    static func fetchFolders(_ db: Database, account: AccountID) throws -> [FolderSummary] {
        let sql = """
            SELECT f.id, f.name, f.path, f.role,
                   (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id) AS total,
                   (SELECT COUNT(*) FROM messages m WHERE m.generation_id = f.live_generation_id AND m.is_read = 0) AS unread,
                   s.backfill_phase, s.progress, s.halted_through
            FROM folders f
            LEFT JOIN sync_state s ON s.generation_id = f.live_generation_id
            WHERE f.account_id = ? AND f.retired = 0
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
            WHERE f.id = ? AND f.retired = 0
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

    static func requireActiveFolder(_ db: Database, _ folder: FolderID) throws -> Row {
        let row = try requireFolder(db, folder)
        let retired: Bool = row["retired"]
        if retired {
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

    /// Structural invariants for sync chaos / leftover detection (spec: sync.md).
    public func checkInvariants() async throws -> StoreInvariantReport {
        try await read { db in
            try MailStore.collectInvariants(db)
        }
    }

    static func collectInvariants(_ db: Database) throws -> StoreInvariantReport {
        let messageCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_fts") ?? 0
        let orphanMessageCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM messages m
                LEFT JOIN generations g ON g.id = m.generation_id
                WHERE g.id IS NULL
                   OR g.state NOT IN ('live', 'replacement', 'retiring')
                """
        ) ?? 0
        let cursorBeyondUidNextCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM sync_state s
                JOIN generations g ON g.id = s.generation_id
                WHERE s.low_water_uid IS NOT NULL
                  AND (
                    (s.baseline_uid IS NOT NULL AND s.low_water_uid > s.baseline_uid + 1)
                    OR s.low_water_uid > COALESCE(
                        (SELECT MAX(m.uid) FROM messages m WHERE m.generation_id = s.generation_id),
                        0
                    ) + 1
                  )
                """
        ) ?? 0
        let liveGenerations = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM generations WHERE state = 'live'"
        ) ?? 0
        let replacementGenerations = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM generations WHERE state = 'replacement'"
        ) ?? 0
        let retiringGenerations = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM generations WHERE state = 'retiring'"
        ) ?? 0
        let seenQueueCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM seen_queue") ?? 0
        let multiLive = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM (
                    SELECT folder_id FROM generations
                    WHERE state = 'live'
                    GROUP BY folder_id
                    HAVING COUNT(*) > 1
                )
                """
        ) ?? 0
        let multiReplacement = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM (
                    SELECT folder_id FROM generations
                    WHERE state = 'replacement'
                    GROUP BY folder_id
                    HAVING COUNT(*) > 1
                )
                """
        ) ?? 0
        let missingFTS = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM messages m
                WHERE NOT EXISTS (SELECT 1 FROM messages_fts f WHERE f.rowid = m.id)
                """
        ) ?? 0
        let extraFTS = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM messages_fts f
                WHERE NOT EXISTS (SELECT 1 FROM messages m WHERE m.id = f.rowid)
                """
        ) ?? 0

        var issues: [String] = []
        if orphanMessageCount > 0 {
            issues.append("orphan messages: \(orphanMessageCount)")
        }
        if messageCount != ftsCount || missingFTS > 0 || extraFTS > 0 {
            issues.append(
                "FTS mismatch messages=\(messageCount) fts=\(ftsCount) missing=\(missingFTS) extra=\(extraFTS)"
            )
        }
        if cursorBeyondUidNextCount > 0 {
            issues.append("cursors beyond UIDNEXT: \(cursorBeyondUidNextCount)")
        }
        if multiLive > 0 {
            issues.append("folders with multiple live generations: \(multiLive)")
        }
        if multiReplacement > 0 {
            issues.append("folders with multiple replacement generations: \(multiReplacement)")
        }

        return StoreInvariantReport(
            messageCount: messageCount,
            ftsCount: ftsCount,
            orphanMessageCount: orphanMessageCount,
            cursorBeyondUidNextCount: cursorBeyondUidNextCount,
            liveGenerations: liveGenerations,
            replacementGenerations: replacementGenerations,
            retiringGenerations: retiringGenerations,
            seenQueueCount: seenQueueCount,
            issues: issues
        )
    }
}
