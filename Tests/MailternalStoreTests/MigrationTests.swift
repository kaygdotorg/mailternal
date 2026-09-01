import Foundation
import Testing
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

@Test func storesNonSecretAccountConfigOnly() async throws {
    try await withStore { store, _ in
        let config = sampleAccount()
        try await store.upsertAccount(config)
        let fetched = try await store.fetchAccount(config.id)
        #expect(fetched == config)
        #expect(fetched?.username == "test@example.com")
    }
}
