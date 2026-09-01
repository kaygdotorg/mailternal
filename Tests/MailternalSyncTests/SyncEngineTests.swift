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

@Test func fetchPartRejectsRemoteURLWithoutWritingCache() async throws {
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

        let caches = dir.appendingPathComponent("Caches", isDirectory: true)
        func cacheListing() -> [String] {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(atPath: caches.path) else { return [] }
            return (enumerator.allObjects as? [String] ?? []).sorted()
        }
        let before = cacheListing()
        let fetchesBefore = world.snapshotFetchCount()

        await #expect(throws: SyncEngineError.invalidPartSpecifier) {
            _ = try await engine.fetchPart(message: id, part: "https://x")
        }
        await #expect(throws: SyncEngineError.invalidPartSpecifier) {
            _ = try await engine.fetchPart(message: id, part: "")
        }
        await #expect(throws: SyncEngineError.invalidPartSpecifier) {
            _ = try await engine.fetchPart(message: id, part: "HEADER")
        }

        #expect(cacheListing() == before)
        #expect(world.snapshotFetchCount() == fetchesBefore)
        #expect(IMAPSectionSpecifier.isLegal("1"))
        #expect(IMAPSectionSpecifier.isLegal("1.2"))
        #expect(IMAPSectionSpecifier.isLegal("1.2.HEADER"))
        #expect(IMAPSectionSpecifier.isLegal("1.2.text"))
        #expect(!IMAPSectionSpecifier.isLegal("https://x"))
        #expect(!IMAPSectionSpecifier.isLegal("cid:foo@bar"))
        await engine.stop()
    }
}

@Test func fetchPartRejectsStaleGenerationWithoutWritingCache() async throws {
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
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 1 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let page = try await store.page(in: inbox.id, after: nil, limit: 1)
        let id = try #require(page.rows.first?.id)
        let ref = try #require(await store.messageRef(id))
        #expect(ref.generation.uidValidity == 1)

        let caches = dir.appendingPathComponent("Caches", isDirectory: true)
        func cacheListing() -> [String] {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(atPath: caches.path) else { return [] }
            return (enumerator.allObjects as? [String] ?? []).sorted()
        }
        let before = cacheListing()
        let fetchesBefore = world.snapshotFetchCount()
        let cacheSizeBefore = try await store.attachmentCacheSize()

        // UIDVALIDITY changes on the server between messageRef and the on-demand
        // SELECT. Same UID now names a different message — must not FETCH or cache it.
        world.updateMailbox("INBOX") { live in
            live.uidValidity = 99
            live.uidNext = 2
            live.highestModSeq = 1
            live.messages = [
                1: makePlainMessage(uid: 1, subject: "gen2", body: "REPLACEMENT-SHOULD-NOT-FETCH"),
            ]
        }

        await #expect(throws: SyncEngineError.staleMessage) {
            _ = try await engine.fetchPart(message: id, part: "1")
        }
        await #expect(throws: SyncEngineError.staleMessage) {
            _ = try await engine.rawSource(message: id)
        }
        #expect(cacheListing() == before)
        #expect(try await store.attachmentCacheSize() == cacheSizeBefore)
        #expect(world.snapshotFetchCount() == fetchesBefore)
        #expect(try await store.search("REPLACEMENT-SHOULD-NOT-FETCH", limit: 5).isEmpty)
        let detail = try await store.detail(id)
        #expect(detail.envelope.subject == "src")

        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            guard let live = try await store.liveGeneration(for: inbox.id) else { return false }
            return live.uidValidity == 99
        }
        await #expect(throws: SyncEngineError.staleMessage) {
            _ = try await engine.fetchPart(message: id, part: "1")
        }
        #expect(cacheListing() == before)
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

