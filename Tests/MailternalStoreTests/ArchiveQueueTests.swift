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

        try await store.enqueueMove(message: id, to: .archive)
        try await store.enqueueMove(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 3), to: .archive)

        let pending = try await store.snapshotMoveQueue()
        #expect(pending.count == 1)
        #expect(pending[0].uid.rawValue == 3)
        #expect(try await store.page(in: folder, after: nil, limit: 10).rows.isEmpty)
    }
}

@Test func archiveQueuePersistsCopiedPhaseFromV5Migration() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store)
        try await store.enqueueMove(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 7), to: .archive)

        let pendingOps = try await store.snapshotMoveQueue()
        let pending = try #require(pendingOps.first)
        #expect(pending.copied == false)
        try await store.markMoveCopied(pending)
        #expect(try await store.snapshotMoveQueue().first?.copied == true)
    }
}

@Test func archiveQueueSkipsCapturedFetchAfterEnqueue() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        try await store.enqueueMove(account: account.id,
        folder: folder,
        uidValidity: generation.uidValidity,
        uid: IMAPUID(rawValue: 12), to: .archive)

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
        // then enqueueMove's queue row appears before the drain dequeue.
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
        let pendingOps = try await store.snapshotMoveQueue()
        let pending = try #require(pendingOps.first)
        try await store.deleteMoveOp(pending)
        #expect(try await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 13)
        ) == nil)
    }
}

@Test func archiveQueueDropsStaleUIDValidity() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store, uidValidity: 1)
        try await store.enqueueMove(account: account.id,
        folder: folder,
        uidValidity: 9,
        uid: IMAPUID(rawValue: 7), to: .archive)
        #expect(try await store.snapshotMoveQueue().count == 1)

        try await store.dropStaleMove(folder: folder)

        #expect(try await store.snapshotMoveQueue().isEmpty)
    }
}

@Test func archiveQueueDeleteRemovesOnlyAcknowledgedOperation() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store)
        try await store.enqueueMove(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 10), to: .archive)
        try await store.enqueueMove(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 11), to: .archive)
        let pending = try await store.snapshotMoveQueue()
        try #require(pending.count == 2)

        try await store.deleteMoveOp(pending[0])

        let remaining = try await store.snapshotMoveQueue()
        #expect(remaining.map(\.uid.rawValue) == [11])
    }
}

@Test func moveQueuePersistsTrashDestination() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 21, subject: "trash me")
        ])
        let id = try #require(await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 21)
        ))

        try await store.enqueueMove(message: id, to: .trash)
        let pending = try #require(await store.snapshotMoveQueue().first)
        #expect(pending.destination == .trash)
        #expect(pending.account == account.id)
        #expect(try await store.page(in: folder, after: nil, limit: 10).rows.isEmpty)
    }
}
