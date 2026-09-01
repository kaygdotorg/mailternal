import Foundation
import GRDB

extension MailStore {
    /// Enqueues a coalesced archive move and optimistically removes the local row.
    public func enqueueArchive(
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID
    ) async throws {
        try await write { db in
            try MailStore.enqueueArchive(
                db,
                account: account,
                folder: folder,
                uidValidity: uidValidity,
                uid: uid
            )
        }
    }

    /// Looks up the message row, enqueues against its generation, and removes
    /// the row in the same writer transaction (spec: sync.md Archive queue).
    public func enqueueArchive(message id: MessageID) async throws {
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
            try MailStore.enqueueArchive(
                db,
                account: AccountID(rawValue: account),
                folder: FolderID(rawValue: folderID),
                uidValidity: UInt32(uidValidity),
                uid: IMAPUID(rawValue: UInt32(uid))
            )
        }
    }

    /// Snapshot of pending archive operations for sending, oldest first.
    public func snapshotArchiveQueue(limit: Int = 100) async throws -> [ArchiveOp] {
        let cap = max(0, limit)
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM archive_queue ORDER BY enqueued_at ASC, id ASC LIMIT ?",
                arguments: [cap]
            )
            return rows.map { MailStore.archiveOp(from: $0) }
        }
    }

    /// Tagged `OK`: dequeue an archive operation and clear any row that
    /// arrived from a concurrent FETCH while this operation was pending.
    public func deleteArchiveOp(_ op: ArchiveOp) async throws {
        try await write { db in
            let present = try Int.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM archive_queue WHERE id = ?)",
                arguments: [op.id]
            ) == 1
            guard present else { return }
            try db.execute(sql: "DELETE FROM archive_queue WHERE id = ?", arguments: [op.id])
            try db.execute(
                sql: """
                    DELETE FROM messages
                    WHERE uid = ?
                      AND generation_id IN (
                        SELECT id FROM generations
                        WHERE folder_id = ? AND uid_validity = ?
                      )
                    """,
                arguments: [Int64(op.uid.rawValue), op.folder.rawValue, Int64(op.uidValidity)]
            )
        }
    }

    /// Persists that the fallback COPY completed. The remaining STORE and
    /// EXPUNGE phases are safe to retry after a process restart.
    public func markArchiveCopied(_ op: ArchiveOp) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE archive_queue SET copied = 1 WHERE id = ?",
                arguments: [op.id]
            )
        }
    }

    /// Discards archive operations whose UIDVALIDITY no longer matches the live generation.
    public func dropStaleArchive(folder: FolderID) async throws {
        try await write { db in
            try MailStore.dropStaleArchive(db, folder: folder)
        }
    }

    static func enqueueArchive(
        _ db: Database,
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO archive_queue (
                    account_id, folder_id, uid_validity, uid, enqueued_at, copied
                )
                VALUES (?, ?, ?, ?, ?, 0)
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
        // An archive mutation leaves this folder. The next delta pass reconciles
        // the server's truth if the operation fails or the process exits.
        try db.execute(
            sql: """
                DELETE FROM messages
                WHERE uid = ?
                  AND generation_id IN (
                    SELECT id FROM generations
                    WHERE folder_id = ? AND uid_validity = ?
                  )
                """,
            arguments: [Int64(uid.rawValue), folder.rawValue, Int64(uidValidity)]
        )
    }

    static func dropStaleArchive(_ db: Database, folder: FolderID) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT account_id, uid_validity, uid
                FROM archive_queue
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
        for row in rows {
            let account: String = row["account_id"]
            let uidValidity: Int64 = row["uid_validity"]
            let uid: Int64 = row["uid"]
            try MailStore.insertError(
                db,
                StoreLogEntry(
                    kind: .archive,
                    account: AccountID(rawValue: account),
                    folder: folder,
                    uid: IMAPUID(rawValue: UInt32(uid)),
                    message: "stale UIDVALIDITY \(uidValidity)"
                )
            )
        }
        try db.execute(
            sql: """
                DELETE FROM archive_queue
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

    static func archiveOp(from row: Row) -> ArchiveOp {
        let uidValidity: Int64 = row["uid_validity"]
        let uid: Int64 = row["uid"]
        return ArchiveOp(
            id: row["id"],
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            uidValidity: UInt32(uidValidity),
            uid: IMAPUID(rawValue: UInt32(uid)),
            copied: row["copied"]
        )
    }

}
