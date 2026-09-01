import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

@Test func engineBackfillPersistsBaselineAndDoesNotNotifyHistoricalUIDs() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 7, uidNext: 4, highestModSeq: 20)
        box.messages[1] = makePlainMessage(uid: 1, subject: "one", body: "alpha token")
        box.messages[2] = makePlainMessage(uid: 2, subject: "two", body: "beta token")
        box.messages[3] = makePlainMessage(uid: 3, subject: "three", body: "gamma token")
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let factory = ScriptedFactory(world: world)
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir)
        )
        let events = EventLog()
        let mail = await engine.newMail
        let collector = Task {
            for await event in mail { events.append(event) }
        }
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            return folders.contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 3 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        let state = try #require(await store.fetchSyncState(for: generation))
        #expect(state.baselineUID?.rawValue == 3)
        #expect(try await store.search("alpha", limit: 5).count == 1)
        #expect(try await store.search("gamma", limit: 5).count == 1)
        #expect(events.snapshot().isEmpty)

        world.updateMailbox("INBOX") { live in
            live.messages[4] = makePlainMessage(uid: 4, subject: "new", body: "delta live")
            live.uidNext = 5
        }

        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("delta", limit: 5).count == 1
        }
        try await waitUntil(timeout: .seconds(2)) { events.snapshot().count == 1 }
        #expect(events.snapshot()[0].subject == "new")
        #expect(events.snapshot()[0].folder == inbox.id)

        await engine.refreshNow()
        try await Task.sleep(for: .milliseconds(80))
        #expect(events.snapshot().count == 1)

        collector.cancel()
        await engine.stop()
    }
}

@Test func engineQuarantinesFailedFetchWithoutStallingFolder() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 3, highestModSeq: 2)
        box.messages[1] = makePlainMessage(uid: 1, subject: "ok", body: "good")
        var bad = makePlainMessage(uid: 2, subject: "bad", body: "nope")
        bad.envelope = IMAPEnvelope(
            date: nil, subject: nil, from: [], sender: [], replyTo: [], to: [], cc: [], bcc: [],
            inReplyTo: nil, messageID: nil
        )
        bad.structure = IMAPBodyStructure(
            partSpecifier: "", type: "text", subtype: "plain", encoding: nil,
            octetCount: nil, charset: nil, filename: nil, contentID: nil, children: []
        )
        bad.parts = [:]
        box.messages[2] = bad
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            return folders.contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 2 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let page = try await store.page(in: inbox.id, after: nil, limit: 10)
        #expect(page.rows.count == 2)
        await engine.stop()
    }
}

@Test func engineDowngradesQresyncFailureAndPersistsBasicOrCondstore() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 9)
        box.messages[1] = makePlainMessage(uid: 1, subject: "only")
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.failQResync = true
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            guard let inbox = folders.first(where: { $0.role == .inbox }) else { return false }
            guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
            let state = try await store.fetchSyncState(for: gen)
            return state?.deltaPath != .qresync && inbox.totalCount == 1
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let gen = try #require(await store.liveGeneration(for: inbox.id))
        let state = try #require(await store.fetchSyncState(for: gen))
        #expect(state.deltaPath == .condstore || state.deltaPath == .basic)
        await engine.stop()
    }
}

@Test func engineDrainsSeenOnTaggedOKAndDropsTaggedNO() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 3, uidNext: 3, highestModSeq: 4)
        box.messages[1] = makePlainMessage(uid: 1, subject: "s1")
        box.messages[2] = makePlainMessage(uid: 2, subject: "s2")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id).contains { $0.totalCount == 2 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        try await store.enqueueSeen(
            account: sampleConfig().id,
            folder: inbox.id,
            uidValidity: 3,
            uid: IMAPUID(rawValue: 1)
        )
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotSeenQueue().isEmpty && world.seenUIDs().contains(1)
        }

        world.storeSeenError = IMAPError.taggedNO(tag: "t", message: "nope", code: nil)
        try await store.enqueueSeen(
            account: sampleConfig().id,
            folder: inbox.id,
            uidValidity: 3,
            uid: IMAPUID(rawValue: 2)
        )
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotSeenQueue().isEmpty
        }
        let log = try await store.fetchErrorLog()
        #expect(log.contains { $0.kind == .seen || $0.message.lowercased().contains("nope") })
        await engine.stop()
    }
}

@Test func engineFallsBackToSingleConnectionOnSecondConnectNO() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        box.messages[1] = makePlainMessage(uid: 1, subject: "solo")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let factory = ScriptedFactory(
            world: world,
            secondConnectError: IMAPError.taggedNO(tag: "t", message: "Too many connections", code: nil)
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id).contains { $0.totalCount == 1 }
        }
        await engine.stop()
    }
}

