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

        try await store.enqueueFlag(message: id, flag: .seen, set: true)
        try await store.enqueueFlag(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 3), flag: .seen, set: true)
        try await store.enqueueFlag(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 4), flag: .seen, set: true)

        var pending = try await store.snapshotFlagQueue()
        #expect(pending.count == 2)
        #expect(Set(pending.map(\.uid.rawValue)) == [3, 4])

        let page = try await store.page(in: folder, after: nil, limit: 10)
        #expect(page.rows[0].isRead)

        let uid3 = pending.first { $0.uid.rawValue == 3 }!
        try await store.dequeueFlag(uid3)
        pending = try await store.snapshotFlagQueue()
        #expect(pending.count == 1)
        #expect(pending[0].uid.rawValue == 4)

        try await store.dropFlag(pending[0], reason: "NO")
        pending = try await store.snapshotFlagQueue()
        #expect(pending.isEmpty)
        let errors = try await store.fetchErrorLog()
        #expect(errors.contains { $0.kind == .seen && $0.message == "NO" })

        try await store.enqueueFlag(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 9), flag: .seen, set: true)
        _ = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 2,
            baselineUID: IMAPUID(rawValue: 1)
        )
        try await store.activateReplacementGeneration(folder: folder)

        pending = try await store.snapshotFlagQueue()
        #expect(pending.isEmpty)
    }
}

@Test func pendingSeenWinsOverInboundUnseenUpsert() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 3, subject: "unread"),
        ])
        try await store.enqueueFlag(account: account.id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 3), flag: .seen, set: true)
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
            try await store.enqueueFlag(account: account.id,
            folder: folder,
            uidValidity: 1,
            uid: IMAPUID(rawValue: uid), flag: .seen, set: true)
        }
        let pending = try await store.snapshotFlagQueue(limit: 2)
        #expect(pending.map(\.uid.rawValue) == [10, 11])
    }
}

@Test func flagQueueCoalescesOppositeSeenAndFlaggedOperations() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 7, isRead: true, isFlagged: false)
        ])
        let id = try #require(await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 7)
        ))

        try await store.enqueueFlag(message: id, flag: .seen, set: false)
        try await store.enqueueFlag(message: id, flag: .seen, set: true)
        try await store.enqueueFlag(message: id, flag: .flagged, set: true)
        try await store.enqueueFlag(message: id, flag: .flagged, set: false)

        let pending = try await store.snapshotFlagQueue()
        #expect(pending.count == 2)
        #expect(pending.first(where: { $0.flag == .seen })?.set == true)
        #expect(pending.first(where: { $0.flag == .flagged })?.set == false)
        let row = try await store.page(in: folder, after: nil, limit: 1).rows[0]
        #expect(row.isRead)
        #expect(!row.isFlagged)
        _ = account
    }
}

@Test func flagPrecedenceWinsBothInboundStates() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 8, isRead: false, isFlagged: false)
        ])
        try await store.enqueueFlag(
            account: account.id,
            folder: folder,
            uidValidity: generation.uidValidity,
            uid: IMAPUID(rawValue: 8),
            flag: .seen,
            set: true
        )
        try await store.enqueueFlag(
            account: account.id,
            folder: folder,
            uidValidity: generation.uidValidity,
            uid: IMAPUID(rawValue: 8),
            flag: .flagged,
            set: true
        )
        try await store.applyFlags(
            generation: generation,
            deltas: [FlagDelta(uid: IMAPUID(rawValue: 8), flags: MessageFlags())]
        )
        let row = try await store.page(in: folder, after: nil, limit: 1).rows[0]
        #expect(row.isRead)
        #expect(row.isFlagged)
    }
}
