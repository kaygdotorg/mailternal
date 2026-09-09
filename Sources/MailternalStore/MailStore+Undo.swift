import Foundation
import GRDB
import MailternalInterfaces

private enum JournalKind {
    static let flags = "flags"
    static let move = "move"
}

private enum JournalState {
    static let active = "active"
    static let completed = "completed"
    static let undoRequested = "undo_requested"
    static let undone = "undone"
    static let rejected = "rejected"
    static let irreversible = "irreversible"
}

private struct JournalEntry: Sendable {
    let id: Int64
    let account: AccountID
    let sourceFolder: FolderID
    let sourceUIDValidity: UInt32
    let sourceUID: IMAPUID
    let destinationFolder: FolderID?
    let destinationUIDValidity: UInt32?
    let destinationUID: IMAPUID?
    let oldIsRead: Bool
    let oldIsFlagged: Bool
    let flag: FlagKind?
}

extension MailStore {
    /// Lightweight account-scoped mutation metadata. Rows are selected in one
    /// SQL statement, in the caller's order, and never load body/raw columns.
    public func messageMutationStates(_ ids: [MessageID]) async throws -> [MessageMutationState] {
        var unique: [MessageID] = []
        unique.reserveCapacity(ids.count)
        var seen = Set<MessageID>()
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        guard !unique.isEmpty else { return [] }

        return try await read { [unique] db in
            // SQLite's default bind limit is commonly 999. Keep one reader
            // snapshot while splitting large metadata requests into bounded
            // statements, then restore the caller's unique input order.
            let chunkSize = 500
            var byID: [MessageID: MessageMutationState] = [:]
            byID.reserveCapacity(unique.count)
            var start = 0
            while start < unique.count {
                let end = min(start + chunkSize, unique.count)
                let chunk = unique[start..<end]
                let values = Array(repeating: "(?)", count: chunk.count).joined(separator: ", ")
                let arguments = StatementArguments(chunk.map { $0.rawValue })
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        WITH requested(id) AS (VALUES \(values))
                        SELECT requested.id AS requested_id, m.id AS canonical_id,
                               m.uid, g.uid_validity, g.folder_id, m.is_read, m.is_flagged,
                               a.account_link_id, f.path, f.object_id
                        FROM requested
                        LEFT JOIN message_aliases ma ON ma.alias_id = requested.id
                        JOIN messages m ON m.id = COALESCE(ma.target_id, requested.id)
                        JOIN generations g ON g.id = m.generation_id
                            AND g.state = 'live'
                        JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                        JOIN accounts a ON a.id = f.account_id
                        WHERE ma.account_id IS NULL OR ma.account_id = f.account_id
                        """,
                    arguments: arguments
                )
                for row in rows {
                    let requestedID = MessageID(rawValue: row["requested_id"])
                    let canonicalID = MessageID(rawValue: row["canonical_id"])
                    let folderID = FolderID(rawValue: row["folder_id"])
                    guard let accountLinkID = AccountLinkID(uuidString: row["account_link_id"]) else {
                        continue
                    }
                    let path: String = row["path"]
                    let objectID: String? = row["object_id"]
                    let locator: FolderLocator
                    if let objectID, !objectID.isEmpty {
                        locator = FolderLocator(kind: .object, value: objectID)
                    } else {
                        locator = FolderLocator(kind: .path, value: path)
                    }
                    let uidValidity: Int64 = row["uid_validity"]
                    let uid: Int64 = row["uid"]
                    guard uidValidity > 0, uidValidity <= Int64(UInt32.max),
                          uid > 0, uid <= Int64(UInt32.max) else {
                        continue
                    }
                    let canonicalLink = MailternalDeepLink.message(
                        accountLinkID: accountLinkID,
                        folderLocator: locator,
                        uidValidity: UInt32(uidValidity),
                        uid: IMAPUID(rawValue: UInt32(uid))
                    )
                    byID[requestedID] = MessageMutationState(
                        id: requestedID,
                        canonicalID: canonicalID,
                        folderID: folderID,
                        accountLinkID: accountLinkID,
                        isRead: row["is_read"],
                        isFlagged: row["is_flagged"],
                        link: canonicalLink
                    )
                }
                start = end
            }
            return unique.compactMap { byID[$0] }
        }
    }

    /// Enqueues a flag batch and captures the actual pre-mutation state in the
    /// same writer transaction. No-op IDs do not create journal entries.
    public func enqueueFlag(messages ids: [MessageID], flag: FlagKind, set: Bool) async throws {
        try await write { db in
            let unique = Self.uniqueIDs(ids)
            var rows: [(id: MessageID, account: AccountID, folder: FolderID, uidValidity: UInt32, uid: IMAPUID, isRead: Bool, isFlagged: Bool)] = []
            rows.reserveCapacity(unique.count)
            for id in unique {
                guard let row = try Self.flagMessageState(db, id: id) else {
                    throw MailStoreError.messageNotFound
                }
                let changed = flag == .seen ? row.isRead != set : row.isFlagged != set
                if changed {
                    rows.append(row)
                }
            }
            guard !rows.isEmpty else { return }
            let journalID = try Self.insertJournal(db, kind: JournalKind.flags)
            for row in rows {
                try Self.insertJournalEntry(
                    db,
                    journalID: journalID,
                    account: row.account,
                    sourceFolder: row.folder,
                    sourceUIDValidity: row.uidValidity,
                    sourceUID: row.uid,
                    oldIsRead: row.isRead,
                    oldIsFlagged: row.isFlagged,
                    flag: flag
                )
                try Self.enqueueFlag(
                    db,
                    account: row.account,
                    folder: row.folder,
                    uidValidity: row.uidValidity,
                    uid: row.uid,
                    flag: flag,
                    set: set,
                    journalID: journalID
                )
            }
            try Self.pruneJournal(db)
        }
    }

    /// Enqueues an explicit-folder move while capturing the source identity and
    /// old flags before the optimistic local row deletion.
    public func enqueueMove(messages ids: [MessageID], to destination: FolderID) async throws {
        try await write { db in
            let unique = Self.uniqueIDs(ids)
            var rows: [MoveSourceRow] = []
            rows.reserveCapacity(unique.count)
            for id in unique {
                guard let row = try Self.moveMessageState(db, id: id) else {
                    throw MailStoreError.messageNotFound
                }
                guard let destinationAccount = try String.fetchOne(
                    db,
                    sql: "SELECT account_id FROM folders WHERE id = ? AND retired = 0",
                    arguments: [destination.rawValue]
                ), destinationAccount == row.account.rawValue else {
                    throw MailStoreError.accountNotFound
                }
                if row.folder != destination {
                    rows.append(row)
                }
            }
            guard !rows.isEmpty else { return }
            let journalID = try Self.insertJournal(db, kind: JournalKind.move)
            for row in rows {
                try Self.insertJournalEntry(
                    db,
                    journalID: journalID,
                    account: row.account,
                    sourceFolder: row.folder,
                    sourceUIDValidity: row.uidValidity,
                    sourceUID: row.uid,
                    destinationFolder: destination,
                    oldIsRead: row.isRead,
                    oldIsFlagged: row.isFlagged
                )
                try Self.enqueueMove(
                    db,
                    account: row.account,
                    folder: row.folder,
                    uidValidity: row.uidValidity,
                    uid: row.uid,
                    destination: .none,
                    destinationFolderID: destination,
                    journalID: journalID
                )
            }
            try Self.pruneJournal(db)
        }
    }

    /// Role-based move variant with the same transactional journal capture.
    /// The destination may not have been discovered yet; the sync drainer
    /// resolves and persists its exact folder identity before completion.
    public func enqueueMove(messages ids: [MessageID], to destination: FolderRole) async throws {
        try await write { db in
            let unique = Self.uniqueIDs(ids)
            var rows: [MoveSourceRow] = []
            rows.reserveCapacity(unique.count)
            for id in unique {
                guard let row = try Self.moveMessageState(db, id: id) else {
                    throw MailStoreError.messageNotFound
                }
                let sourceRole = try String.fetchOne(
                    db,
                    sql: "SELECT role FROM folders WHERE id = ?",
                    arguments: [row.folder.rawValue]
                ).flatMap(FolderRole.init(rawValue:))
                if sourceRole != destination {
                    rows.append(row)
                }
            }
            guard !rows.isEmpty else { return }
            let journalID = try Self.insertJournal(db, kind: JournalKind.move)
            for row in rows {
                try Self.insertJournalEntry(
                    db,
                    journalID: journalID,
                    account: row.account,
                    sourceFolder: row.folder,
                    sourceUIDValidity: row.uidValidity,
                    sourceUID: row.uid,
                    destinationFolder: nil,
                    oldIsRead: row.isRead,
                    oldIsFlagged: row.isFlagged
                )
                try Self.enqueueMove(
                    db,
                    account: row.account,
                    folder: row.folder,
                    uidValidity: row.uidValidity,
                    uid: row.uid,
                    destination: destination,
                    destinationFolderID: nil,
                    journalID: journalID
                )
            }
            try Self.pruneJournal(db)
        }
    }

    /// True only when the newest journal operation is reversible and wholly
    /// within the caller's account scope. A newer denied/irreversible operation
    /// intentionally blocks older operations instead of being skipped.
    public func canUndo(allowedAccountLinks: Set<AccountLinkID>? = nil) async throws -> Bool {
        guard allowedAccountLinks?.isEmpty != true else { return false }
        return try await read { db in
            guard let journal = try Self.latestJournal(db) else { return false }
            guard journal.state == JournalState.active || journal.state == JournalState.completed else {
                return false
            }
            return try Self.journalAllowed(db, journalID: journal.id, allowedAccountLinks: allowedAccountLinks)
        }
    }

    /// Atomically authorizes and applies (or durably requests) the newest
    /// operation's inverse. Every target is validated before the first queue
    /// write, so a rejected batch cannot leave a partial inverse.
    public func undo(allowedAccountLinks: Set<AccountLinkID>? = nil) async throws {
        guard allowedAccountLinks?.isEmpty != true else { throw MailUndoError.permissionDenied }
        try await write { db in
            guard let journal = try Self.latestJournal(db) else {
                throw MailUndoError.unavailable
            }
            guard journal.state == JournalState.active || journal.state == JournalState.completed else {
                switch journal.state {
                case JournalState.irreversible:
                    throw MailUndoError.irreversible("the server identity is no longer available")
                case JournalState.undoRequested:
                    throw MailUndoError.unavailable
                default:
                    throw MailUndoError.unavailable
                }
            }
            guard try Self.journalAllowed(db, journalID: journal.id, allowedAccountLinks: allowedAccountLinks) else {
                throw MailUndoError.permissionDenied
            }
            let entries = try Self.journalEntries(db, journalID: journal.id)
            guard !entries.isEmpty else { throw MailUndoError.unavailable }
            if journal.kind == JournalKind.flags {
                try Self.undoFlags(db, journalID: journal.id, entries: entries)
            } else if journal.kind == JournalKind.move {
                try Self.undoMoves(db, journalID: journal.id, entries: entries, state: journal.state)
            } else {
                throw MailUndoError.irreversible("unknown operation kind")
            }
            try Self.pruneJournal(db)
        }
    }
    /// Atomically claims a queued move before any IMAP command is sent. An
    /// unclaimed move whose journal received an undo request is cancelled
    /// here, leaving its cached source visible without a server mutation.
    public func claimMoveOp(_ op: MoveOp) async throws -> Bool {
        try await write { db in
            guard try Self.moveQueueMatches(db, op),
                  let claimed: Bool = try Bool.fetchOne(
                    db,
                    sql: "SELECT claimed FROM archive_queue WHERE id = ?",
                    arguments: [op.id]
                  ) else {
                return false
            }
            if let journalID = op.journalID,
               try String.fetchOne(
                   db,
                   sql: "SELECT state FROM op_journal WHERE id = ?",
                   arguments: [journalID]
               ) == JournalState.undoRequested {
                if claimed { return true }
                try Self.cancelUnclaimedMoves(db, journalID: journalID)
                return false
            }
            if claimed { return true }
            try db.execute(
                sql: "UPDATE archive_queue SET claimed = 1 WHERE id = ? AND claimed = 0",
                arguments: [op.id]
            )
            return db.changesCount == 1
        }
    }


    /// Persists the discovered destination folder before a MOVE/COPY result is
    /// acknowledged. Role moves cannot know this local identity at enqueue.
    public func recordMoveDestinationFolder(_ op: MoveOp, destination: FolderID) async throws {
        try await write { db in
            guard try Self.moveQueueMatches(db, op) else { return }
            try db.execute(
                sql: "UPDATE archive_queue SET destination_folder_id = ? WHERE id = ?",
                arguments: [destination.rawValue, op.id]
            )
            if let journalID = op.journalID {
                try db.execute(
                    sql: """
                        UPDATE op_journal_entries SET destination_folder_id = ?
                        WHERE journal_id = ? AND source_folder_id = ?
                          AND source_uid_validity = ? AND source_uid = ?
                        """,
                    arguments: [
                        destination.rawValue,
                        journalID,
                        op.folder.rawValue,
                        Int64(op.uidValidity),
                        Int64(op.uid.rawValue),
                    ]
                )
            }
        }
    }

    /// Records the destination identities returned by COPYUID/MOVE. A nil or
    /// incomplete mapping is retained as an explicit irreversible outcome and
    /// is never replaced with a guessed source UID.
    public func recordMoveDestinations(
        _ op: MoveOp,
        destinations: [MoveDestinationIdentity]
    ) async throws {
        try await write { db in
            guard try Self.moveQueueMatches(db, op) else { return }
            for destination in destinations where destination.sourceUID == op.uid {
                try db.execute(
                    sql: """
                        UPDATE archive_queue
                        SET destination_uid_validity = ?, destination_uid = ?
                        WHERE id = ? AND uid = ?
                        """,
                    arguments: [
                        Int64(destination.uidValidity),
                        Int64(destination.uid.rawValue),
                        op.id,
                        Int64(destination.sourceUID.rawValue),
                    ]
                )
                if let journalID = op.journalID {
                    try db.execute(
                        sql: """
                            UPDATE op_journal_entries
                            SET destination_uid_validity = ?, destination_uid = ?
                            WHERE journal_id = ? AND source_folder_id = ?
                              AND source_uid_validity = ? AND source_uid = ?
                            """,
                        arguments: [
                            Int64(destination.uidValidity),
                            Int64(destination.uid.rawValue),
                            journalID,
                            op.folder.rawValue,
                            Int64(op.uidValidity),
                            Int64(destination.sourceUID.rawValue),
                        ]
                    )
                }
            }
        }
    }

    /// Completes a server-side move. The mapping is optional only for legacy
    /// callers; a journal operation without all exact destination identities is
    /// marked irreversible rather than retried or guessed.
    public func completeMoveOp(
        _ op: MoveOp,
        destinations: [MoveDestinationIdentity]? = nil
    ) async throws {
        try await write { db in
            guard try Self.moveQueueMatches(db, op) else { return }
            if let destinations {
                for destination in destinations where destination.sourceUID == op.uid {
                    try db.execute(
                        sql: """
                            UPDATE archive_queue
                            SET destination_uid_validity = ?, destination_uid = ?
                            WHERE id = ? AND uid = ?
                            """,
                        arguments: [
                            Int64(destination.uidValidity),
                            Int64(destination.uid.rawValue),
                            op.id,
                            Int64(destination.sourceUID.rawValue),
                        ]
                    )
                    if let journalID = op.journalID {
                        try db.execute(
                            sql: """
                                UPDATE op_journal_entries
                                SET destination_uid_validity = ?, destination_uid = ?
                                WHERE journal_id = ? AND source_folder_id = ?
                                  AND source_uid_validity = ? AND source_uid = ?
                                """,
                            arguments: [
                                Int64(destination.uidValidity),
                                Int64(destination.uid.rawValue),
                                journalID,
                                op.folder.rawValue,
                                Int64(op.uidValidity),
                                Int64(destination.sourceUID.rawValue),
                            ]
                        )
                    }
                }
            }
            let destinationIdentity: (folder: FolderID, uidValidity: UInt32, uid: IMAPUID)? = try Row.fetchOne(
                db,
                sql: """
                    SELECT destination_folder_id, destination_uid_validity, destination_uid
                    FROM archive_queue WHERE id = ?
                    """,
                arguments: [op.id]
            ).flatMap { row in
                let folder: Int64? = row["destination_folder_id"]
                let uidValidity: Int64? = row["destination_uid_validity"]
                let uid: Int64? = row["destination_uid"]
                guard let folder, let uidValidity, let uid,
                      uidValidity > 0, uidValidity <= Int64(UInt32.max),
                      uid > 0, uid <= Int64(UInt32.max) else {
                    return nil
                }
                return (
                    folder: FolderID(rawValue: folder),
                    uidValidity: UInt32(uidValidity),
                    uid: IMAPUID(rawValue: UInt32(uid))
                )
            }
            var deleteSQL = """
                DELETE FROM archive_queue
                WHERE id = ? AND account_id = ? AND folder_id = ?
                  AND uid_validity = ? AND uid = ? AND destination = ?
                """
            var deleteArguments: StatementArguments = [
                op.id,
                op.account.rawValue,
                op.folder.rawValue,
                Int64(op.uidValidity),
                Int64(op.uid.rawValue),
                op.destination.rawValue,
            ]
            if let destinationFolderID = op.destinationFolderID {
                deleteSQL += " AND destination_folder_id = ?"
                deleteArguments += [destinationFolderID.rawValue]
            }
            try db.execute(sql: deleteSQL, arguments: deleteArguments)
            guard db.changesCount == 1 else { return }
            try Self.preserveCompletedMoveCache(
                db,
                op: op,
                destination: destinationIdentity
            )
            if let destinationIdentity {
                try Self.rewriteDependentJournalIdentities(
                    db,
                    account: op.account,
                    sourceFolder: op.folder,
                    sourceUIDValidity: op.uidValidity,
                    sourceUID: op.uid,
                    destinationFolder: destinationIdentity.folder,
                    destinationUIDValidity: destinationIdentity.uidValidity,
                    destinationUID: destinationIdentity.uid,
                    excluding: op.journalID
                )
            }
            guard let journalID = op.journalID else { return }
            try Self.finishMoveJournal(db, journalID: journalID)
        }
    }

    /// Commits the server's exact destination identity to the cache without
    /// decoding or copying message content. A destination generation is
    /// consumed only when it is already live/replacement, or when the exact
    /// server UIDVALIDITY allows a fresh replacement with no guessed baseline.
    /// The replacement is never activated by a move.
    private static func preserveCompletedMoveCache(
        _ db: Database,
        op: MoveOp,
        destination: (folder: FolderID, uidValidity: UInt32, uid: IMAPUID)?
    ) throws {
        guard let sourceRow = try Row.fetchOne(
            db,
            sql: """
                SELECT m.id
                FROM messages m
                JOIN generations g ON g.id = m.generation_id
                WHERE g.folder_id = ? AND g.uid_validity = ?
                  AND g.state IN ('live', 'replacement') AND m.uid = ?
                """,
            arguments: [
                op.folder.rawValue,
                Int64(op.uidValidity),
                Int64(op.uid.rawValue),
            ]
        ) else {
            return
        }
        let sourceID = MessageID(rawValue: sourceRow["id"])
        func discardSource() throws {
            try db.execute(
                sql: """
                    DELETE FROM messages
                    WHERE id = ? AND generation_id IN (
                        SELECT id FROM generations
                        WHERE folder_id = ? AND uid_validity = ?
                          AND state IN ('live', 'replacement')
                    )
                """,
                arguments: [
                    sourceID.rawValue,
                    op.folder.rawValue,
                    Int64(op.uidValidity),
                ]
            )
        }

        guard let destination else {
            try discardSource()
            return
        }

        var destinationGeneration = try Row.fetchOne(
            db,
            sql: """
                SELECT g.id, f.account_id
                FROM generations g
                JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                WHERE g.folder_id = ? AND g.uid_validity = ?
                  AND g.state IN ('live', 'replacement')
                """,
            arguments: [
                destination.folder.rawValue,
                Int64(destination.uidValidity),
            ]
        ).map { row -> (id: Int64, account: String) in
            (row["id"], row["account_id"])
        }
        if destinationGeneration == nil {
            // The destination may not have been selected yet. An exact
            // COPYUID UIDVALIDITY is sufficient to create an empty
            // replacement, but its baseline remains unknown by design.
            guard try String.fetchOne(
                db,
                sql: "SELECT account_id FROM folders WHERE id = ? AND retired = 0",
                arguments: [destination.folder.rawValue]
            ) == op.account.rawValue,
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM generations WHERE folder_id = ? AND uid_validity = ?)",
                arguments: [destination.folder.rawValue, Int64(destination.uidValidity)]
            ) != true,
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM generations WHERE folder_id = ? AND state = 'replacement')",
                arguments: [destination.folder.rawValue]
            ) != true else {
                // Do not retire or relabel another in-progress replacement.
                try discardSource()
                return
            }
            try MailStore.insertGeneration(
                db,
                folder: destination.folder,
                uidValidity: destination.uidValidity,
                state: .replacement,
                baselineUID: nil,
                makeLive: false
            )
            destinationGeneration = try Row.fetchOne(
                db,
                sql: """
                    SELECT g.id, f.account_id
                    FROM generations g
                    JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                    WHERE g.folder_id = ? AND g.uid_validity = ?
                      AND g.state = 'replacement'
                    """,
                arguments: [
                    destination.folder.rawValue,
                    Int64(destination.uidValidity),
                ]
            ).map { row -> (id: Int64, account: String) in
                (row["id"], row["account_id"])
            }
        }

        guard let destinationGeneration,
              destinationGeneration.account == op.account.rawValue else {
            try discardSource()
            return
        }
        let destinationGenerationID = destinationGeneration.id
        let destinationID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM messages WHERE generation_id = ? AND uid = ?",
            arguments: [destinationGenerationID, Int64(destination.uid.rawValue)]
        ).map(MessageID.init(rawValue:))
        if let destinationID, destinationID != sourceID {
            // Any aliases that pointed to this source are flattened before
            // the source row is removed. This keeps a chain from growing and
            // makes a subsequent inverse collision resolve in one hop.
            try db.execute(
                sql: """
                    UPDATE message_aliases
                    SET target_id = ?
                    WHERE target_id = ? AND account_id = ?
                    """,
                arguments: [
                    destinationID.rawValue,
                    sourceID.rawValue,
                    op.account.rawValue,
                ]
            )
            // Delete before inserting the alias so an alias ID can never
            // coexist with a live message row. The transaction rolls back
            // both operations if the alias insert fails.
            try db.execute(
                sql: "DELETE FROM messages WHERE id = ?",
                arguments: [sourceID.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO message_aliases (alias_id, target_id, account_id)
                    VALUES (?, ?, ?)
                    ON CONFLICT(alias_id) DO UPDATE SET
                        target_id = excluded.target_id,
                        account_id = excluded.account_id
                    """,
                arguments: [
                    sourceID.rawValue,
                    destinationID.rawValue,
                    op.account.rawValue,
                ]
            )
        } else {
            // Reusing the source row preserves its auto-increment ID, body,
            // parts and FTS row. UPDATE generation/UID is metadata-only.
            try db.execute(
                sql: """
                    UPDATE messages
                    SET generation_id = ?, uid = ?
                    WHERE id = ? AND generation_id IN (
                        SELECT id FROM generations
                        WHERE folder_id = ? AND uid_validity = ?
                          AND state IN ('live', 'replacement')
                    )
                """,
                arguments: [
                    destinationGenerationID,
                    Int64(destination.uid.rawValue),
                    sourceID.rawValue,
                    op.folder.rawValue,
                    Int64(op.uidValidity),
                ]
            )
        }
    }

