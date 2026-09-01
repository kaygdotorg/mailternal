import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

@Test func uidvalidityMidBackfillReplacesAtomicallyWithoutNotifyFlood() async throws {
    try await withSyncStore { store, dir in
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": populatedInbox(uidValidity: 10, count: 20, prefix: "old")]
        )
        world.fetchNanos = 35_000_000
        let (engine, _) = makeEngine(store: store, world: world, dir: dir)
        let events = EventLog()
        let collector = Task {
            for await event in await engine.newMail { events.append(event) }
        }
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.totalCount >= 6 && inbox.backfill != .complete
        }
        let inbox = try await requireInbox(store)
        let oldLive = try #require(await store.liveGeneration(for: inbox.id))
        #expect(oldLive.uidValidity == 10)
        let oldSubjects = try await pageSubjects(store, folder: inbox.id)
        #expect(oldSubjects.contains { $0.hasPrefix("old-") })
        #expect(oldSubjects.count == inbox.totalCount)

        world.fetchNanos = 8_000_000
        world.updateMailbox("INBOX") { live in
            live = populatedInbox(uidValidity: 77, count: 8, prefix: "new", highestModSeq: 3)
        }
        world.fetchError = IMAPError.transport("connection reset")
        world.fetchErrorAfter = world.fetchCount + 1

        try await waitUntil(timeout: .seconds(6)) {
            guard let current = try await inboxFolder(store) else { return false }
            guard let live = try await store.liveGeneration(for: current.id) else { return false }
            if live.uidValidity == 10 {
                let oldStillReadable = try await store.page(in: current.id, after: nil, limit: 50)
                return !oldStillReadable.rows.isEmpty
            }
            return live.uidValidity == 77 && current.backfill == .complete && current.totalCount == 8
        }
        try await waitUntil(timeout: .seconds(6)) {
            guard let current = try await inboxFolder(store) else { return false }
            guard let live = try await store.liveGeneration(for: current.id) else { return false }
            return live.uidValidity == 77 && current.backfill == .complete && current.totalCount == 8
        }

        let switched = try await requireInbox(store)
        let live = try #require(await store.liveGeneration(for: switched.id))
        #expect(live.uidValidity == 77)
        #expect(switched.totalCount == 8)
        let subjects = try await pageSubjects(store, folder: switched.id, limit: 3)
        #expect(subjects.allSatisfy { $0.hasPrefix("new-") })
        #expect(Set(subjects).count == subjects.count)
        #expect(events.snapshot().isEmpty)
        try await assertStoreInvariants(store, drain: true, expectEmptySeen: true, expectNoReplacement: true)

        world.updateMailbox("INBOX") { live in
            live.messages[9] = makePlainMessage(uid: 9, subject: "post-switch", body: "after baseline")
            live.uidNext = 10
            live.highestModSeq = 9
        }
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(4)) { events.snapshot().count == 1 }
        #expect(events.snapshot()[0].subject == "post-switch")

        collector.cancel()
        await engine.stop()
    }
}

@Test func restartMidIdleAndMidFetchReconnectsDeltaFirstWithoutWedge() async throws {
    try await withSyncStore { store, dir in
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": populatedInbox(uidValidity: 4, count: 16, prefix: "hist")]
        )
        world.fetchNanos = 30_000_000
        let (engine, factory) = makeEngine(store: store, world: world, dir: dir)
        let events = EventLog()
        let collector = Task {
            for await event in await engine.newMail { events.append(event) }
        }
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            (try await inboxFolder(store))?.totalCount ?? 0 >= 6
        }
        world.fetchError = IMAPError.transport("mid-fetch drop")
        world.fetchErrorAfter = world.fetchCount + 1
        world.fetchNanos = 0

        try await waitUntil(timeout: .seconds(8)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.backfill == .complete && inbox.totalCount == 16
        }
        #expect(events.snapshot().isEmpty)
        try await waitUntil(timeout: .seconds(3)) { factory.clients.count >= 2 }

        world.updateMailbox("INBOX") { live in
            live.messages[17] = makePlainMessage(uid: 17, subject: "after-restart", body: "delta first")
            live.uidNext = 18
            live.highestModSeq = 40
        }
        await factory.emitAll(.bye("server restart"))

        try await waitUntil(timeout: .seconds(6)) {
            try await inboxFolder(store)?.totalCount == 17
        }
        try await waitUntil(timeout: .seconds(3)) { events.snapshot().count == 1 }
        #expect(events.snapshot()[0].subject == "after-restart")
        try await waitUntil(timeout: .seconds(3)) { await factory.closedClientCount() >= 2 }
        try await assertStoreInvariants(store, drain: true, expectEmptySeen: true)

        collector.cancel()
        await engine.stop()
    }
}