@Test func engineCancelledMidWindowDoesNotSkipUIDsOnResume() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 7, highestModSeq: 2)
        for n in 1...6 {
            let uid = UInt32(n)
            box.messages[uid] = makePlainMessage(
                uid: uid,
                subject: "msg-\(uid)",
                body: "body-\(uid)"
            )
        }
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        // Window 5...6 commits; the next metadata FETCH throws CancellationError
        // mid-window 3...4. Cursor must stay at 5 so resume cannot skip 3...4.
        world.fetchError = CancellationError()
        world.fetchErrorAfter = 2

        let disk = FixedDisk(
            freeBytes: 50 * 1024 * 1024 * 1024,
            volumeBytes: 100 * 1024 * 1024 * 1024
        )
        func makeEngine() -> SyncEngine {
            SyncEngine(
                store: store,
                config: sampleConfig(),
                credentials: StaticPassword(value: "pw"),
                clientFactory: ScriptedFactory(world: world),
                disk: disk,
                clock: { Date() },
                settings: testSettings(dir: dir, window: 2)
            )
        }

        let first = makeEngine()
        await first.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.totalCount >= 2 }
        }
        try await waitUntil(timeout: .seconds(2)) { world.snapshotFetchCount() >= 2 }
        await first.stop()

        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        let state = try #require(await store.fetchSyncState(for: generation))
        #expect(state.backfillPhase != .complete)
        #expect(state.lowWaterUID?.rawValue == 5)
        #expect(try await store.uids(in: generation).map(\.rawValue) == [5, 6])

        let second = makeEngine()
        await second.start()
        try await waitUntil(timeout: .seconds(5)) {
            let latest = try await store.fetchFolders(account: sampleConfig().id)
            guard let inbox = latest.first(where: { $0.role == .inbox }) else { return false }
            return inbox.backfill == .complete && inbox.totalCount == 6
        }
        let resumed = try #require(await store.liveGeneration(for: inbox.id))
        #expect(try await store.uids(in: resumed).map(\.rawValue) == [1, 2, 3, 4, 5, 6])
        for uid in [UInt32(3), UInt32(4)] {
            let id = try #require(await store.messageID(generation: resumed, uid: IMAPUID(rawValue: uid)))
            let detail = try await store.detail(id)
            #expect(!detail.isQuarantined)
            #expect(detail.envelope.subject == "msg-\(uid)")
        }
        await second.stop()
    }
}

@Test func engineResumesBackfillFromCommittedCursorWithoutDoubleNotify() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 9, highestModSeq: 9)
        for uid in 1...8 {
            box.messages[UInt32(uid)] = makePlainMessage(
                uid: UInt32(uid),
                subject: "hist-\(uid)",
                body: "body-\(uid)"
            )
        }
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.fetchNanos = 40_000_000
        func makeEngine() -> SyncEngine {
            SyncEngine(
                store: store,
                config: sampleConfig(),
                credentials: StaticPassword(value: "pw"),
                clientFactory: ScriptedFactory(world: world),
                disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
                clock: { Date() },
                settings: testSettings(dir: dir, window: 2)
            )
        }

        let first = makeEngine()
        await first.start()
        try await waitUntil(timeout: .seconds(8)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            guard let inbox = folders.first(where: { $0.role == .inbox }) else { return false }
            guard inbox.totalCount >= 2, inbox.backfill != .complete else { return false }
            guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
            let state = try await store.fetchSyncState(for: gen)
            return state?.lowWaterUID != nil
        }
        let foldersMid = try await store.fetchFolders(account: sampleConfig().id)
        let inboxMid = try #require(foldersMid.first { $0.role == .inbox })
        let genMid = try #require(await store.liveGeneration(for: inboxMid.id))
        let stateMid = try #require(await store.fetchSyncState(for: genMid))
        let lowMid = try #require(stateMid.lowWaterUID?.rawValue)
        let countMid = inboxMid.totalCount
        await first.stop()
        #expect(countMid < 8)
        #expect(lowMid > 1)

        world.fetchNanos = 0
        let second = makeEngine()
        let events = EventLog()
        let mail = await second.newMail
        let collector = Task {
            for await event in mail { events.append(event) }
        }
        await second.start()
        try await waitUntil(timeout: .seconds(8)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 8 }
        }
        let logs = try await store.fetchErrorLog()
        #expect(logs.contains { $0.message == "resuming backfill from cursor" })
        #expect(events.snapshot().isEmpty)

        world.updateMailbox("INBOX") { live in
            live.messages[9] = makePlainMessage(uid: 9, subject: "live-new", body: "fresh")
            live.uidNext = 10
            live.highestModSeq = 12
        }
        await second.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("fresh", limit: 5).count == 1
        }
        try await waitUntil(timeout: .seconds(2)) { events.snapshot().count == 1 }
        #expect(events.snapshot()[0].subject == "live-new")
        collector.cancel()
        await second.stop()

        let third = makeEngine()
        let events2 = EventLog()
        let mail2 = await third.newMail
        let collector2 = Task {
            for await event in mail2 { events2.append(event) }
        }
        await third.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.totalCount == 9 }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(events2.snapshot().isEmpty)
        collector2.cancel()
        await third.stop()
    }
}

