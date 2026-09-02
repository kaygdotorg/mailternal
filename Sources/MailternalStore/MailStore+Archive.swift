import Foundation
import GRDB

extension MailStore {
    /// Enqueues a coalesced move and optimistically removes the local row.
    public func enqueueMove(
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        to destination: FolderRole
    ) async throws {
        try await write { db in
            try MailStore.enqueueMove(
                db,
                account: account,
                folder: folder,
                uidValidity: uidValidity,
                uid: uid,
                destination: destination
            )
        }
    }

    /// Looks up the message row, enqueues against its generation, and removes
    /// the row in the same writer transaction.
    public func enqueueMove(message id: MessageID, to destination: FolderRole) async throws {
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
            try MailStore.enqueueMove(
                db,
                account: AccountID(rawValue: account),
                folder: FolderID(rawValue: folderID),
                uidValidity: UInt32(uidValidity),
                uid: IMAPUID(rawValue: UInt32(uid)),
                destination: destination
            )
        }
    }

    /// Snapshot of pending moves for sending, oldest first.
    public func snapshotMoveQueue(limit: Int = 100) async throws -> [MoveOp] {
        let cap = max(0, limit)
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM archive_queue ORDER BY enqueued_at ASC, id ASC LIMIT ?",
                arguments: [cap]
            )
            return rows.map { MailStore.moveOp(from: $0) }
        }
    }

    /// Tagged `OK`: dequeue a move and clear any row that arrived from a
    /// concurrent FETCH while this operation was pending.
    public func deleteMoveOp(_ op: MoveOp) async throws {
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

    /// Persists that fallback COPY completed. Remaining STORE and EXPUNGE
    /// phases are safe to retry after a process restart.
    public func markMoveCopied(_ op: MoveOp) async throws {
        try await write { db in
            try db.execute(
                sql: "UPDATE archive_queue SET copied = 1 WHERE id = ?",
                arguments: [op.id]
            )
        }
    }

    /// Discards move operations whose UIDVALIDITY no longer matches the live generation.
    public func dropStaleMove(folder: FolderID) async throws {
        try await write { db in
            try MailStore.dropStaleMove(db, folder: folder)
        }
    }


    static func enqueueMove(
        _ db: Database,
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        destination: FolderRole
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO archive_queue (
                    account_id, folder_id, uid_validity, uid, enqueued_at, copied, destination
                )
                VALUES (?, ?, ?, ?, ?, 0, ?)
                ON CONFLICT(account_id, folder_id, uid_validity, uid) DO UPDATE SET
                    enqueued_at = excluded.enqueued_at,
                    destination = excluded.destination,
                    copied = 0
                """,
            arguments: [
                account.rawValue,
                folder.rawValue,
                Int64(uidValidity),
                Int64(uid.rawValue),
                Date().timeIntervalSince1970,
                destination.rawValue,
            ]
        )
        // A move mutation leaves this folder. The next delta pass reconciles
        // server truth if the operation fails or the process exits.
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

    static func dropStaleMove(_ db: Database, folder: FolderID) throws {
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

    static func moveOp(from row: Row) -> MoveOp {
        let uidValidity: Int64 = row["uid_validity"]
        let uid: Int64 = row["uid"]
        let destinationRaw: String = row["destination"]
        let destination = FolderRole(rawValue: destinationRaw) ?? .archive
        return MoveOp(
            id: row["id"],
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            uidValidity: UInt32(uidValidity),
            uid: IMAPUID(rawValue: UInt32(uid)),
            destination: destination,
            copied: row["copied"]
        )
    }

}
