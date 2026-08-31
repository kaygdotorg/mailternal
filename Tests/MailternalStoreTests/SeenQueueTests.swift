import Foundation
import Testing
@testable import MailternalStore

@Test func seenQueueCoalescesAndDropsStaleGeneration() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 3, subject: "unread"),
        ])
        let id = try await store.messageID(generation: generation, uid: IMAPUID(rawValue: 3))!

        try await store.enqueueSeen(message: id)
        try await store.enqueueSeen(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 3)
        )
        try await store.enqueueSeen(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 4)
        )

        var pending = try await store.snapshotSeenQueue()
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.uid.rawValue)) == [3, 4])

        let page = try await store.page(in: folder, after: nil, limit: 10)
        #expect(page.rows[0].isRead)

        let uid3 = pending.first { $0.uid.rawValue == 3 }!
        try await store.dequeueSeen(uid3)
        pending = try await store.snapshotSeenQueue()
        #expect(pending.count == 1)
        #expect(pending[0].uid.rawValue == 4)

        try await store.dropSeen(pending[0], reason: "NO")
        pending = try await store.snapshotSeenQueue()
        #expect(pending.isEmpty)
        let errors = try await store.fetchErrorLog()
        #expect(errors.contains { $0.kind == .seen && $0.message == "NO" })

        try await store.enqueueSeen(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 9)
        )
        _ = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 2,
            baselineUID: IMAPUID(rawValue: 1)
        )
        try await store.activateReplacementGeneration(folder: folder)

        pending = try await store.snapshotSeenQueue()
        #expect(pending.isEmpty)
    }
}

@Test func pendingSeenWinsOverInboundUnseenUpsert() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 3, subject: "unread"),
        ])
        try await store.enqueueSeen(
            account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: 3)
        )
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 3, subject: "still unread on server", isRead: false),
        ])
        let page = try await store.page(in: folder, after: nil, limit: 1)
        #expect(page.rows[0].isRead)
        #expect(page.rows[0].subject == "still unread on server")
    }
}

@Test func seenQueueSnapshotOrderIsStable() async throws {
    try await withStore { store, _ in
        let (account, folder, _) = try await seedInbox(store)
        for uid in [10, 11, 12] as [UInt32] {
            try await store.enqueueSeen(
                account: account.id,
                folder: folder,
                uidValidity: 1,
                uid: IMAPUID(rawValue: uid)
            )
        }
        let pending = try await store.snapshotSeenQueue(limit: 2)
        #expect(pending.map(\.uid.rawValue) == [10, 11])
    }
}
