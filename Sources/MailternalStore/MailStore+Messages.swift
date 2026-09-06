import Foundation
import GRDB

extension MailStore {
    /// Inserts or updates messages in bounded transactions (row count + decoded
    /// bytes). Cancellation is checked between batches; already-committed batches
    /// remain durable (spec: sync.md backfill).
    public func upsertMessages(
        _ messages: [IncomingMessage],
        budget: WriteBudget = .backfill
    ) async throws -> BatchWriteResult {
        var index = 0
        var committed = 0
        var txs = 0
        var bytes = 0
        var lastUID: IMAPUID?
        while index < messages.count {
            try Task.checkCancellation()
            var rowCount = 0
            var byteCount = 0
            var end = index
            while end < messages.count {
                let extra = messages[end].decodedBytes
                if rowCount > 0 && (rowCount >= budget.maxRows || byteCount + extra > budget.maxDecodedBytes) {
                    break
                }
                rowCount += 1
                byteCount += extra
                end += 1
            }
            let batchStart = index
            let batchEnd = end
            let batchRange = batchStart..<batchEnd
            try await write { db in
                for messageIndex in batchRange {
                    try MailStore.upsertMessage(db, messages[messageIndex])
                }
            }
            index = batchEnd
            committed += rowCount
            bytes += byteCount
            txs += 1
            lastUID = messages[batchRange].last?.uid
        }
        return BatchWriteResult(
            committedCount: committed,
            transactionCount: txs,
            committedDecodedBytes: bytes,
            lastCommittedUID: lastUID
        )
    }

    /// Expunges UIDs in budgeted transactions. FTS delete triggers fire per row.
    public func deleteUIDs(
        generation: MailboxGeneration,
        uids: [IMAPUID],
        budget: WriteBudget = .backfill
    ) async throws -> BatchWriteResult {
        var index = 0
        var committed = 0
        var txs = 0
        var lastUID: IMAPUID?
        while index < uids.count {
            try Task.checkCancellation()
            let end = min(index + budget.maxRows, uids.count)
            let batchStart = index
            let batchEnd = end
            let batchRange = batchStart..<batchEnd
            let gen = generation
            try await write { db in
                let genID = try MailStore.requireGenerationID(db, gen)
                for uidIndex in batchRange {
                    try db.execute(
                        sql: "DELETE FROM messages WHERE generation_id = ? AND uid = ?",
                        arguments: [genID, Int64(uids[uidIndex].rawValue)]
                    )
                }
            }
            index = batchEnd
            committed += batchRange.count
            txs += 1
            lastUID = uids[batchRange].last
        }
        return BatchWriteResult(
            committedCount: committed,
            transactionCount: txs,
            committedDecodedBytes: 0,
            lastCommittedUID: lastUID
        )
    }

