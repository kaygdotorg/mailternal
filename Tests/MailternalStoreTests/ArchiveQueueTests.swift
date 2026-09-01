import Foundation
import Testing
@testable import MailternalStore

@Test func archiveQueueCoalescesAndOptimisticallyDeletesLocalMessage() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 3, subject: "archive me")
        ])
        let id = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 3)))

        try await store.enqueueArchive(message: id)
        try await store.enqueueArchive(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 3)
        )

        let pending = try await store.snapshotArchiveQueue()
        #expect(pending.count == 1)
        #expect(pending[0].uid.rawValue == 3)
        #expect(try await store.page(in: folder, after: nil, limit: 10).rows.isEmpty)
    }
}

@Test func archiveQueuePersistsCopiedPhaseFromV5Migration() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store)
        try await store.enqueueArchive(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 7)
        )

        let pendingOps = try await store.snapshotArchiveQueue()
        let pending = try #require(pendingOps.first)
        #expect(pending.copied == false)
        try await store.markArchiveCopied(pending)
        #expect(try await store.snapshotArchiveQueue().first?.copied == true)
    }
}

@Test func archiveQueueSkipsCapturedFetchAfterEnqueue() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        try await store.enqueueArchive(
            account: account.id,
            folder: folder,
            uidValidity: generation.uidValidity,
            uid: IMAPUID(rawValue: 12)
        )

        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 12, subject: "captured")
        ])
        #expect(try await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 12)
        ) == nil)
    }
}

@Test func archiveQueueDeleteClearsConcurrentResurrection() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        // Construct the interleave directly: a stale FETCH commits first,
        // then enqueueArchive's queue row appears before the drain dequeue.
        try await store.write { db in
            try MailStore.upsertMessage(
                db,
                makeMessage(generation: generation, uid: 13, subject: "resurrected")
            )
            try db.execute(
                sql: """
                    INSERT INTO archive_queue (
                        account_id, folder_id, uid_validity, uid, enqueued_at, copied
                    ) VALUES (?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    account.id.rawValue,
                    folder.rawValue,
                    Int64(generation.uidValidity),
                    13,
                    Date().timeIntervalSince1970,
                ]
            )
        }
        let pendingOps = try await store.snapshotArchiveQueue()
        let pending = try #require(pendingOps.first)
        try await store.deleteArchiveOp(pending)
        #expect(try await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 13)
        ) == nil)
    }
}

@Test func archiveQueueDropsStaleUIDValidity() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store, uidValidity: 1)
        try await store.enqueueArchive(
            account: account.id,
            folder: folder,
            uidValidity: 9,
            uid: IMAPUID(rawValue: 7)
        )
        #expect(try await store.snapshotArchiveQueue().count == 1)

        try await store.dropStaleArchive(folder: folder)

        #expect(try await store.snapshotArchiveQueue().isEmpty)
    }
}

@Test func archiveQueueDeleteRemovesOnlyAcknowledgedOperation() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store)
        try await store.enqueueArchive(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 10)
        )
        try await store.enqueueArchive(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 11)
        )
        let pending = try await store.snapshotArchiveQueue()
        try #require(pending.count == 2)

        try await store.deleteArchiveOp(pending[0])

        let remaining = try await store.snapshotArchiveQueue()
        #expect(remaining.map(\.uid.rawValue) == [11])
    }
}
