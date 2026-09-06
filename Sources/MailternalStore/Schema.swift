import Foundation
import GRDB

enum Schema {
    static let ftsTable = "messages_fts"

    static var migrator: DatabaseMigrator {
        makeMigrator()
    }

    static func makeMigrator(
        progress: @escaping @Sendable (Int, Int, String) -> Void = { _, _, _ in },
        openProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) -> DatabaseMigrator {
        let total = 15
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            progress(1, total, "v1_initial")
            try createV1(db)
        }
        migrator.registerMigration("v2_folder_separator") { db in
            progress(2, total, "v2_folder_separator")
            try db.alter(table: "folders") { t in
                t.add(column: "separator", .text)
            }
        }
        migrator.registerMigration("v3_account_link_id") { db in
            progress(3, total, "v3_account_link_id")
            try db.alter(table: "accounts") { t in
                t.add(column: "account_link_id", .text)
            }

            let accountIDs = try String.fetchAll(db, sql: "SELECT id FROM accounts ORDER BY id")
            var used = Set<String>()
            for accountID in accountIDs {
                var linkID = UUID().uuidString.lowercased()
                while used.contains(linkID) {
                    linkID = UUID().uuidString.lowercased()
                }
                used.insert(linkID)
                try db.execute(
                    sql: "UPDATE accounts SET account_link_id = ? WHERE id = ?",
                    arguments: [linkID, accountID]
                )
            }
            try db.execute(
                sql: "CREATE UNIQUE INDEX accounts_account_link_id_uidx ON accounts(account_link_id)"
            )
        }
        migrator.registerMigration("v4_archive_queue") { db in
            progress(4, total, "v4_archive_queue")
            try db.create(table: "archive_queue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account_id", .text).notNull()
                t.column("folder_id", .integer).notNull()
                    .references("folders", onDelete: .cascade)
                t.column("uid_validity", .integer).notNull()
                t.column("uid", .integer).notNull()
                t.column("enqueued_at", .double).notNull()
                t.uniqueKey(["account_id", "folder_id", "uid_validity", "uid"])
            }
            try db.execute(sql: "CREATE INDEX archive_queue_send_idx ON archive_queue(enqueued_at, id)")
        }
        migrator.registerMigration("v5_archive_copied") { db in
            progress(5, total, "v5_archive_copied")
            try db.alter(table: "archive_queue") { t in
                t.add(column: "copied", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v6_move_destination") { db in
            progress(6, total, "v6_move_destination")
            try db.alter(table: "archive_queue") { t in
                t.add(column: "destination", .text).notNull().defaults(to: FolderRole.archive.rawValue)
            }
        }
        migrator.registerMigration("v7_flag_queue") { db in
            progress(7, total, "v7_flag_queue")
            // The original seen queue was unique per message. Rebuild it so
            // independent \Seen and \Flagged mutations can coexist while
            // retaining every existing operation as a pending read.
            try db.execute(sql: "DROP INDEX IF EXISTS seen_queue_send_idx")
            try db.execute(sql: "ALTER TABLE seen_queue RENAME TO seen_queue_v6")
            try db.execute(sql: """
                CREATE TABLE seen_queue (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL,
                    folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                    uid_validity INTEGER NOT NULL,
                    uid INTEGER NOT NULL,
                    enqueued_at DOUBLE NOT NULL,
                    flag TEXT NOT NULL DEFAULT 'seen',
                    "set" BOOLEAN NOT NULL DEFAULT 1,
                    UNIQUE(account_id, folder_id, uid_validity, uid, flag)
                )
                """)
            try db.execute(sql: """
                INSERT INTO seen_queue (
                    id, account_id, folder_id, uid_validity, uid, enqueued_at, flag, "set"
                )
                SELECT id, account_id, folder_id, uid_validity, uid, enqueued_at, 'seen', 1
                FROM seen_queue_v6
                """)
            try db.execute(sql: "DROP TABLE seen_queue_v6")
            try db.execute(sql: "CREATE INDEX seen_queue_send_idx ON seen_queue(enqueued_at, id)")
        }
        migrator.registerMigration("v8_remote_image_references") { db in
            progress(8, total, "v8_remote_image_references")
            // Existing rows are left NULL so detail() can derive the value
            // from their already-sanitized token stream and backfill lazily.
            try db.alter(table: "messages") { t in
                t.add(column: "has_remote_references", .boolean)
            }
        }
        migrator.registerMigration("v9_move_destination_folder_id") { db in
            progress(9, total, "v9_move_destination_folder_id")
            try db.alter(table: "archive_queue") { t in
                t.add(column: "destination_folder_id", .integer)
            }
        }
        migrator.registerMigration("v10_unread_index", foreignKeyChecks: .immediate) { db in
            progress(10, total, "v10_unread_index")
            openProgress("migration-v10-begin")
            // Folder unread counts run at launch and after every write. Without
            // this partial index the count visits every row of the generation
            // (107 ms warm, 1.3 s cold on a 1 GB store); with it the count is
            // index-only and stays proportional to the unread rows.
            openProgress("index-build-begin")
            try db.execute(sql: """
                CREATE INDEX messages_unread_idx
                ON messages(generation_id) WHERE is_read = 0
                """)
            openProgress("index-build-end")
            openProgress("migration-v10-end")
        }
        migrator.registerMigration("v11_keep_locally", foreignKeyChecks: .immediate) { db in
            progress(11, total, "v11_keep_locally")
            openProgress("migration-v11-begin")
            try db.alter(table: "folders") { t in
                // Keep system mailboxes useful by default; custom folders opt
                // into local history only when the user asks for it.
                t.add(column: "keep_locally", .boolean).notNull().defaults(to: true)
                // STATUS/SELECT counts remain visible while local rows are
                // disabled. This is deliberately separate from message rows.
                t.add(column: "server_message_count", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                UPDATE folders
                SET keep_locally = CASE role
                    WHEN 'inbox' THEN 1
                    WHEN 'sent' THEN 1
                    WHEN 'drafts' THEN 1
                    WHEN 'archive' THEN 1
                    WHEN 'trash' THEN 1
                    WHEN 'junk' THEN 1
                    ELSE 0
                END
                """)
            openProgress("migration-v11-end")
        }
        migrator.registerMigration("v12_account_enabled", foreignKeyChecks: .immediate) { db in
            progress(12, total, "v12_account_enabled")
            openProgress("migration-v12-begin")
            try db.alter(table: "accounts") { t in
                t.add(column: "is_enabled", .integer).notNull().defaults(to: 1)
            }
            openProgress("migration-v12-end")
        }
        migrator.registerMigration("v13_folder_rename_queue", foreignKeyChecks: .immediate) { db in
            progress(13, total, "v13_folder_rename_queue")
            openProgress("migration-v13-begin")
            try db.create(table: "folder_rename_queue") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account_id", .text).notNull()
                t.column("folder_id", .integer).notNull()
                    .references("folders", onDelete: .cascade)
                t.column("target_name", .text).notNull()
                t.column("target_path", .text).notNull()
                t.column("enqueued_at", .double).notNull()
                t.uniqueKey(["folder_id"])
            }
            try db.execute(
                sql: "CREATE INDEX folder_rename_queue_send_idx ON folder_rename_queue(enqueued_at, id)"
            )
            openProgress("migration-v13-end")
        }
        migrator.registerMigration("v14_list_sort_indexes", foreignKeyChecks: .immediate) { db in
            progress(14, total, "v14_list_sort_indexes")
            openProgress("migration-v14-begin")
            // Every configurable keyset order has a generation-prefixed index.
            // SQLite can scan each index in either direction for the requested
            // ASC/DESC order while retaining the UID tie-breaker.
            openProgress("sort-index-build-begin")
            openProgress("sort-index-sender-begin")
            try db.execute(sql: """
                CREATE INDEX messages_sender_page_idx
                ON messages(generation_id, from_display, uid)
                """)
            openProgress("sort-index-sender-end")
            openProgress("sort-index-subject-begin")
            try db.execute(sql: """
                CREATE INDEX messages_subject_page_idx
                ON messages(generation_id, subject, uid)
                """)
            openProgress("sort-index-subject-end")
            openProgress("sort-index-read-begin")
            try db.execute(sql: """
                CREATE INDEX messages_read_page_idx
                ON messages(generation_id, is_read, uid)
                """)
            openProgress("sort-index-read-end")
            openProgress("sort-index-flagged-begin")
            try db.execute(sql: """
                CREATE INDEX messages_flagged_page_idx
                ON messages(generation_id, is_flagged, uid)
                """)
            openProgress("sort-index-flagged-end")
            openProgress("sort-index-attachments-begin")
            try db.execute(sql: """
                CREATE INDEX messages_attachments_page_idx
                ON messages(generation_id, has_attachments, uid)
                """)
            openProgress("sort-index-attachments-end")
            openProgress("sort-index-build-end")
            openProgress("migration-v14-end")
        }
        migrator.registerMigration("v15_account_link_commands", foreignKeyChecks: .immediate) { db in
            progress(15, total, "v15_account_link_commands")
            openProgress("migration-v15-begin")
            try db.create(table: "account_link_commands") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account_id", .text).notNull()
                    .references("accounts", onDelete: .cascade)
                t.column("source", .text).notNull()
                t.column("destination", .text).notNull()
                t.column("enqueued_at", .double).notNull()
                t.column("completed_at", .double)
            }
            openProgress("migration-v15-end")
        }

        return migrator
    }

    private static func createV1(_ db: Database) throws {
        try db.create(table: "accounts") { t in
            t.column("id", .text).primaryKey()
            t.column("display_name", .text).notNull()
            t.column("email_address", .text).notNull()
            t.column("username", .text).notNull()
            t.column("imap_host", .text).notNull()
            t.column("imap_port", .integer).notNull()
            t.column("imap_security", .text).notNull()
        }

        try db.create(table: "folders") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("account_id", .text).notNull()
                .references("accounts", onDelete: .cascade)
            t.column("path", .text).notNull()
            t.column("name", .text).notNull()
            t.column("role", .text).notNull()
            t.column("object_id", .text)
            // No FK: circular with generations.live pointer.
            t.column("live_generation_id", .integer)
            // Retired folders stay until generation cleanup; path uniqueness
            // applies only to live rows so a path-only recreate can insert.
            t.column("retired", .boolean).notNull().defaults(to: false)
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX folders_object_id_uidx
            ON folders(account_id, object_id)
            WHERE object_id IS NOT NULL
            """)
        try db.execute(sql: """
            CREATE UNIQUE INDEX folders_account_path_uidx
            ON folders(account_id, path)
            WHERE retired = 0
            """)
        try db.execute(sql: "CREATE INDEX folders_account_idx ON folders(account_id)")

        try db.create(table: "generations") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("folder_id", .integer).notNull()
                .references("folders", onDelete: .cascade)
            t.column("uid_validity", .integer).notNull()
            t.column("state", .text).notNull()
            t.column("created_at", .double).notNull()
            t.uniqueKey(["folder_id", "uid_validity"])
        }
        try db.execute(sql: "CREATE INDEX generations_folder_state_idx ON generations(folder_id, state)")

        try db.create(table: "messages") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("generation_id", .integer).notNull()
                .indexed()
                .references("generations", onDelete: .cascade)
            t.column("uid", .integer).notNull()
            t.column("subject", .text).notNull()
            t.column("from_json", .text).notNull()
            t.column("to_json", .text).notNull()
            t.column("cc_json", .text).notNull()
            t.column("reply_to_json", .text).notNull()
            t.column("from_text", .text).notNull()
            t.column("to_text", .text).notNull()
            t.column("from_display", .text).notNull()
            t.column("internal_date", .double).notNull()
            t.column("header_date", .double)
            t.column("rfc_message_id", .text)
            t.column("in_reply_to", .text)
            t.column("references_json", .text).notNull()
            t.column("is_read", .boolean).notNull().defaults(to: false)
            t.column("is_flagged", .boolean).notNull().defaults(to: false)
            t.column("is_answered", .boolean).notNull().defaults(to: false)
            t.column("is_draft", .boolean).notNull().defaults(to: false)
            t.column("is_deleted", .boolean).notNull().defaults(to: false)
            t.column("extra_flags_json", .text).notNull().defaults(to: "[]")
            t.column("has_attachments", .boolean).notNull().defaults(to: false)
            t.column("body_text", .text)
            t.column("sanitized_html", .text)
            t.column("preview", .text).notNull().defaults(to: "")
            t.column("is_truncated", .boolean).notNull().defaults(to: false)
            t.column("is_quarantined", .boolean).notNull().defaults(to: false)
            t.column("parse_defect", .text)
            t.column("attachments_json", .text).notNull().defaults(to: "[]")
            t.column("decoded_bytes", .integer).notNull().defaults(to: 0)
            t.uniqueKey(["generation_id", "uid"])
        }
        try db.execute(sql: """
            CREATE INDEX messages_page_idx
            ON messages(generation_id, internal_date DESC, uid DESC)
            """)

        try db.create(virtualTable: ftsTable, using: FTS5()) { t in
            t.content = "messages"
            t.contentRowID = "id"
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("subject")
            t.column("from_text")
            t.column("to_text")
            t.column("body_text")
        }

        // External-content FTS: delete while old content rows still exist
        // (spec: sync.md FTS). Insert/update after the content row is written.
        // Flag-only UPDATEs must not churn FTS (AFTER UPDATE OF content columns + WHEN).
        try db.execute(sql: """
            CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, subject, from_text, to_text, body_text)
              VALUES (new.id, new.subject, new.from_text, new.to_text, new.body_text);
            END;
            CREATE TRIGGER messages_fts_ad BEFORE DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, subject, from_text, to_text, body_text)
              VALUES ('delete', old.id, old.subject, old.from_text, old.to_text, old.body_text);
            END;
            CREATE TRIGGER messages_fts_au
            AFTER UPDATE OF subject, from_text, to_text, body_text ON messages
            WHEN old.subject IS NOT new.subject
              OR old.from_text IS NOT new.from_text
              OR old.to_text IS NOT new.to_text
              OR old.body_text IS NOT new.body_text
            BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, subject, from_text, to_text, body_text)
              VALUES ('delete', old.id, old.subject, old.from_text, old.to_text, old.body_text);
              INSERT INTO messages_fts(rowid, subject, from_text, to_text, body_text)
              VALUES (new.id, new.subject, new.from_text, new.to_text, new.body_text);
            END;
            """)
        try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")

        try db.create(table: "sync_state") { t in
            t.column("generation_id", .integer).primaryKey()
                .references("generations", onDelete: .cascade)
            t.column("delta_path", .text).notNull().defaults(to: DeltaPath.basic.rawValue)
            t.column("highest_modseq", .integer)
            t.column("backfill_phase", .text).notNull().defaults(to: BackfillPhase.idle.rawValue)
            t.column("low_water_uid", .integer)
            t.column("baseline_uid", .integer)
            t.column("progress", .double)
            t.column("halted_through", .double)
        }

        try db.create(table: "seen_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("account_id", .text).notNull()
            t.column("folder_id", .integer).notNull()
                .references("folders", onDelete: .cascade)
            t.column("uid_validity", .integer).notNull()
            t.column("uid", .integer).notNull()
            t.column("enqueued_at", .double).notNull()
            t.uniqueKey(["account_id", "folder_id", "uid_validity", "uid"])
        }
        try db.execute(sql: "CREATE INDEX seen_queue_send_idx ON seen_queue(enqueued_at, id)")

        try db.create(table: "error_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("occurred_at", .double).notNull()
            t.column("kind", .text).notNull()
            t.column("account_id", .text)
            t.column("folder_id", .integer)
            t.column("generation_id", .integer)
            t.column("uid", .integer)
            t.column("message", .text).notNull()
            t.column("detail", .text)
        }
        try db.execute(sql: "CREATE INDEX error_log_time_idx ON error_log(occurred_at DESC)")

        try db.create(table: "attachment_cache") { t in
            t.column("content_hash", .text).primaryKey()
            t.column("byte_size", .integer).notNull()
            t.column("last_access", .double).notNull()
        }
        try db.execute(sql: "CREATE INDEX attachment_cache_lru_idx ON attachment_cache(last_access)")
    }
}
