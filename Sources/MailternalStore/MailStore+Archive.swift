import Foundation
import GRDB

extension MailStore {
    /// Enqueues a coalesced role-based move and optimistically removes the
    /// local row.
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
                destination: destination,
                destinationFolderID: nil
            )
        }
    }

    /// Enqueues a move to an explicit folder identity.
    public func enqueueMove(
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        to destination: FolderID
    ) async throws {
        try await write { db in
            try MailStore.enqueueMove(
                db,
                account: account,
                folder: folder,
                uidValidity: uidValidity,
                uid: uid,
                destination: .none,
                destinationFolderID: destination
            )
        }
    }

    /// Looks up all message rows and enqueues the batch in one transaction.

    /// Single-id role move retained for existing store clients.
    public func enqueueMove(message id: MessageID, to destination: FolderRole) async throws {
        try await enqueueMove(messages: [id], to: destination)
    }

    /// Single-id explicit-folder move retained for existing store clients.
    public func enqueueMove(message id: MessageID, to destination: FolderID) async throws {
        try await enqueueMove(messages: [id], to: destination)
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
    /// concurrent FETCH while this operation was pending. Acknowledgements are
    /// matched against the complete queued operation so a stale result cannot
    /// remove a coalesced replacement.
    public func deleteMoveOp(_ op: MoveOp) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    DELETE FROM archive_queue
                    WHERE id = ? AND account_id = ? AND folder_id = ?
                      AND uid_validity = ? AND uid = ? AND destination = ?
                      AND destination_folder_id IS ?
                    """,
                arguments: [
                    op.id,
                    op.account.rawValue,
                    op.folder.rawValue,
                    Int64(op.uidValidity),
                    Int64(op.uid.rawValue),
                    op.destination.rawValue,
                    op.destinationFolderID?.rawValue,
                ]
            )
            guard db.changesCount == 1 else { return }
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
            if let journalID = op.journalID {
                try db.execute(
                    sql: "UPDATE op_journal SET state = ?, completed_at = ? WHERE id = ?",
                    arguments: ["irreversible", Date().timeIntervalSince1970, journalID]
                )
            }
        
        }
    }

    /// Persists that fallback COPY completed. Remaining STORE and EXPUNGE
    /// phases are safe to retry after a process restart. Ignore an operation
    /// snapshot that was superseded while COPY was in flight.
    public func markMoveCopied(_ op: MoveOp) async throws {
        try await write { db in
            var sql = """
                UPDATE archive_queue
                SET copied = 1
                WHERE id = ? AND account_id = ? AND folder_id = ?
                  AND uid_validity = ? AND uid = ? AND destination = ?
                """
            var arguments: StatementArguments = [
                op.id,
                op.account.rawValue,
                op.folder.rawValue,
                Int64(op.uidValidity),
                Int64(op.uid.rawValue),
                op.destination.rawValue,
            ]
            if let destinationFolderID = op.destinationFolderID {
                sql += " AND destination_folder_id = ?"
                arguments += [destinationFolderID.rawValue]
            }
            sql += " AND copied = ?"
            arguments += [op.copied]
            try db.execute(sql: sql, arguments: arguments)
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
        destination: FolderRole,
        destinationFolderID: FolderID?,
        journalID: Int64? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO archive_queue (
                    account_id, folder_id, uid_validity, uid, enqueued_at, copied,
                    destination, destination_folder_id, journal_id
                )
                VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?)
                ON CONFLICT(account_id, folder_id, uid_validity, uid) DO UPDATE SET
                    enqueued_at = excluded.enqueued_at,
                    destination = excluded.destination,
                    destination_folder_id = excluded.destination_folder_id,
                    copied = 0,
                    claimed = 0,
                    journal_id = excluded.journal_id,
                    destination_uid_validity = NULL,
                    destination_uid = NULL
                """,
            arguments: [
                account.rawValue,
                folder.rawValue,
                Int64(uidValidity),
                Int64(uid.rawValue),
                Date().timeIntervalSince1970,
                destination.rawValue,
                destinationFolderID?.rawValue,
                journalID,
            ]
        )
    }

    private struct MoveMessageRow: Sendable {
        let account: String
        let folder: Int64
        let uidValidity: UInt32
        let uid: IMAPUID
    }

    private static func moveMessageRow(_ db: Database, id: MessageID) throws -> MoveMessageRow? {
        guard let canonicalID = try MailStore.resolveMessageID(db, id: id),
              let row = try Row.fetchOne(
            db,
            sql: """
                SELECT m.uid, g.folder_id, g.uid_validity, f.account_id
                FROM messages m
                JOIN generations g ON g.id = m.generation_id
                JOIN folders f ON f.id = g.folder_id
                WHERE m.id = ?
                """,
            arguments: [canonicalID.rawValue]
        ) else {
            return nil
        }
        let uid: Int64 = row["uid"]
        let uidValidity: Int64 = row["uid_validity"]
        return MoveMessageRow(
            account: row["account_id"],
            folder: row["folder_id"],
            uidValidity: UInt32(uidValidity),
            uid: IMAPUID(rawValue: UInt32(uid))
        )
    }

    static func enqueueMove(
        _ db: Database,
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        destination: FolderRole
    ) throws {
        try enqueueMove(
            db,
            account: account,
            folder: folder,
            uidValidity: uidValidity,
            uid: uid,
            destination: destination,
            destinationFolderID: nil
        )
    }

    static func dropStaleMove(_ db: Database, folder: FolderID) throws {
        try db.execute(
            sql: """
                UPDATE op_journal SET state = ?, completed_at = ?
                WHERE id IN (
                    SELECT journal_id FROM archive_queue
                    WHERE folder_id = ?
                      AND uid_validity != COALESCE(
                        (SELECT g.uid_validity
                         FROM folders f
                         JOIN generations g ON g.id = f.live_generation_id
                         WHERE f.id = ?),
                        -1
                      )
                      AND journal_id IS NOT NULL
                )
                """,
            arguments: ["irreversible", Date().timeIntervalSince1970, folder.rawValue, folder.rawValue]
        )
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
        let destinationFolderRaw: Int64? = row["destination_folder_id"]
        let destinationUIDValidity: Int64? = row["destination_uid_validity"]
        let destinationUIDRaw: Int64? = row["destination_uid"]
        let journalID: Int64? = row["journal_id"]
        return MoveOp(
            id: row["id"],
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            uidValidity: UInt32(uidValidity),
            uid: IMAPUID(rawValue: UInt32(uid)),
            destination: destination,
            destinationFolderID: destinationFolderRaw.map(FolderID.init(rawValue:)),
            copied: row["copied"],
            claimed: row["claimed"],
            journalID: journalID,
            destinationUIDValidity: destinationUIDValidity.map(UInt32.init),
            destinationUID: destinationUIDRaw.map { IMAPUID(rawValue: UInt32($0)) }
        )
    }


}
