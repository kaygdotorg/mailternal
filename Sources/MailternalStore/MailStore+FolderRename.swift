import Foundation
import GRDB

extension MailStore {
    /// Enqueues one persisted mailbox rename. A later rename for the same folder
    /// replaces the target and enqueue time without creating a second operation.
    /// The folder row is intentionally not changed here: discovery remains the
    /// source of truth, so a failed terminal rename cannot leave a cosmetic path.
    public func enqueueFolderRename(folder: FolderID, to name: String) async throws {
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else { throw MailStoreError.invalidFolderName }
        let enqueuedAt = Date()
        try await write { db in
            let row = try MailStore.requireActiveFolder(db, folder)
            let currentPath: String = row["path"]
            let separator: String? = row["separator"]
            let targetPath = MailStore.folderRenamePath(
                currentPath: currentPath,
                targetName: targetName,
                separator: separator?.first
            )
            let account: String = row["account_id"]
            try db.execute(
                sql: """
                    INSERT INTO folder_rename_queue (
                        account_id, folder_id, target_name, target_path, enqueued_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(folder_id) DO UPDATE SET
                        account_id = excluded.account_id,
                        target_name = excluded.target_name,
                        target_path = excluded.target_path,
                        enqueued_at = excluded.enqueued_at
                    """,
                arguments: [
                    account,
                    folder.rawValue,
                    targetName,
                    targetPath,
                    enqueuedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    /// Returns pending folder renames in enqueue order. The queue is durable and
    /// therefore also contains operations left by a prior process invocation.
    public func snapshotFolderRenameQueue(limit: Int = 100) async throws -> [FolderRenameOp] {
        let cap = max(0, limit)
        return try await read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM folder_rename_queue ORDER BY enqueued_at ASC, id ASC LIMIT ?",
                arguments: [cap]
            )
            return rows.map(MailStore.folderRenameOp(from:))
        }
    }

    /// Tagged IMAP OK: remove one acknowledged rename operation. The target
    /// match keeps a newer coalesced edit from being deleted by an older send.
    public func dequeueFolderRename(_ op: FolderRenameOp) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    DELETE FROM folder_rename_queue
                    WHERE id = ? AND target_name = ? AND target_path = ?
                    """,
                arguments: [op.id, op.targetName, op.targetPath]
            )
        }
    }

    /// Applies a tagged-OK rename to the local folder tree and dequeues it in
    /// one transaction. Matching the target protects a newer coalesced edit
    /// from being overwritten by an older in-flight server command.
    public func applyFolderRename(_ op: FolderRenameOp) async throws {
        try await write { db in
            guard try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM folder_rename_queue
                    WHERE id = ? AND target_name = ? AND target_path = ?
                    """,
                arguments: [op.id, op.targetName, op.targetPath]
            ) != nil else {
                return
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT path, separator FROM folders
                    WHERE id = ? AND account_id = ? AND retired = 0
                    """,
                arguments: [op.folder.rawValue, op.account.rawValue]
            ) else {
                try db.execute(
                    sql: "DELETE FROM folder_rename_queue WHERE id = ?",
                    arguments: [op.id]
                )
                return
            }

            let oldPath: String = row["path"]
            let rawSeparator: String? = row["separator"]
            let separator = rawSeparator?.first ?? "/"
            try db.execute(
                sql: """
                    UPDATE folders
                    SET path = ?, name = ?
                    WHERE id = ? AND account_id = ? AND retired = 0
                    """,
                arguments: [op.targetPath, op.targetName, op.folder.rawValue, op.account.rawValue]
            )

            let oldPrefix = oldPath + String(separator)
            let newPrefix = op.targetPath + String(separator)
            if oldPrefix != newPrefix {
                let descendants = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, path FROM folders
                        WHERE account_id = ? AND retired = 0 AND id != ?
                        """,
                    arguments: [op.account.rawValue, op.folder.rawValue]
                )
                for descendant in descendants {
                    let path: String = descendant["path"]
                    guard path.hasPrefix(oldPrefix) else { continue }
                    let suffix = String(path.dropFirst(oldPrefix.count))
                    try db.execute(
                        sql: "UPDATE folders SET path = ? WHERE id = ?",
                        arguments: [newPrefix + suffix, descendant["id"]]
                    )
                }
            }

            try db.execute(
                sql: """
                    DELETE FROM folder_rename_queue
                    WHERE id = ? AND target_name = ? AND target_path = ?
                    """,
                arguments: [op.id, op.targetName, op.targetPath]
            )
        }
    }

    /// Tagged IMAP NO/BAD or a retired/mismatched folder: remove the operation
    /// and record a user-visible error in the same transaction.
    public func dropFolderRename(_ op: FolderRenameOp, reason: String) async throws {
        try await write { db in
            try db.execute(
                sql: """
                    DELETE FROM folder_rename_queue
                    WHERE id = ? AND target_name = ? AND target_path = ?
                    """,
                arguments: [op.id, op.targetName, op.targetPath]
            )
            try MailStore.insertError(
                db,
                StoreLogEntry(
                    kind: .sync,
                    account: op.account,
                    folder: op.folder,
                    message: "Couldn’t rename folder",
                    detail: reason
                )
            )
        }
    }

    /// Replaces only the terminal component of a mailbox path. The persisted
    /// separator is authoritative; LIST's historical `/` fallback is used only
    /// when a server omitted the separator.
    static func folderRenamePath(
        currentPath: String,
        targetName: String,
        separator: Character?
    ) -> String {
        let separator = separator ?? "/"
        guard let lastSeparator = currentPath.lastIndex(of: separator) else {
            return targetName
        }
        let prefixEnd = currentPath.index(after: lastSeparator)
        return String(currentPath[..<prefixEnd]) + targetName
    }

    static func folderRenameOp(from row: Row) -> FolderRenameOp {
        let enqueuedAt: Double = row["enqueued_at"]
        return FolderRenameOp(
            id: row["id"],
            account: AccountID(rawValue: row["account_id"]),
            folder: FolderID(rawValue: row["folder_id"]),
            targetName: row["target_name"],
            targetPath: row["target_path"],
            enqueuedAt: Date(timeIntervalSince1970: enqueuedAt)
        )
    }
}
