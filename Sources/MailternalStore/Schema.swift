import Foundation
import GRDB

enum Schema {
    static let ftsTable = "messages_fts"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try createV1(db)
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
            t.uniqueKey(["account_id", "path"])
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX folders_object_id_uidx
            ON folders(account_id, object_id)
            WHERE object_id IS NOT NULL
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
        try db.execute(sql: """
            CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages BEGIN
              INSERT INTO messages_fts(rowid, subject, from_text, to_text, body_text)
              VALUES (new.id, new.subject, new.from_text, new.to_text, new.body_text);
            END;
            CREATE TRIGGER messages_fts_ad BEFORE DELETE ON messages BEGIN
              INSERT INTO messages_fts(messages_fts, rowid, subject, from_text, to_text, body_text)
              VALUES ('delete', old.id, old.subject, old.from_text, old.to_text, old.body_text);
            END;
            CREATE TRIGGER messages_fts_au AFTER UPDATE ON messages BEGIN
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
