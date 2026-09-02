import Foundation
import GRDB
import MailternalInterfaces

extension MailStore {
    /// Builds a link from the account's durable identity and the server mailbox
    /// locator, never from local database identifiers.
    public func makeDeepLink(account: AccountID, folder: FolderID) async throws -> MailternalDeepLink? {
        try await read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT a.account_link_id, f.path, f.object_id
                    FROM folders f
                    JOIN accounts a ON a.id = f.account_id
                    WHERE f.id = ? AND f.account_id = ? AND f.retired = 0
                    """,
                arguments: [folder.rawValue, account.rawValue]
            ), let accountLinkID = Self.accountLinkID(from: row),
            let folderLocator = Self.folderLocator(from: row) else { return nil }
            return .folder(accountLinkID: accountLinkID, folderLocator: folderLocator)
        }
    }

    /// Builds a link only for a message in the folder's current live
    /// UIDVALIDITY generation. Retired generations cannot produce links.
    public func makeDeepLink(account: AccountID, message: MessageID) async throws -> MailternalDeepLink? {
        try await read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT m.uid, g.uid_validity, f.path, f.object_id, a.account_link_id
                    FROM messages m
                    JOIN generations g ON g.id = m.generation_id AND g.state = ?
                    JOIN folders f ON f.id = g.folder_id AND f.live_generation_id = g.id
                    JOIN accounts a ON a.id = f.account_id
                    WHERE m.id = ? AND f.account_id = ? AND f.retired = 0
                    """,
                arguments: [GenerationState.live.rawValue, message.rawValue, account.rawValue]
            ),
            let accountLinkID = Self.accountLinkID(from: row),
            let folderLocator = Self.folderLocator(from: row) else { return nil }

            let rawValidity: Int64 = row["uid_validity"]
            let rawUID: Int64 = row["uid"]
            guard rawValidity > 0, rawValidity <= Int64(UInt32.max),
                  rawUID > 0, rawUID <= Int64(UInt32.max) else { return nil }
            return .message(
                accountLinkID: accountLinkID,
                folderLocator: folderLocator,
                uidValidity: UInt32(rawValidity),
                uid: IMAPUID(rawValue: UInt32(rawUID))
            )
        }
    }

    /// Resolves a cross-device link by account link ID and server mailbox
    /// locator. Message links additionally require the exact current generation.
    public func resolve(_ link: MailternalDeepLink) async throws -> MailternalDeepLinkResolution? {
        try await read { db in
            guard let folder = try Self.folderRow(db, accountLinkID: link.accountLinkID, locator: link.folderLocator) else {
                return nil
            }
            let folderID = FolderID(rawValue: folder["id"])
            switch link {
            case .folder:
                return .folder(folderID)
            case .message(_, _, let uidValidity, let uid):
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT m.id, m.from_display, m.subject, m.preview, m.internal_date,
                               m.is_read, m.has_attachments, m.is_flagged,
                               COALESCE(NULLIF(f.name, ''), CASE f.role
                                   WHEN 'inbox' THEN 'INBOX'
                                   WHEN 'archive' THEN 'Archive'
                                   WHEN 'trash' THEN 'Trash'
                                   WHEN 'junk' THEN 'Junk'
                                   WHEN 'sent' THEN 'Sent'
                                   WHEN 'drafts' THEN 'Drafts'
                                   ELSE f.path
                               END) AS folder_name
                        FROM messages m
                        JOIN generations g ON g.id = m.generation_id
                            AND g.folder_id = ? AND g.uid_validity = ? AND g.state = ?
                        JOIN folders f ON f.id = g.folder_id AND f.live_generation_id = g.id
                            AND f.retired = 0
                        WHERE m.uid = ?
                        """,
                    arguments: [
                        folderID.rawValue,
                        Int64(uidValidity),
                        GenerationState.live.rawValue,
                        Int64(uid.rawValue),
                    ]
                ) else { return nil }
                let messageID = MessageID(rawValue: row["id"])
                return .message(
                    folderID: folderID,
                    messageID: messageID,
                    row: Self.messageRow(from: row, preview: row["preview"])
                )
            }
        }
    }

    private static func accountLinkID(from row: Row) -> AccountLinkID? {
        guard let raw: String = row["account_link_id"] else { return nil }
        return AccountLinkID(uuidString: raw)
    }

    private static func folderLocator(from row: Row) -> FolderLocator? {
        let path: String = row["path"]
        let objectID: String? = row["object_id"]
        if let objectID, !objectID.isEmpty {
            return FolderLocator(kind: .object, value: objectID)
        }
        return FolderLocator(kind: .path, value: path)
    }

    private static func folderRow(
        _ db: Database,
        accountLinkID: AccountLinkID,
        locator: FolderLocator
    ) throws -> Row? {
        let sql: String
        switch locator.kind {
        case .object:
            sql = """
                SELECT f.id
                FROM folders f
                JOIN accounts a ON a.id = f.account_id
                WHERE a.account_link_id = ? AND f.object_id = ? AND f.retired = 0
                """
        case .path:
            sql = """
                SELECT f.id
                FROM folders f
                JOIN accounts a ON a.id = f.account_id
                WHERE a.account_link_id = ? AND f.path = ? AND f.retired = 0
                """
        }
        return try Row.fetchOne(
            db,
            sql: sql,
            arguments: [accountLinkID.uuidString, locator.value]
        )
    }
}