@Test func fetchPartHonorsTinyAttachmentCacheCap() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailternal-sync-cap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try MailStore(
        databaseURL: dir.appendingPathComponent("mail.sqlite"),
        cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true),
        attachmentCacheCapBytes: 80
    )
    var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 3, highestModSeq: 2)
    let blobA = String(repeating: "A", count: 60)
    let blobB = String(repeating: "B", count: 60)
    box.messages[1] = makePlainMessage(uid: 1, subject: "a", body: blobA)
    box.messages[2] = makePlainMessage(uid: 2, subject: "b", body: blobB)
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
    let page = try await store.page(in: inbox.id, after: nil, limit: 10)
    let idA = try #require(page.rows.first { $0.subject == "a" }?.id)
    let idB = try #require(page.rows.first { $0.subject == "b" }?.id)
    let urlA = try await engine.fetchPart(message: idA, part: "1")
    #expect(FileManager.default.fileExists(atPath: urlA.path))
    let urlB = try await engine.fetchPart(message: idB, part: "1")
    #expect(FileManager.default.fileExists(atPath: urlB.path))
    #expect(!FileManager.default.fileExists(atPath: urlA.path))
    #expect(try await store.attachmentCacheSize() <= 80)
    await engine.stop()
}

@Test func engineRetiresVanishedFolderOnSecondDiscovery() async throws {
    try await withSyncStore { store, dir in
        var inbox = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        inbox.messages[1] = makePlainMessage(uid: 1, subject: "keep", body: "inbox")
        var archive = ScriptedMailbox(path: "Archive", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        archive.messages[1] = makePlainMessage(uid: 1, subject: "gone", body: "archive")
        let archiveMailbox = IMAPMailbox(
            path: "Archive",
            name: "Archive",
            separator: "/",
            role: .archive,
            mailboxID: nil,
            attributes: ["\\Archive"]
        )
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox(), archiveMailbox],
            mailboxes: ["INBOX": inbox, "Archive": archive]
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
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            let paths = Set(folders.map(\.path))
            return paths == ["INBOX", "Archive"]
                && folders.allSatisfy { $0.backfill == .complete }
        }
        let afterA = try await store.fetchFolders(account: sampleConfig().id)
        #expect(Set(afterA.map(\.path)) == ["INBOX", "Archive"])
        #expect(Set(afterA.map(\.id)).count == afterA.count)
        let vanishedID = try #require(afterA.first { $0.path == "Archive" }?.id)
        await first.stop()

        world.replaceFolders([inboxMailbox()])
        let second = makeEngine()
        await second.start()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            return folders.map(\.path) == ["INBOX"]
        }
        let afterB = try await store.fetchFolders(account: sampleConfig().id)
        #expect(afterB.map(\.path) == ["INBOX"])
        #expect(Set(afterB.map(\.id)).count == afterB.count)
        #expect(Set(afterB.map(\.path)).count == afterB.count)
        #expect(try await store.fetchFolderSummary(vanishedID) == nil)
        await second.stop()
    }
}
