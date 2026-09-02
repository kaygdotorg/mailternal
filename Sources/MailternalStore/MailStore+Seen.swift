import Foundation
import GRDB

extension MailStore {
    /// Enqueues a coalesced flag mutation and applies it optimistically to the
    /// local message row.
    public func enqueueFlag(
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        flag: FlagKind,
        set: Bool
    ) async throws {
        try await write { db in
            try MailStore.enqueueFlag(
                db,
                account: account,
                folder: folder,
                uidValidity: uidValidity,
                uid: uid,
                flag: flag,
                set: set
            )
        }
    }

    /// Looks up the message row and enqueues a flag mutation against its generation.
    public func enqueueFlag(message id: MessageID, flag: FlagKind, set: Bool) async throws {
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
            let uidValidity: Int64 = row["uid_validity"]
            let account: String = row["account_id"]
            try MailStore.enqueueFlag(
                db,
                account: AccountID(rawValue: account),
                folder: FolderID(rawValue: folderID),
                uidValidity: UInt32(uidValidity),
                uid: IMAPUID(rawValue: UInt32(uid)),
                flag: flag,
                set: set
            )
        }
    }

    /// Snapshot of pending flag mutations for `UID STORE`, oldest first.
    public func snapshotFlagQueue(limit: Int = 100) async throws -> [FlagOp] {
        let cap = max(0, limit)
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM seen_queue ORDER BY enqueued_at ASC, id ASC LIMIT ?",
                arguments: [cap]
            )
            return rows.map { MailStore.flagOp(from: $0) }
        }
    }

    /// Tagged `OK`: dequeue a flag operation.
    public func dequeueFlag(_ op: FlagOp) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM seen_queue WHERE id = ?", arguments: [op.id])
        }
    }

    /// Tagged `NO`/`BAD`: drop the op, clear its local optimistic override, and
    /// record the failure. The next remote delta then supplies server truth.
    public func dropFlag(_ op: FlagOp, reason: String) async throws {
        try await write { db in
            try db.execute(sql: "DELETE FROM seen_queue WHERE id = ?", arguments: [op.id])
            let column = op.flag == .seen ? "is_read" : "is_flagged"
            try db.execute(
                sql: """
                    UPDATE messages SET \(column) = ?
                    WHERE uid = ?
                      AND generation_id IN (
                        SELECT id FROM generations
                        WHERE folder_id = ? AND uid_validity = ?
                      )
                    """,
                arguments: [!op.set, Int64(op.uid.rawValue), op.folder.rawValue, Int64(op.uidValidity)]
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

    /// Discards all flag ops whose UIDVALIDITY no longer matches the live generation.
    public func dropStaleFlag(folder: FolderID) async throws {
        try await write { db in
            try MailStore.dropStaleFlag(db, folder: folder)
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

    static func enqueueFlag(
        _ db: Database,
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        flag: FlagKind,
        set: Bool
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO seen_queue (
                    account_id, folder_id, uid_validity, uid, enqueued_at, flag, "set"
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account_id, folder_id, uid_validity, uid, flag) DO UPDATE SET
                    enqueued_at = excluded.enqueued_at,
                    "set" = excluded."set"
                """,
            arguments: [
                account.rawValue,
                folder.rawValue,
                Int64(uidValidity),
                Int64(uid.rawValue),
                Date().timeIntervalSince1970,
                flag.rawValue,
                set,
            ]
        )
        let column = flag == .seen ? "is_read" : "is_flagged"
        try db.execute(
            sql: """
                UPDATE messages SET \(column) = ?
                WHERE uid = ?
                  AND generation_id IN (
                    SELECT id FROM generations
                    WHERE folder_id = ? AND uid_validity = ?
                  )
                """,
            arguments: [set, Int64(uid.rawValue), folder.rawValue, Int64(uidValidity)]
        )
    }

    static func dropStaleFlag(_ db: Database, folder: FolderID) throws {
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
    static func flagOp(from row: Row) -> FlagOp {
        let uidValidity: Int64 = row["uid_validity"]
        let uid: Int64 = row["uid"]
        let rawFlag: String = row["flag"]
        return FlagOp(
            id: row["id"],
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            uidValidity: UInt32(uidValidity),
            uid: IMAPUID(rawValue: UInt32(uid)),
            flag: FlagKind(rawValue: rawFlag) ?? .seen,
            set: row["set"]
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