    /// Explicit failure path used by the sync drainer; failed moves are not
    /// offered to undo after local optimistic rows are restored.
    public func rejectMoveOp(_ op: MoveOp, reason: String) async throws {
        try await write { db in
            guard try Self.moveQueueMatches(db, op) else { return }
            try db.execute(
                sql: "DELETE FROM archive_queue WHERE id = ?",
                arguments: [op.id]
            )
            if let journalID = op.journalID {
                try db.execute(
                    sql: """
                        UPDATE op_journal_entries
                        SET state = ?
                        WHERE journal_id = ? AND state = 'active'
                          AND source_folder_id = ? AND source_uid_validity = ? AND source_uid = ?
                        """,
                    arguments: [
                        JournalState.rejected,
                        journalID,
                        op.folder.rawValue,
                        Int64(op.uidValidity),
                        Int64(op.uid.rawValue),
                    ]
                )
                try Self.finishMoveJournal(db, journalID: journalID)
            }
            try Self.insertError(
                db,
                StoreLogEntry(kind: .archive, account: op.account, folder: op.folder, uid: op.uid, message: reason)
            )
        }
    }

    /// Settles a whole move batch only after every claimed operation has
    /// completed or failed. Earlier successful siblings remain reversible.
    private static func finishMoveJournal(_ db: Database, journalID: Int64) throws {
        let pending = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM archive_queue WHERE journal_id = ?",
            arguments: [journalID]
        ) ?? 0
        guard pending == 0 else { return }
        let entries = try Self.journalEntries(db, journalID: journalID)
        let requested = try Bool.fetchOne(
            db,
            sql: "SELECT undo_requested FROM op_journal WHERE id = ?",
            arguments: [journalID]
        ) ?? false
        guard !entries.isEmpty else {
            try Self.setJournalState(
                db, journalID: journalID,
                state: requested ? JournalState.undone : JournalState.rejected
            )
            return
        }
        guard entries.allSatisfy({
            $0.destinationFolder != nil
                && $0.destinationUIDValidity != nil
                && $0.destinationUID != nil
        }) else {
            try Self.setJournalState(db, journalID: journalID, state: JournalState.irreversible)
            return
        }
        if requested {
            try Self.enqueueInverseMoves(db, journalID: journalID, entries: entries)
        }
        try Self.setJournalState(
            db, journalID: journalID,
            state: requested ? JournalState.undone : JournalState.completed
        )
    }
    /// Advances locators in older journals after a UID-changing move. Flag
    /// entries follow the message's current source; move entries retain their
    /// original source as the desired return folder and advance only their
    /// recorded destination.
    private static func rewriteDependentJournalIdentities(
        _ db: Database,
        account: AccountID,
        sourceFolder: FolderID,
        sourceUIDValidity: UInt32,
        sourceUID: IMAPUID,
        destinationFolder: FolderID,
        destinationUIDValidity: UInt32,
        destinationUID: IMAPUID,
        excluding journalID: Int64?
    ) throws {
        var flagSQL = """
            UPDATE op_journal_entries
            SET source_folder_id = ?, source_uid_validity = ?, source_uid = ?
            WHERE account_id = ?
              AND source_folder_id = ? AND source_uid_validity = ? AND source_uid = ?
              AND journal_id IN (
                  SELECT id FROM op_journal
                  WHERE kind = ? AND state IN (?, ?)
              )
            """
        var flagArguments: StatementArguments = [
            destinationFolder.rawValue,
            Int64(destinationUIDValidity),
            Int64(destinationUID.rawValue),
            account.rawValue,
            sourceFolder.rawValue,
            Int64(sourceUIDValidity),
            Int64(sourceUID.rawValue),
            JournalKind.flags,
            JournalState.active,
            JournalState.completed,
        ]
        if let journalID {
            flagSQL += " AND journal_id <> ?"
            flagArguments += [journalID]
        }
        try db.execute(sql: flagSQL, arguments: flagArguments)

        var moveSQL = """
            UPDATE op_journal_entries
            SET destination_folder_id = ?, destination_uid_validity = ?, destination_uid = ?
            WHERE account_id = ?
              AND destination_folder_id = ? AND destination_uid_validity = ? AND destination_uid = ?
              AND journal_id IN (
                  SELECT id FROM op_journal
                  WHERE kind = ? AND state IN (?, ?)
              )
            """
        var moveArguments: StatementArguments = [
            destinationFolder.rawValue,
            Int64(destinationUIDValidity),
            Int64(destinationUID.rawValue),
            account.rawValue,
            sourceFolder.rawValue,
            Int64(sourceUIDValidity),
            Int64(sourceUID.rawValue),
            JournalKind.move,
            JournalState.active,
            JournalState.completed,
        ]
        if let journalID {
            moveSQL += " AND journal_id <> ?"
            moveArguments += [journalID]
        }
        try db.execute(sql: moveSQL, arguments: moveArguments)
    }
    private struct JournalHeader: Sendable {
        let id: Int64
        let kind: String
        let state: String
    }

    private struct MoveSourceRow: Sendable {
        let account: AccountID
        let folder: FolderID
        let uidValidity: UInt32
        let uid: IMAPUID
        let isRead: Bool
        let isFlagged: Bool
        var destinationFolder: FolderID?
    }

    private static func uniqueIDs(_ ids: [MessageID]) -> [MessageID] {
        var result: [MessageID] = []
        result.reserveCapacity(ids.count)
        var seen = Set<MessageID>()
        for id in ids where seen.insert(id).inserted { result.append(id) }
        return result
    }

    private static func insertJournal(_ db: Database, kind: String) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO op_journal (kind, created_at, state) VALUES (?, ?, ?)",
            arguments: [kind, Date().timeIntervalSince1970, JournalState.active]
        )
        return db.lastInsertedRowID
    }

    private static func insertJournalEntry(
        _ db: Database,
        journalID: Int64,
        account: AccountID,
        sourceFolder: FolderID,
        sourceUIDValidity: UInt32,
        sourceUID: IMAPUID,
        destinationFolder: FolderID? = nil,
        oldIsRead: Bool,
        oldIsFlagged: Bool,
        flag: FlagKind? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO op_journal_entries (
                    journal_id, account_id, source_folder_id, source_uid_validity, source_uid,
                    destination_folder_id, old_is_read, old_is_flagged, flag
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                journalID,
                account.rawValue,
                sourceFolder.rawValue,
                Int64(sourceUIDValidity),
                Int64(sourceUID.rawValue),
                destinationFolder?.rawValue,
                oldIsRead,
                oldIsFlagged,
                flag?.rawValue,
            ]
        )
    }

    private static func flagMessageState(
        _ db: Database,
        id: MessageID
    ) throws -> (id: MessageID, account: AccountID, folder: FolderID, uidValidity: UInt32, uid: IMAPUID, isRead: Bool, isFlagged: Bool)? {
        guard let canonicalID = try Self.resolveMessageID(db, id: id),
              let row = try Row.fetchOne(
            db,
            sql: """
                SELECT m.id, m.uid, m.is_read, m.is_flagged,
                       g.folder_id, g.uid_validity, f.account_id
                FROM messages m
                JOIN generations g ON g.id = m.generation_id AND g.state = 'live'
                JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                WHERE m.id = ?
                """,
            arguments: [canonicalID.rawValue]
        ) else { return nil }
        return (
            MessageID(rawValue: row["id"]),
            AccountID(rawValue: row["account_id"]),
            FolderID(rawValue: row["folder_id"]),
            UInt32(row["uid_validity"] as Int64),
            IMAPUID(rawValue: UInt32(row["uid"] as Int64)),
            row["is_read"],
            row["is_flagged"]
        )
    }

    private static func moveMessageState(_ db: Database, id: MessageID) throws -> MoveSourceRow? {
        guard let canonicalID = try Self.resolveMessageID(db, id: id),
              let row = try Row.fetchOne(
            db,
            sql: """
                SELECT m.uid, m.is_read, m.is_flagged,
                       g.folder_id, g.uid_validity, f.account_id
                FROM messages m
                JOIN generations g ON g.id = m.generation_id AND g.state = 'live'
                JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                WHERE m.id = ?
                """,
            arguments: [canonicalID.rawValue]
        ) else { return nil }
        return MoveSourceRow(
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            uidValidity: UInt32(row["uid_validity"] as Int64),
            uid: IMAPUID(rawValue: UInt32(row["uid"] as Int64)),
            isRead: row["is_read"],
            isFlagged: row["is_flagged"],
            destinationFolder: nil
        )
    }

    private static func latestJournal(_ db: Database) throws -> JournalHeader? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, kind, state FROM op_journal
                WHERE state NOT IN (?, ?)
                ORDER BY created_at DESC, id DESC LIMIT 1
                """,
            arguments: [JournalState.undone, JournalState.rejected]
        ) else { return nil }
        return JournalHeader(id: row["id"], kind: row["kind"], state: row["state"])
    }

    private static func journalAllowed(
        _ db: Database,
        journalID: Int64,
        allowedAccountLinks: Set<AccountLinkID>?
    ) throws -> Bool {
        guard let allowedAccountLinks else { return true }
        let values = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT a.account_link_id
                FROM op_journal_entries e
                JOIN accounts a ON a.id = e.account_id
                WHERE e.journal_id = ? AND e.state = 'active'
                """,
            arguments: [journalID]
        )
        return values.allSatisfy { raw in
            guard let id = AccountLinkID(uuidString: raw) else { return false }
            return allowedAccountLinks.contains(id)
        }
    }

    private static func journalEntries(_ db: Database, journalID: Int64) throws -> [JournalEntry] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, account_id, source_folder_id, source_uid_validity, source_uid,
                       destination_folder_id, destination_uid_validity, destination_uid,
                       old_is_read, old_is_flagged, flag
                FROM op_journal_entries WHERE journal_id = ? AND state = 'active' ORDER BY id ASC
                """,
            arguments: [journalID]
        ).map { row in
            let flagRaw: String? = row["flag"]
            return JournalEntry(
                id: row["id"],
                account: AccountID(rawValue: row["account_id"]),
                sourceFolder: FolderID(rawValue: row["source_folder_id"]),
                sourceUIDValidity: UInt32(row["source_uid_validity"] as Int64),
                sourceUID: IMAPUID(rawValue: UInt32(row["source_uid"] as Int64)),
                destinationFolder: (row["destination_folder_id"] as Int64?).map(FolderID.init(rawValue:)),
                destinationUIDValidity: (row["destination_uid_validity"] as Int64?).map(UInt32.init),
                destinationUID: (row["destination_uid"] as Int64?).map { IMAPUID(rawValue: UInt32($0)) },
                oldIsRead: row["old_is_read"],
                oldIsFlagged: row["old_is_flagged"],
                flag: flagRaw.flatMap(FlagKind.init(rawValue:))
            )
        }
    }

    private static func undoFlags(_ db: Database, journalID: Int64, entries: [JournalEntry]) throws {
        // Validate every current identity and flag before writing any inverse.
        var current: [(JournalEntry, Bool)] = []
        current.reserveCapacity(entries.count)
        for entry in entries {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT m.is_read, m.is_flagged
                    FROM messages m
                    JOIN generations g ON g.id = m.generation_id
                    WHERE g.folder_id = ? AND g.uid_validity = ? AND m.uid = ?
                      AND g.state = 'live'
                    """,
                arguments: [entry.sourceFolder.rawValue, Int64(entry.sourceUIDValidity), Int64(entry.sourceUID.rawValue)]
            ), let flag = entry.flag else {
                throw MailUndoError.irreversible("a message identity is no longer current")
            }
            let desired = flag == .seen ? entry.oldIsRead : entry.oldIsFlagged
            let actual: Bool = flag == .seen ? row["is_read"] : row["is_flagged"]
            current.append((entry, actual != desired))
        }
        for (entry, changed) in current where changed {
            guard let flag = entry.flag else { continue }
            let desired = flag == .seen ? entry.oldIsRead : entry.oldIsFlagged
            try db.execute(
                sql: """
                    INSERT INTO seen_queue (
                        account_id, folder_id, uid_validity, uid, enqueued_at, flag, "set", journal_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                    ON CONFLICT(account_id, folder_id, uid_validity, uid, flag) DO UPDATE SET
                        enqueued_at = excluded.enqueued_at, "set" = excluded."set", journal_id = NULL
                    """,
                arguments: [
                    entry.account.rawValue,
                    entry.sourceFolder.rawValue,
                    Int64(entry.sourceUIDValidity),
                    Int64(entry.sourceUID.rawValue),
                    Date().timeIntervalSince1970,
                    flag.rawValue,
                    desired,
                ]
            )
            let column = flag == .seen ? "is_read" : "is_flagged"
            try db.execute(
                sql: """
                    UPDATE messages SET \(column) = ?
                    WHERE uid = ? AND generation_id IN (
                        SELECT id FROM generations WHERE folder_id = ? AND uid_validity = ? AND state = 'live'
                    )
                    """,
                arguments: [desired, Int64(entry.sourceUID.rawValue), entry.sourceFolder.rawValue, Int64(entry.sourceUIDValidity)]
            )
        }
        try Self.setJournalState(db, journalID: journalID, state: JournalState.undone)
    }

    private static func undoMoves(
        _ db: Database,
        journalID: Int64,
        entries: [JournalEntry],
        state: String
    ) throws {
        let pendingRows = try Row.fetchAll(
            db,
            sql: "SELECT id, folder_id, uid_validity, uid, claimed FROM archive_queue WHERE journal_id = ?",
            arguments: [journalID]
        )
        if !pendingRows.isEmpty {
            try Self.cancelUnclaimedMoves(db, journalID: journalID)
            let claimed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM archive_queue WHERE journal_id = ? AND claimed = 1",
                arguments: [journalID]
            ) ?? 0
            if claimed == 0 {
                let completedEntries = try Self.journalEntries(db, journalID: journalID)
                try Self.enqueueInverseMoves(db, journalID: journalID, entries: completedEntries)
                try Self.setJournalState(db, journalID: journalID, state: JournalState.undone)
            } else {
                try db.execute(
                    sql: "UPDATE op_journal SET state = ?, undo_requested = 1 WHERE id = ?",
                    arguments: [JournalState.undoRequested, journalID]
                )
            }
            return
        }
        let complete = entries.allSatisfy {
            $0.destinationFolder != nil
                && $0.destinationUIDValidity != nil
                && $0.destinationUID != nil
        }
        guard complete else {
            throw MailUndoError.irreversible("the server did not return exact destination identities")
        }
        try Self.enqueueInverseMoves(db, journalID: journalID, entries: entries)
        try Self.setJournalState(db, journalID: journalID, state: JournalState.undone)
    }

    private static func cancelUnclaimedMoves(_ db: Database, journalID: Int64) throws {
        try db.execute(
            sql: """
                UPDATE op_journal_entries
                SET state = ?
                WHERE journal_id = ? AND state = 'active'
                  AND EXISTS (
                      SELECT 1 FROM archive_queue q
                      WHERE q.journal_id = op_journal_entries.journal_id
                        AND q.claimed = 0
                        AND q.folder_id = op_journal_entries.source_folder_id
                        AND q.uid_validity = op_journal_entries.source_uid_validity
                        AND q.uid = op_journal_entries.source_uid
                  )
                """,
            arguments: [JournalState.rejected, journalID]
        )
        try db.execute(
            sql: "DELETE FROM archive_queue WHERE journal_id = ? AND claimed = 0",
            arguments: [journalID]
        )
    }

    private static func enqueueInverseMoves(_ db: Database, journalID: Int64, entries: [JournalEntry]) throws {
        // Validate every destination/source folder and account before the first
        // inverse queue write. This makes stale/partial batches all-or-nothing.
        for entry in entries {
            guard let destinationFolder = entry.destinationFolder,
                  let destinationUIDValidity = entry.destinationUIDValidity,
                  let destinationUID = entry.destinationUID,
                  destinationUIDValidity > 0,
                  destinationUID.rawValue > 0,
                  try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ? AND account_id = ? AND retired = 0)",
                    arguments: [destinationFolder.rawValue, entry.account.rawValue]
                  ) == true,
                  try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ? AND account_id = ? AND retired = 0)",
                    arguments: [entry.sourceFolder.rawValue, entry.account.rawValue]
                  ) == true else {
                throw MailUndoError.irreversible("a source or destination folder is no longer current")
            }
        }
        for entry in entries {
            let destinationFolder = entry.destinationFolder!
            let destinationUIDValidity = entry.destinationUIDValidity!
            let destinationUID = entry.destinationUID!
            try db.execute(
                sql: """
                    INSERT INTO archive_queue (
                        account_id, folder_id, uid_validity, uid, enqueued_at, copied,
                        destination, destination_folder_id, journal_id,
                        destination_uid_validity, destination_uid
                    ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, NULL, NULL, NULL)
                    ON CONFLICT(account_id, folder_id, uid_validity, uid) DO UPDATE SET
                        enqueued_at = excluded.enqueued_at,
                        destination = excluded.destination,
                        destination_folder_id = excluded.destination_folder_id,
                        copied = 0,
                        journal_id = NULL,
                        destination_uid_validity = NULL,
                        destination_uid = NULL
                    """,
                arguments: [
                    entry.account.rawValue,
                    destinationFolder.rawValue,
                    Int64(destinationUIDValidity),
                    Int64(destinationUID.rawValue),
                    Date().timeIntervalSince1970,
                    FolderRole.none.rawValue,
                    entry.sourceFolder.rawValue,
                ]
            )
            // Keep the cached source row until the inverse move completes.
            // The exact destination mapping can then relocate this row again,
            // preserving its stable local ID, body, parts and FTS entry.
        }
    }

    private static func setJournalState(_ db: Database, journalID: Int64, state: String) throws {
        try db.execute(
            sql: "UPDATE op_journal SET state = ?, completed_at = ? WHERE id = ?",
            arguments: [state, Date().timeIntervalSince1970, journalID]
        )
    }

    private static func pruneJournal(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM op_journal
            WHERE id NOT IN (
                SELECT id FROM op_journal ORDER BY created_at DESC, id DESC LIMIT 50
            )
              AND NOT EXISTS (SELECT 1 FROM seen_queue q WHERE q.journal_id = op_journal.id)
              AND NOT EXISTS (SELECT 1 FROM archive_queue q WHERE q.journal_id = op_journal.id)
            """)
    }

    private static func moveQueueMatches(_ db: Database, _ op: MoveOp) throws -> Bool {
        var sql = """
            SELECT EXISTS(
                SELECT 1 FROM archive_queue
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
        sql += ")"
        return try Bool.fetchOne(db, sql: sql, arguments: arguments) == true
    }
}
