import Foundation
import GRDB

extension MailStore {
    /// Enqueues a coalesced `\Seen` op and marks the local row read (spec: sync.md).
    public func enqueueSeen(account: AccountID, folder: FolderID, uidValidity: UInt32, uid: IMAPUID) async throws {
        try await write { db in
            try MailStore.enqueueSeen(db, account: account, folder: folder, uidValidity: uidValidity, uid: uid)
        }
    }

    /// Looks up the message row and enqueues `\Seen` against its generation.
    public func enqueueSeen(message id: MessageID) async throws {
        try await write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT m.uid, g.folder_id, g.uid_validity, f.account_id
                    FROM messages m
                    JOIN generations g ON g.id = m.generation_id
                    JOIN folders f ON f.id = g.folder_id
                    WHERE m.id = ?
                    """,
                arguments: [id.rawValue]
            ) else {
                throw MailStoreError.messageNotFound
            }
            let uid: Int64 = row["uid"]
            let folderID: Int64 = row["folder_id"]
            let uv: Int64 = row["uid_validity"]
            let account: String = row["account_id"]
            try MailStore.enqueueSeen(
                db,
                account: AccountID(rawValue: account),
                folder: FolderID(rawValue: folderID),
                uidValidity: UInt32(uv),
                uid: IMAPUID(rawValue: UInt32(uid))
            )
        }
    }

    /// Snapshot of pending ops for `UID STORE` send. Oldest first.
    public func snapshotSeenQueue(limit: Int = 100) async throws -> [SeenOp] {
        let cap = max(0, limit)
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM seen_queue ORDER BY enqueued_at ASC, id ASC LIMIT ?",
                arguments: [cap]
            )
            return rows.map { MailStore.seenOp(from: $0) }
        }
    }

    /// Tagged `OK`: dequeue the op.
    public func dequeueSeen(_ op: SeenOp) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM seen_queue WHERE id = ?", arguments: [op.id])
        }
    }

    /// Tagged `NO`/`BAD`: drop the op, clear the local read override, log the failure.
    public func dropSeen(_ op: SeenOp, reason: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM seen_queue WHERE id = ?", arguments: [op.id])
            try db.execute(
                sql: """
                    UPDATE messages SET is_read = 0
                    WHERE uid = ?
                      AND generation_id IN (
                        SELECT id FROM generations
                        WHERE folder_id = ? AND uid_validity = ?
                      )
                    """,
                arguments: [Int64(op.uid.rawValue), op.folder.rawValue, Int64(op.uidValidity)]
            )
            try MailStore.insertError(
                db,
                StoreLogEntry(
                    kind: .seen,
                    account: op.account,
                    folder: op.folder,
                    uid: op.uid,
                    message: reason
                )
            )
        }
    }

    /// Discards ops whose UIDVALIDITY no longer matches the live generation.
    public func dropStaleSeen(folder: FolderID) async throws {
        try await write { db in
            try MailStore.dropStaleSeen(db, folder: folder)
        }
    }

    public func recordError(_ entry: StoreLogEntry) async throws {
        try await write { db in
            try MailStore.insertError(db, entry)
        }
    }

    public func fetchErrorLog(limit: Int = 100) async throws -> [StoreLogEntry] {
        let cap = max(0, limit)
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.*, g.uid_validity, g.folder_id AS gen_folder_id
                    FROM error_log e
                    LEFT JOIN generations g ON g.id = e.generation_id
                    ORDER BY e.occurred_at DESC, e.id DESC
                    LIMIT ?
                    """,
                arguments: [cap]
            )
            return rows.map { MailStore.logEntry(from: $0) }
        }
    }

    static func enqueueSeen(
        _ db: Database,
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO seen_queue (account_id, folder_id, uid_validity, uid, enqueued_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id, folder_id, uid_validity, uid) DO NOTHING
                """,
            arguments: [
                account.rawValue,
                folder.rawValue,
                Int64(uidValidity),
                Int64(uid.rawValue),
                Date().timeIntervalSince1970,
            ]
        )
        try db.execute(
            sql: """
                UPDATE messages SET is_read = 1
                WHERE uid = ?
                  AND generation_id IN (
                    SELECT id FROM generations
                    WHERE folder_id = ? AND uid_validity = ?
                  )
                """,
            arguments: [Int64(uid.rawValue), folder.rawValue, Int64(uidValidity)]
        )
    }

    static func dropStaleSeen(_ db: Database, folder: FolderID) throws {
        try db.execute(
            sql: """
                DELETE FROM seen_queue
                WHERE folder_id = ?
                  AND uid_validity != COALESCE(
                    (SELECT g.uid_validity
                     FROM folders f
                     JOIN generations g ON g.id = f.live_generation_id
                     WHERE f.id = ?),
                    -1
                  )
                """,
            arguments: [folder.rawValue, folder.rawValue]
        )
    }

    static func seenOp(from row: Row) -> SeenOp {
        let uv: Int64 = row["uid_validity"]
        let uid: Int64 = row["uid"]
        return SeenOp(
            id: row["id"],
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            uidValidity: UInt32(uv),
            uid: IMAPUID(rawValue: UInt32(uid))
        )
    }

    static func insertError(_ db: Database, _ entry: StoreLogEntry) throws {
        var generationID: Int64?
        if let gen = entry.generation {
            generationID = try MailStore.generationID(db, gen)
        }
        try db.execute(
            sql: """
                INSERT INTO error_log (
                    occurred_at, kind, account_id, folder_id, generation_id, uid, message, detail
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.occurredAt.timeIntervalSince1970,
                entry.kind.rawValue,
                entry.account?.rawValue,
                entry.folder?.rawValue,
                generationID,
                entry.uid.map { Int64($0.rawValue) },
                entry.message,
                entry.detail,
            ]
        )
    }

    static func logEntry(from row: Row) -> StoreLogEntry {
        let kind = StoreErrorKind(rawValue: row["kind"]) ?? .sync
        let folderID: Int64? = row["folder_id"]
        let genFolderID: Int64? = row["gen_folder_id"]
        let uv: Int64? = row["uid_validity"]
        let uid: Int64? = row["uid"]
        let account: String? = row["account_id"]
        var generation: MailboxGeneration?
        if let uv, let fid = genFolderID ?? folderID {
            generation = MailboxGeneration(folder: FolderID(rawValue: fid), uidValidity: UInt32(uv))
        }
        return StoreLogEntry(
            id: row["id"],
            occurredAt: Date(timeIntervalSince1970: row["occurred_at"]),
            kind: kind,
            account: account.map(AccountID.init(rawValue:)),
            folder: folderID.map { FolderID(rawValue: $0) },
            generation: generation,
            uid: uid.map { IMAPUID(rawValue: UInt32($0)) },
            message: row["message"],
            detail: row["detail"]
        )
    }
}