    /// Applies remote flag deltas. Pending local flag operations take
    /// precedence over inbound state until their STORE is acknowledged.
    public func applyFlags(
        generation: MailboxGeneration,
        deltas: [FlagDelta]
    ) async throws {
        guard !deltas.isEmpty else { return }
        try await write { db in
            let genID = try MailStore.requireGenerationID(db, generation)
            let folderID = generation.folder.rawValue
            let uv = Int64(generation.uidValidity)
            for delta in deltas {
                let pendingRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT flag, "set" FROM seen_queue
                        WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                        """,
                    arguments: [folderID, uv, Int64(delta.uid.rawValue)]
                )
                var isRead = delta.flags.isRead
                var isFlagged = delta.flags.isFlagged
                for pending in pendingRows {
                    let flag = FlagKind(rawValue: pending["flag"] as String) ?? .seen
                    let set: Bool = pending["set"]
                    switch flag {
                    case .seen: isRead = set
                    case .flagged: isFlagged = set
                    }
                }
                try db.execute(
                    sql: """
                        UPDATE messages SET
                            is_read = ?, is_flagged = ?, is_answered = ?,
                            is_draft = ?, is_deleted = ?, extra_flags_json = ?
                        WHERE generation_id = ? AND uid = ?
                        """,
                    arguments: [
                        isRead,
                        isFlagged,
                        delta.flags.isAnswered,
                        delta.flags.isDraft,
                        delta.flags.isDeleted,
                        try StoreJSON.encode(delta.flags.extra),
                        genID,
                        Int64(delta.uid.rawValue),
                    ]
                )
            }
        }
    }

    /// Keyset page over the folder's live generation in `sort` order. Bodies
    /// are not selected. The UID is always the final stable tie-breaker.
    public func page(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) async throws -> MessagePage {
        try await read { db in
            try MailStore.fetchPage(
                db,
                folder: folder,
                after: cursor,
                limit: limit,
                sort: sort
            )
        }
    }

    /// Returns every message ID in the folder's current live generation in the
    /// same store-backed order as `page`. This is one indexed read: it does not
    /// materialize or sort the mailbox in Swift.
    public func messageIDs(in folder: FolderID, sort: MailListSort) async throws -> [MessageID] {
        try await read { db in
            let spec = MailStore.sortSpec(sort)
            let values = try Int64.fetchAll(
                db,
                sql: """
                    SELECT m.id
                    FROM messages m
                    JOIN folders f ON f.live_generation_id = m.generation_id
                    WHERE f.id = ? AND f.retired = 0
                    ORDER BY m.\(spec.column) \(spec.order), m.uid \(spec.order)
                    """,
                arguments: [folder.rawValue]
            )
            return values.map { MessageID(rawValue: $0) }
        }
    }

    /// `EXPLAIN QUERY PLAN` for the selected pagination order.
    public func explainPageQueryPlan(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) async throws -> String {
        try await read { db in
            try MailStore.explainPage(
                db,
                folder: folder,
                after: cursor,
                limit: limit,
                sort: sort
            )
        }
    }

    /// ValueObservation of the visible page window (spec: sync.md Storage).
    public func observePage(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) -> AsyncStream<MessagePage> {
        observe { db in
            try MailStore.fetchPage(
                db,
                folder: folder,
                after: cursor,
                limit: limit,
                sort: sort
            )
        }
    }

    public func detail(_ id: MessageID) async throws -> MessageDetail {
        let result = try await read { db in
            try MailStore.fetchDetailWithStorage(db, id: id)
        }
        if result.storedRemoteReferences == nil {
            // Do not put a schema backfill on the interactive detail path.
            // Existing stores have NULL here until they are touched, but the
            // derived value above is already correct for this response.
            let remoteReferences = result.detail.hasRemoteImageReferences
            Task { [self] in
                try? await write { db in
                    try db.execute(
                        sql: "UPDATE messages SET has_remote_references = ? WHERE id = ?",
                        arguments: [remoteReferences, id.rawValue]
                    )
                }
            }
        }
        return result.detail
    }

    /// Returns locally stored details in input order using one database read.
    ///
    /// Duplicate IDs are decoded once, missing rows are omitted, and decode or
    /// database errors are propagated. This path never performs remote work or
    /// schema backfills.
    public func details(_ ids: [MessageID]) async throws -> [MessageDetail] {
        let uniqueIDs: [MessageID] = {
            var uniqueIDs: [MessageID] = []
            uniqueIDs.reserveCapacity(ids.count)
            var seen = Set<MessageID>()
            for id in ids where seen.insert(id).inserted {
                uniqueIDs.append(id)
            }
            return uniqueIDs
        }()
        guard !uniqueIDs.isEmpty else { return [] }

        return try await read { db in
            var details: [MessageDetail] = []
            details.reserveCapacity(uniqueIDs.count)
            for id in uniqueIDs {
                do {
                    details.append(try MailStore.fetchDetailWithStorage(db, id: id).detail)
                } catch MailStoreError.messageNotFound {
                    continue
                }
            }
            return details
        }
    }

    public func messageID(generation: MailboxGeneration, uid: IMAPUID) async throws -> MessageID? {
        try await read { db in
            guard let genID = try MailStore.generationID(db, generation) else { return nil }
            guard let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM messages WHERE generation_id = ? AND uid = ?",
                arguments: [genID, Int64(uid.rawValue)]
            ) else { return nil }
            return MessageID(rawValue: id)
        }
    }

    /// IMAP locator for an on-demand BODY.PEEK / RFC822 fetch.
    ///
    /// Returns `nil` when the row is gone (expunged or retired-generation cleanup).
    public func messageRef(
        _ id: MessageID
    ) async throws -> (folder: FolderID, generation: MailboxGeneration, uid: IMAPUID)? {
        try await read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT g.folder_id, g.uid_validity, m.uid
                    FROM messages m
                    JOIN generations g ON g.id = m.generation_id
                    WHERE m.id = ?
                    """,
                arguments: [id.rawValue]
            ) else { return nil }
            let folderID: Int64 = row["folder_id"]
            let uidValidity: Int64 = row["uid_validity"]
            let uid: Int64 = row["uid"]
            let folder = FolderID(rawValue: folderID)
            return (
                folder,
                MailboxGeneration(folder: folder, uidValidity: UInt32(uidValidity)),
                IMAPUID(rawValue: UInt32(uid))
            )
        }
    }
    /// Returns the owning account for a message without exposing account
    /// secrets. Facades use this to dispatch mutations and on-demand fetches
    /// to the correct account engine.
    public func accountID(for message: MessageID) async throws -> AccountID? {
        try await read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT f.account_id
                    FROM messages m
                    JOIN generations g ON g.id = m.generation_id
                    JOIN folders f ON f.id = g.folder_id
                    WHERE m.id = ?
                    """,
                arguments: [message.rawValue]
            ).map(AccountID.init(rawValue:))
        }
    }

    /// Returns the owning account for a folder.
    public func accountID(for folder: FolderID) async throws -> AccountID? {
        try await read { db in
            try String.fetchOne(
                db,
                sql: "SELECT account_id FROM folders WHERE id = ?",
                arguments: [folder.rawValue]
            ).map(AccountID.init(rawValue:))
        }
    }

    /// UIDs stored for `generation`, optional inclusive range, ascending.
    ///
    /// Used by CONDSTORE/basic expunge reconciliation. A missing generation
    /// yields an empty array rather than an error.
    public func uids(
        in generation: MailboxGeneration,
        range: ClosedRange<UInt32>? = nil
    ) async throws -> [IMAPUID] {
        try await read { db in
            guard let genID = try MailStore.generationID(db, generation) else { return [] }
            let values: [Int64]
            if let range {
                values = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT uid FROM messages
                        WHERE generation_id = ? AND uid >= ? AND uid <= ?
                        ORDER BY uid ASC
                        """,
                    arguments: [genID, Int64(range.lowerBound), Int64(range.upperBound)]
                )
            } else {
                values = try Int64.fetchAll(
                    db,
                    sql: """
                        SELECT uid FROM messages
                        WHERE generation_id = ?
                        ORDER BY uid ASC
                        """,
                    arguments: [genID]
                )
            }
            return values.map { IMAPUID(rawValue: UInt32($0)) }
        }
    }

    /// Returns the highest stored UID for `generation`.
    ///
    /// The aggregate is evaluated against the messages generation/UID
    /// uniqueness index, so this does not materialize the generation's UIDs.
    /// A missing or empty generation returns `nil`.
    public func maximumUID(in generation: MailboxGeneration) async throws -> IMAPUID? {
        try await read { db in
            guard let genID = try MailStore.generationID(db, generation) else { return nil }
            let value: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(uid) FROM messages WHERE generation_id = ?",
                arguments: [genID]
            )
            return value.map { IMAPUID(rawValue: UInt32($0)) }
        }
    }

    private static func sortSpec(_ sort: MailListSort) -> (column: String, order: String) {
        // These identifiers are selected exclusively from this allowlist; no
        // caller-provided sort value is ever interpolated into SQL.
        switch sort.field {
        case .date:
            return ("internal_date", sort.direction == .ascending ? "ASC" : "DESC")
        case .sender:
            return ("from_display", sort.direction == .ascending ? "ASC" : "DESC")
        case .subject:
            return ("subject", sort.direction == .ascending ? "ASC" : "DESC")
        case .read:
            return ("is_read", sort.direction == .ascending ? "ASC" : "DESC")
        case .flagged:
            return ("is_flagged", sort.direction == .ascending ? "ASC" : "DESC")
        case .attachments:
            return ("has_attachments", sort.direction == .ascending ? "ASC" : "DESC")
        }
    }

    private static func validateCursor(
        _ cursor: MessagePageCursor?,
        sort: MailListSort
    ) throws {
        guard let cursor else { return }
        guard cursor.sort == sort else { throw MailStoreError.invalidPageCursor }
        switch (sort.field, cursor.value) {
        case (.date, .date(_)), (.sender, .sender(_)), (.subject, .subject(_)),
             (.read, .read(_)), (.flagged, .flagged(_)), (.attachments, .attachments(_)):
            return
        default:
            throw MailStoreError.invalidPageCursor
        }
    }

    private static func addCursorPredicate(
        to sql: inout String,
        arguments: inout StatementArguments,
        cursor: MessagePageCursor?,
        sort: MailListSort
    ) throws {
        guard let cursor else { return }
        try validateCursor(cursor, sort: sort)
        let comparison = sort.direction == .ascending ? ">" : "<"
        let value: any DatabaseValueConvertible
        switch (sort.field, cursor.value) {
        case (.date, .date(let date)):
            value = date.timeIntervalSince1970
        case (.sender, .sender(let text)), (.subject, .subject(let text)):
            value = text
        case (.read, .read(let state)), (.flagged, .flagged(let state)),
             (.attachments, .attachments(let state)):
            value = state
        default:
            throw MailStoreError.invalidPageCursor
        }
        let spec = sortSpec(sort)
        sql += " AND (m.\(spec.column) \(comparison) ? OR (m.\(spec.column) = ? AND m.uid \(comparison) ?))"
        arguments += [value, value, Int64(cursor.uid.rawValue)]
    }

    private static func cursor(from row: Row, sort: MailListSort) -> MessagePageCursor {
        let uid: Int64 = row["uid"]
        let value: MessagePageCursorValue
        switch sort.field {
        case .date:
            value = .date(Date(timeIntervalSince1970: row["internal_date"]))
        case .sender:
            value = .sender(row["from_display"])
        case .subject:
            value = .subject(row["subject"])
        case .read:
            value = .read(row["is_read"])
        case .flagged:
            value = .flagged(row["is_flagged"])
        case .attachments:
            value = .attachments(row["has_attachments"])
        }
        return MessagePageCursor(sort: sort, value: value, uid: IMAPUID(rawValue: UInt32(uid)))
    }

    static func fetchPage(
        _ db: Database,
        folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) throws -> MessagePage {
        try validateCursor(cursor, sort: sort)
        let cap = max(limit, 0)
        if cap == 0 { return MessagePage(rows: [], next: nil) }

        var sql = """
            SELECT m.id, m.from_display, m.from_text, m.subject, m.preview, m.internal_date, m.uid,
                   m.is_read, m.has_attachments, m.is_flagged,
                   f.id AS folder_id,
                   COALESCE(NULLIF(f.name, ''), CASE f.role
                       WHEN 'inbox' THEN 'INBOX'
                       WHEN 'archive' THEN 'Archive'
                       WHEN 'trash' THEN 'Trash'
                       WHEN 'junk' THEN 'Junk'
                       WHEN 'sent' THEN 'Sent'
                       WHEN 'drafts' THEN 'Drafts'
                       ELSE f.path END) AS folder_name,
                   COALESCE(NULLIF(a.display_name, ''), a.email_address) AS account_name
            FROM messages m
            JOIN folders f ON f.live_generation_id = m.generation_id
            JOIN accounts a ON a.id = f.account_id
            WHERE f.id = ? AND f.retired = 0
            """
        var arguments: StatementArguments = [folder.rawValue]
        try addCursorPredicate(to: &sql, arguments: &arguments, cursor: cursor, sort: sort)
        let spec = sortSpec(sort)
        sql += " ORDER BY m.\(spec.column) \(spec.order), m.uid \(spec.order) LIMIT ?"
        arguments += [cap + 1]
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        let hasMore = rows.count > cap
        let slice = hasMore ? Array(rows.prefix(cap)) : rows
        let mapped = slice.map { MailStore.messageRow(from: $0, preview: $0["preview"]) }
        let next = hasMore ? slice.last.map { MailStore.cursor(from: $0, sort: sort) } : nil
        return MessagePage(rows: mapped, next: next)
    }

    static func explainPage(
        _ db: Database,
        folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) throws -> String {
        try validateCursor(cursor, sort: sort)
        let cap = max(limit, 0)
        var sql = """
            SELECT m.id, m.from_display, m.subject, m.preview, m.internal_date, m.uid,
                   m.is_read, m.has_attachments, m.is_flagged,
                   f.id AS folder_id,
                   COALESCE(NULLIF(f.name, ''), CASE f.role
                       WHEN 'inbox' THEN 'INBOX'
                       WHEN 'archive' THEN 'Archive'
                       WHEN 'trash' THEN 'Trash'
                       WHEN 'junk' THEN 'Junk'
                       WHEN 'sent' THEN 'Sent'
                       WHEN 'drafts' THEN 'Drafts'
                       ELSE f.path END) AS folder_name
            FROM messages m
            JOIN folders f ON f.live_generation_id = m.generation_id
            WHERE f.id = ? AND f.retired = 0
            """
        var arguments: StatementArguments = [folder.rawValue]
        try addCursorPredicate(to: &sql, arguments: &arguments, cursor: cursor, sort: sort)
        let spec = sortSpec(sort)
        sql += " ORDER BY m.\(spec.column) \(spec.order), m.uid \(spec.order) LIMIT ?"
        arguments += [cap + 1]
        let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
        return rows.map { row -> String in
            if let detail: String = row["detail"] { return detail }
            return row.map { String(describing: $0.1) }.joined(separator: " | ")
        }.joined(separator: "\n")
    }
    static func messageRow(from row: Row, preview: String) -> MessageRow {
        let accountName: String? = row["account_name"]
        let folderRawValue: Int64? = row["folder_id"]
        return MessageRow(
            id: MessageID(rawValue: row["id"]),
            from: row["from_display"],
            senderAddress: row["from_text"],
            subject: row["subject"],
            preview: preview,
            date: Date(timeIntervalSince1970: row["internal_date"]),
            isRead: row["is_read"],
            hasAttachments: row["has_attachments"],
            isFlagged: row["is_flagged"],
            folderName: row["folder_name"],
            accountName: accountName,
            folderID: folderRawValue.map { FolderID(rawValue: $0) }
        )
    }
    private static let remoteTokenPrefix = "mailternal-part://part/remote."

    static func fetchDetail(_ db: Database, id: MessageID) throws -> MessageDetail {
        try fetchDetailWithStorage(db, id: id).detail
    }

    private static func fetchDetailWithStorage(
        _ db: Database,
        id: MessageID
    ) throws -> (detail: MessageDetail, storedRemoteReferences: Bool?) {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id.rawValue]) else {
            throw MailStoreError.messageNotFound
        }
        let from: [MailAddress] = try StoreJSON.decode([MailAddress].self, from: row["from_json"])
        let to: [MailAddress] = try StoreJSON.decode([MailAddress].self, from: row["to_json"])
        let cc: [MailAddress] = try StoreJSON.decode([MailAddress].self, from: row["cc_json"])
        let replyTo: [MailAddress] = try StoreJSON.decode([MailAddress].self, from: row["reply_to_json"])
        let references: [String] = try StoreJSON.decode([String].self, from: row["references_json"])
        let attachments = try StoreJSON.decode([AttachmentInfoDTO].self, from: row["attachments_json"]).map { $0.makeInfo() }
        let headerDate: Double? = row["header_date"]
        let rfcID: String? = row["rfc_message_id"]
        let inReplyTo: String? = row["in_reply_to"]
        let bodyText: String? = row["body_text"]
        let html: String? = row["sanitized_html"]
        let storedRemoteReferences: Bool? = row["has_remote_references"]
        let hasRemoteImageReferences = storedRemoteReferences
            ?? (html?.contains(remoteTokenPrefix) ?? false)
        let envelope = Envelope(
            subject: row["subject"],
            from: from,
            to: to,
            cc: cc,
            replyTo: replyTo,
            internalDate: Date(timeIntervalSince1970: row["internal_date"]),
            headerDate: headerDate.map { Date(timeIntervalSince1970: $0) },
            rfcMessageID: rfcID,
            inReplyTo: inReplyTo,
            references: references
        )
        let quarantined: Bool = row["is_quarantined"]
        return (
            MessageDetail(
                id: id,
                envelope: envelope,
                bodyText: bodyText,
                sanitizedHTML: html,
                hasRemoteImageReferences: hasRemoteImageReferences,
                attachments: attachments,
                isQuarantined: quarantined
            ),
            storedRemoteReferences
        )
    }

    static func upsertMessage(_ db: Database, _ message: IncomingMessage) throws {
        let genID = try requireGenerationID(db, message.generation)
        // A FETCH captured before enqueueMove must not resurrect the
        // optimistically hidden message. The queue entry is checked in the same
        // writer transaction as this upsert, so either ordering is safe.
        let pendingArchive = try Int.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM archive_queue
                    WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                )
                """,
            arguments: [
                message.generation.folder.rawValue,
                Int64(message.generation.uidValidity),
                Int64(message.uid.rawValue),
            ]
        ) == 1
        if pendingArchive { return }
        let env = message.envelope
        let fromJSON = try StoreJSON.encode(env.from)
        let toJSON = try StoreJSON.encode(env.to)
        let ccJSON = try StoreJSON.encode(env.cc)
        let replyJSON = try StoreJSON.encode(env.replyTo)
        let refsJSON = try StoreJSON.encode(env.references)
        let extraJSON = try StoreJSON.encode(message.flags.extra)
        let attJSON = try StoreJSON.encode(message.attachments.map(AttachmentInfoDTO.init))
        // Pending local moves must not be resurrected by a FETCH captured
        // before enqueueMove committed.
        let pendingFlags = try Row.fetchAll(
            db,
            sql: """
                SELECT flag, "set" FROM seen_queue
                WHERE folder_id = ? AND uid_validity = ? AND uid = ?
                """,
            arguments: [
                message.generation.folder.rawValue,
                Int64(message.generation.uidValidity),
                Int64(message.uid.rawValue),
            ]
        )
        var isRead = message.flags.isRead
        var isFlagged = message.flags.isFlagged
        for pending in pendingFlags {
            let flag = FlagKind(rawValue: pending["flag"] as String) ?? .seen
            let set: Bool = pending["set"]
            switch flag {
            case .seen: isRead = set
            case .flagged: isFlagged = set
            }
        }
        // Date-ordered primary key: id = (internal_date seconds << 22) + seq
        // within that second-bucket (writer-serialized, race-free). The FTS
        // external-content rowid inherits this order, so newest-first search is
        // `ORDER BY messages_fts.rowid DESC LIMIT n` — index order, no bm25
        // scoring or sorter over every match (QA: 180ms → sub-ms on 100k docs).
        let epoch = Int64(env.internalDate.timeIntervalSince1970)
        try db.execute(
            sql: """
                INSERT INTO messages (
                    id,
                    generation_id, uid, subject, from_json, to_json, cc_json, reply_to_json,
                    from_text, to_text, from_display, internal_date, header_date,
                    rfc_message_id, in_reply_to, references_json,
                    is_read, is_flagged, is_answered, is_draft, is_deleted, extra_flags_json,
                    has_attachments, body_text, sanitized_html, has_remote_references, preview,
                    is_truncated, is_quarantined, parse_defect, attachments_json, decoded_bytes
                ) VALUES (
                    COALESCE(
                        (SELECT MAX(id) + 1 FROM messages
                         WHERE id >= (CAST(?1 AS INTEGER) << 22)
                           AND id < ((CAST(?1 AS INTEGER) + 1) << 22)),
                        CAST(?1 AS INTEGER) << 22
                    ),
                    ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?
                )
                ON CONFLICT(generation_id, uid) DO UPDATE SET
                    subject = excluded.subject,
                    from_json = excluded.from_json,
                    to_json = excluded.to_json,
                    cc_json = excluded.cc_json,
                    reply_to_json = excluded.reply_to_json,
                    from_text = excluded.from_text,
                    to_text = excluded.to_text,
                    from_display = excluded.from_display,
                    internal_date = excluded.internal_date,
                    header_date = excluded.header_date,
                    rfc_message_id = excluded.rfc_message_id,
                    in_reply_to = excluded.in_reply_to,
                    references_json = excluded.references_json,
                    is_read = excluded.is_read,
                    is_flagged = excluded.is_flagged,
                    is_answered = excluded.is_answered,
                    is_draft = excluded.is_draft,
                    is_deleted = excluded.is_deleted,
                    extra_flags_json = excluded.extra_flags_json,
                    has_attachments = excluded.has_attachments,
                    body_text = excluded.body_text,
                    sanitized_html = excluded.sanitized_html,
                    has_remote_references = excluded.has_remote_references,
                    preview = excluded.preview,
                    is_truncated = excluded.is_truncated,
                    is_quarantined = excluded.is_quarantined,
                    parse_defect = excluded.parse_defect,
                    attachments_json = excluded.attachments_json,
                    decoded_bytes = excluded.decoded_bytes
                """,
            arguments: [
                epoch,
                genID,
                Int64(message.uid.rawValue),
                env.subject,
                fromJSON, toJSON, ccJSON, replyJSON,
                AddressFormat.ftsText(env.from),
                AddressFormat.ftsText(env.to) + " " + AddressFormat.ftsText(env.cc),
                AddressFormat.display(env.from),
                env.internalDate.timeIntervalSince1970,
                env.headerDate.map { $0.timeIntervalSince1970 },
                env.rfcMessageID,
                env.inReplyTo,
                refsJSON,
                isRead,
                isFlagged,
                message.flags.isAnswered,
                message.flags.isDraft,
                message.flags.isDeleted,
                extraJSON,
                !message.attachments.isEmpty,
                message.bodyText,
                message.sanitizedHTML,
                message.hasRemoteImageReferences,
                Preview.make(from: message.bodyText),
                message.isTruncated,
                message.isQuarantined,
                message.parseDefect,
                attJSON,
                message.decodedBytes,
            ]
        )
        if message.isQuarantined, let defect = message.parseDefect, !defect.isEmpty {
            let folderRow = try requireFolder(db, message.generation.folder)
            let accountID: String = folderRow["account_id"]
            try insertError(
                db,
                StoreLogEntry(
                    kind: .parse,
                    account: AccountID(rawValue: accountID),
                    folder: message.generation.folder,
                    generation: message.generation,
                    uid: message.uid,
                    message: defect
                )
            )
        }
    }
}