@Test func fetchPartAndRawSourceUsePeekedBytes() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        box.messages[1] = makePlainMessage(uid: 1, subject: "src", body: "BODYTEXT")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id).contains { $0.totalCount == 1 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let page = try await store.page(in: inbox.id, after: nil, limit: 1)
        let id = try #require(page.rows.first?.id)
        let url = try await engine.fetchPart(message: id, part: "1")
        let bytes = try Data(contentsOf: url)
        #expect(String(decoding: bytes, as: UTF8.self) == "BODYTEXT")
        let raw = try await engine.rawSource(message: id)
        #expect(raw.contains("BODYTEXT") || raw.contains("src"))
        await engine.stop()
    }
}

@Test func engineIngestsOfflineMailOnReconnectWithoutRefetchingHistory() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 4, highestModSeq: 4)
        box.messages[1] = makePlainMessage(uid: 1, subject: "old-1", body: "alpha")
        box.messages[2] = makePlainMessage(uid: 2, subject: "old-2", body: "beta")
        box.messages[3] = makePlainMessage(uid: 3, subject: "old-3", body: "gamma")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        func makeEngine() -> SyncEngine {
            SyncEngine(
                store: store,
                config: sampleConfig(),
                credentials: StaticPassword(value: "pw"),
                clientFactory: ScriptedFactory(world: world),
                disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
                clock: { Date() },
                settings: testSettings(dir: dir)
            )
        }
        let first = makeEngine()
        await first.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 3 }
        }
        await first.stop()

        world.updateMailbox("INBOX") { live in
            live.messages[4] = makePlainMessage(uid: 4, subject: "offline", body: "delta live")
            live.uidNext = 5
            live.highestModSeq = 8
        }

        let second = makeEngine()
        let events = EventLog()
        let mail = await second.newMail
        let collector = Task {
            for await event in mail { events.append(event) }
        }
        await second.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("delta", limit: 5).count == 1
        }
        try await waitUntil(timeout: .seconds(2)) { events.snapshot().count == 1 }
        #expect(events.snapshot()[0].subject == "offline")
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        #expect(inbox.totalCount == 4)
        collector.cancel()
        await second.stop()
    }
}

@Test func engineSwitchesGenerationOnUIDValidityChangeWithoutNotifying() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 3, highestModSeq: 4)
        box.messages[1] = makePlainMessage(uid: 1, subject: "gen1-a", body: "one")
        box.messages[2] = makePlainMessage(uid: 2, subject: "gen1-b", body: "two")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        let events = EventLog()
        let mail = await engine.newMail
        let collector = Task {
            for await event in mail { events.append(event) }
        }
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 2 }
        }

        world.updateMailbox("INBOX") { live in
            live.uidValidity = 99
            live.uidNext = 2
            live.highestModSeq = 1
            live.messages = [
                1: makePlainMessage(uid: 1, subject: "gen2", body: "replacement body"),
            ]
        }

        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            guard let inbox = folders.first(where: { $0.role == .inbox }) else { return false }
            guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
            return gen.uidValidity == 99 && inbox.totalCount == 1 && inbox.backfill == .complete
        }
        #expect(events.snapshot().isEmpty)
        #expect(try await store.search("replacement", limit: 5).count == 1)
        collector.cancel()
        await engine.stop()
    }
}

@Test func engineReconcilesExpungeOnBasicDelta() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 3, highestModSeq: 2)
        box.messages[1] = makePlainMessage(uid: 1, subject: "keep", body: "stay")
        box.messages[2] = makePlainMessage(uid: 2, subject: "gone", body: "drop")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.totalCount == 2 }
        }

        world.updateMailbox("INBOX") { live in
            live.messages.removeValue(forKey: 2)
        }

        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.totalCount == 1 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let page = try await store.page(in: inbox.id, after: nil, limit: 10)
        #expect(page.rows.map(\.subject) == ["keep"])
        await engine.stop()
    }
}

@Test func engineCommitsFirstInboxWindowBeforeDiskHalt() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 5, highestModSeq: 1)
        box.messages[1] = makePlainMessage(uid: 1, subject: "old-1", body: "one")
        box.messages[2] = makePlainMessage(uid: 2, subject: "old-2", body: "two")
        box.messages[3] = makePlainMessage(uid: 3, subject: "new-3", body: "three")
        box.messages[4] = makePlainMessage(uid: 4, subject: "new-4", body: "four")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 1, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir, window: 2)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            guard let inbox = folders.first(where: { $0.role == .inbox }) else { return false }
            guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
            let state = try await store.fetchSyncState(for: gen)
            return state?.backfillPhase == .halted && inbox.totalCount >= 2
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        #expect(inbox.totalCount == 2)
        let logs = try await store.fetchErrorLog(limit: 20)
        #expect(logs.contains { $0.message.contains("halted") })
        await engine.stop()
    }
}


@Test func engineStopUnblocksInFlightBackfillFetch() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 4, highestModSeq: 2)
        box.messages[1] = makePlainMessage(uid: 1, subject: "one", body: "alpha")
        box.messages[2] = makePlainMessage(uid: 2, subject: "two", body: "beta")
        box.messages[3] = makePlainMessage(uid: 3, subject: "three", body: "gamma")
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.fetchNanos = 400_000_000
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await Task.sleep(for: .milliseconds(80))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw WaitTimeout()
            }
            group.addTask {
                await engine.stop()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
