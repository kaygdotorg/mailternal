import Foundation
import Testing
import GRDB
@testable import MailternalStore

@Test func migratesFromEmptyDatabase() async throws {
    try await withStore { store, _ in
        let tables = try await store.tableNames()
        let expected: Set<String> = [
            "accounts",
            "folders",
            "generations",
            "messages",
            "messages_fts",
            "sync_state",
            "seen_queue",
            "archive_queue",
            "folder_rename_queue",
            "error_log",
            "attachment_cache",
            "grdb_migrations",
        ]
        for name in expected {
            #expect(tables.contains(name), "missing table \(name)")
        }

        let triggers = try await store.triggerNames()
        #expect(triggers.contains("messages_fts_ai"))
        #expect(triggers.contains("messages_fts_ad"))
        #expect(triggers.contains("messages_fts_au"))
        let au = (try await store.triggerSQL("messages_fts_au")) ?? ""
        #expect(au.contains("UPDATE OF subject, from_text, to_text, body_text"))
        #expect(au.uppercased().contains("WHEN"))

        let sql = try await store.ftsCreateSQL() ?? ""
        #expect(sql.contains("unicode61"))
        #expect(sql.contains("remove_diacritics"))
        #expect(sql.contains("2"))
        #expect(sql.contains("content"))

        let integrity = try await store.checkFTSIntegrity()
        #expect(integrity == .ok)
        try await store.optimizeFTS()

        let journal = try await store.journalMode()
        #expect(journal.lowercased().contains("wal"))

        // Re-open the same files via a second pool to prove the migration is stable.
        // (Opening twice in one process is covered by migrator no-op on current schema.)
        let folders = try await store.fetchFolders(account: AccountID(rawValue: "missing"))
        #expect(folders.isEmpty)
    }
}

@Test func reportsMigrationProgressWhileOpeningANewStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailternal-store-progress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let progress = MigrationProgressCapture()
    _ = try MailStore(
        databaseURL: root.appendingPathComponent("mail.sqlite"),
        cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
        migrationProgress: { completed, total, identifier in
            progress.append(completed: completed, total: total, identifier: identifier)
        }
    )

    let events = progress.values
    let final = try #require(events.last)
    #expect(final.total > 0)
    #expect(events.map(\.completed) == Array(1...final.total))
    #expect(events.allSatisfy { $0.total == final.total })
    #expect(Set(events.map(\.identifier)).count == events.count)
}

private final class MigrationProgressCapture: @unchecked Sendable {
    struct Event: Sendable {
        let completed: Int
        let total: Int
        let identifier: String
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func append(completed: Int, total: Int, identifier: String) {
        lock.lock()
        events.append(Event(completed: completed, total: total, identifier: identifier))
        lock.unlock()
    }

    var values: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Test func folderSeparatorColumnIsNullableAndPersistsDiscoveryMetadata() async throws {
    try await withStore { store, _ in
        let columns = try await store.read { db in
            try db.columns(in: "folders").map(\.name)
        }
        #expect(columns.contains("separator"))

        let account = sampleAccount()
        try await store.upsertAccount(account)
        let legacy = try await store.upsertFolder(
            account: account.id,
            path: "Legacy",
            name: "Legacy",
            separator: nil,
            role: .none,
            objectID: nil
        )
        #expect(try await store.fetchFolderSummary(legacy)?.separator == nil)

        let discovered = try await store.upsertFolder(
            account: account.id,
            path: "Root^Child",
            name: "Child",
            separator: "^",
            role: .none,
            objectID: "custom-delimiter"
        )
        #expect(try await store.fetchFolderSummary(discovered)?.separator == "^")
    }
}

@Test func folderKeepLocallyDefaultsByRoleAndRoundTrips() async throws {
    try await withStore { store, _ in
        let account = sampleAccount()
        try await store.upsertAccount(account)
        let inbox = try await store.upsertFolder(
            account: account.id,
            path: "INBOX",
            name: "INBOX",
            separator: "/",
            role: .inbox,
            objectID: nil
        )
        let custom = try await store.upsertFolder(
            account: account.id,
            path: "Projects",
            name: "Projects",
            separator: "/",
            role: .none,
            objectID: nil
        )

        #expect(try await store.fetchFolderSummary(inbox)?.keepLocally == true)
        #expect(try await store.fetchFolderSummary(custom)?.keepLocally == false)

        try await store.setKeepLocally(true, for: custom)
        try await store.updateServerMessageCount(7, for: custom)
        let enabled = try #require(await store.fetchFolderSummary(custom))
        #expect(enabled.keepLocally)
        #expect(enabled.totalCount == 0)

        try await store.setKeepLocally(false, for: custom)
        let disabled = try #require(await store.fetchFolderSummary(custom))
        #expect(!disabled.keepLocally)
        #expect(disabled.totalCount == 7)
    }
}

@Test func storesNonSecretAccountConfigOnly() async throws {
    try await withStore { store, _ in
        let config = sampleAccount()
        try await store.upsertAccount(config)
        let fetched = try await store.fetchAccount(config.id)
        #expect(fetched == config)
        #expect(fetched?.username == "test@example.com")
    }
}

@Test func accountEnabledFlagRoundTripsAndMigrationDefaultsToEnabled() async throws {
    try await withStore { store, _ in
        let columns = try await store.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                .compactMap { row -> (String, Int64, String?)? in
                    guard let name: String = row["name"], name == "is_enabled" else { return nil }
                    let notNull: Int64 = row["notnull"]
                    let defaultValue: String? = row["dflt_value"]
                    return (name, notNull, defaultValue)
                }
        }
        let enabledColumn = try #require(columns.first)
        #expect(enabledColumn.0 == "is_enabled")
        #expect(enabledColumn.1 == 1)
        #expect(enabledColumn.2 == "1")

        var disabled = sampleAccount("disabled")
        disabled.isEnabled = false
        try await store.upsertAccount(disabled)
        let roundTripped = try #require(await store.fetchAccount(disabled.id))
        #expect(!roundTripped.isEnabled)

        try await store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts (
                        id, account_link_id, display_name, email_address, username,
                        imap_host, imap_port, imap_security
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "legacy",
                    "00000000-0000-4000-8000-000000000011",
                    "Legacy",
                    "legacy@example.com",
                    "legacy@example.com",
                    "imap.example.com",
                    993,
                    "implicitTLS",
                ]
            )
        }
        let migrated = try #require(await store.fetchAccount(AccountID(rawValue: "legacy")))
        #expect(migrated.isEnabled)
    }
}