@Test(arguments: [
    ChaosDeltaPath.qresync,
    ChaosDeltaPath.condstore,
    ChaosDeltaPath.basic,
])
func expungeStormRemovesRowsAndFTSGhostsOnDeltaPath(_ path: ChaosDeltaPath) async throws {
    try await withSyncStore { store, dir in
        var box = populatedInbox(uidValidity: 2, count: 30, prefix: "keep", highestModSeq: 50)
        for uid in [3, 8, 9, 14, 15, 21, 22, 23, 27, 28] as [UInt32] {
            box.messages[uid] = makePlainMessage(uid: uid, subject: "gone-\(uid)", body: "ghosttoken\(uid)")
        }
        let world = ScriptedWorld(
            capabilities: path.capabilities,
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let (engine, _) = makeEngine(
            store: store,
            world: world,
            dir: dir,
            window: 8,
            allowEnableQResync: path.allowEnable
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(6)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.backfill == .complete && inbox.totalCount == 30
        }
        let inbox = try await requireInbox(store)
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        let state = try #require(await store.fetchSyncState(for: generation))
        #expect(state.deltaPath == path.expected)

        let vanished: [UInt32] = [3, 8, 9, 14, 15, 21, 22, 23, 27, 28]
        world.updateMailbox("INBOX") { live in
            for uid in vanished {
                live.messages.removeValue(forKey: uid)
            }
            live.vanished = path.usesVanished ? vanished : []
            live.vanishedEarlier = []
            live.highestModSeq = 80
        }
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await inboxFolder(store)?.totalCount == 20
        }
        let subjects = try await pageSubjects(store, folder: inbox.id, limit: 7)
        #expect(subjects.count == 20)
        #expect(subjects.allSatisfy { !$0.hasPrefix("gone-") })
        #expect(try await store.search("ghosttoken", limit: 10).isEmpty)
        try await assertStoreInvariants(store, drain: true, expectEmptySeen: true, expectNoReplacement: true)
        await engine.stop()
    }
}

@Test func burstDeliverDuringIdleIsSingleDeltaAndBoundedPage() async throws {
    try await withSyncStore { store, dir in
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": populatedInbox(uidValidity: 1, count: 10, prefix: "base")]
        )
        let (engine, factory) = makeEngine(store: store, world: world, dir: dir, window: 20)
        let events = EventLog()
        let collector = Task {
            for await event in await engine.newMail { events.append(event) }
        }
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.backfill == .complete && inbox.totalCount == 10
        }
        let inbox = try await requireInbox(store)
        let pageHits = EventCountLog()
        let observer = Task {
            for await page in store.observePage(in: inbox.id, after: nil, limit: 6) {
                pageHits.append(page.rows.count)
                if page.rows.count > 6 { break }
            }
        }
        try await waitUntil(timeout: .seconds(2)) { factory.clients.count >= 2 }

        world.updateMailbox("INBOX") { live in
            for n in 11...90 {
                let uid = UInt32(n)
                live.messages[uid] = makePlainMessage(uid: uid, subject: "burst-\(uid)", body: "live \(uid)")
            }
            live.uidNext = 91
            live.highestModSeq = 200
        }
        await factory.emitAll(.exists(90))
        await engine.refreshNow()

        try await waitUntil(timeout: .seconds(6)) {
            (try await inboxFolder(store))?.totalCount == 90
        }
        try await waitUntil(timeout: .seconds(3)) { events.snapshot().count == 80 }
        let snapshot = events.snapshot()
        #expect(snapshot.allSatisfy { $0.subject.hasPrefix("burst-") })
        #expect(Set(snapshot.map(\.messageID)).count == 80)
        #expect(pageHits.snapshot().allSatisfy { $0 <= 6 })
        try await assertStoreInvariants(store, drain: true, expectEmptySeen: true)
        observer.cancel()
        collector.cancel()
        await engine.stop()
    }
}

@Test func capabilityLieDowngradesPersistentlyWithoutDataLoss() async throws {
    try await withSyncStore { store, dir in
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": populatedInbox(uidValidity: 5, count: 5, prefix: "keep")]
        )
        let (engine, _) = makeEngine(store: store, world: world, dir: dir)
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            guard inbox.backfill == .complete, let gen = try await store.liveGeneration(for: inbox.id) else {
                return false
            }
            return (try await store.fetchSyncState(for: gen))?.deltaPath == .qresync
        }
        world.failQResync = true
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(4)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
            return (try await store.fetchSyncState(for: gen))?.deltaPath == .condstore
        }
        #expect(try await inboxFolder(store)?.totalCount == 5)
        #expect(try await store.search("keep", limit: 10).count == 5)
        await engine.stop()

        let (again, _) = makeEngine(store: store, world: world, dir: dir)
        await again.start()
        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
            let state = try await store.fetchSyncState(for: gen)
            return state?.deltaPath == .condstore && inbox.totalCount == 5
        }
        try await assertStoreInvariants(store, drain: true, expectEmptySeen: true)
        await again.stop()
    }
}

@Test func seenQueueSurvivesOfflineAndDrainsOnTaggedOK() async throws {
    try await withSyncStore { store, dir in
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": populatedInbox(uidValidity: 3, count: 2, prefix: "seen")]
        )
        let (engine, _) = makeEngine(store: store, world: world, dir: dir)
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            (try await inboxFolder(store))?.totalCount == 2
        }
        let inbox = try await requireInbox(store)
        await engine.stop()
        try await store.enqueueSeen(
            account: sampleConfig().id,
            folder: inbox.id,
            uidValidity: 3,
            uid: IMAPUID(rawValue: 1)
        )
        #expect(try await store.snapshotSeenQueue().count == 1)
        let (again, _) = makeEngine(store: store, world: world, dir: dir)
        await again.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.snapshotSeenQueue().isEmpty && world.seenUIDs().contains(1)
        }

[Showing lines 1-300 of 494. Use :301 to continue]