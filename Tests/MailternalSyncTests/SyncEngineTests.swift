import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

private actor StreamReadyGate {
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isReady = true
        let pending = waiters
        self.waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            if isReady {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}


private func nextMailEvent(
    from task: Task<NewMailEvent?, Never>,
    timeout: Duration
) async throws -> NewMailEvent {
    let timeoutTask = Task {
        try? await Task.sleep(for: timeout)
        task.cancel()
    }
    let event = await task.value
    timeoutTask.cancel()
    guard let event else { throw WaitTimeout() }
    return event
}

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
        let mail = await engine.newMail
        let listenerReady = StreamReadyGate()
        let firstEvent = Task<NewMailEvent?, Never> {
            var iterator = mail.makeAsyncIterator()
            await listenerReady.signal()
            return await iterator.next()
        }
        defer { firstEvent.cancel() }
        await listenerReady.waitUntilReady()
        await engine.start()
        try await waitUntil(timeout: .seconds(15)) {
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
        let sweepsBeforeAppend = world.snapshotFlagSweepRanges().count
        world.updateMailbox("INBOX") { live in
            live.messages[4] = makePlainMessage(uid: 4, subject: "new", body: "delta live")
            live.uidNext = 5
        }

        let completedFetches = world.snapshotCompletedFetchCount()
        let refreshTask = Task {
            await engine.refreshNow()
        }
        await world.waitForFetchCompletion(after: completedFetches)
        await refreshTask.value
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("delta", limit: 5).count == 1
        }
        // QRESYNC's UIDNEXT advance is an append, not proof of an expunge.
        #expect(world.snapshotFlagSweepRanges().count == sweepsBeforeAppend)
        let event = try await nextMailEvent(from: firstEvent, timeout: .seconds(2))
        #expect(event.subject == "new")
        #expect(event.folder == inbox.id)

        await engine.refreshNow()
        await #expect(throws: WaitTimeout.self) {
            _ = try await nextMailEvent(from: mail, timeout: .seconds(2))
        }

        await engine.stop()
    }
}

@Test func gmailCondstoreBackfillDeltaAndArchiveAllMail() async throws {
    try await withSyncStore { store, dir in
        var inbox = ScriptedMailbox(path: "INBOX", uidValidity: 22, uidNext: 2, highestModSeq: 10)
        inbox.messages[1] = makePlainMessage(
            uid: 1,
            subject: "Gmail archive",
            body: "first backfill",
            flags: [],
            modSeq: 10
        )
        let allMailPath = "[Gmail]/All Mail"
        let allMail = ScriptedMailbox(path: allMailPath, uidValidity: 22)
        let folders = [
            inboxMailbox(),
            IMAPMailbox(
                path: allMailPath,
                name: "All Mail",
                separator: "/",
                role: .archive,
                mailboxID: nil,
                attributes: ["\\All"]
            ),
            IMAPMailbox(
                path: "[Gmail]/Sent Mail",
                name: "Sent Mail",
                separator: "/",
                role: .sent,
                mailboxID: nil,
                attributes: ["\\Sent"]
            ),
            IMAPMailbox(
                path: "[Gmail]/Drafts",
                name: "Drafts",
                separator: "/",
                role: .drafts,
                mailboxID: nil,
                attributes: ["\\Drafts"]
            ),
            IMAPMailbox(
                path: "[Gmail]/Spam",
                name: "Spam",
                separator: "/",
                role: .junk,
                mailboxID: nil,
                attributes: ["\\Junk"]
            ),
            IMAPMailbox(
                path: "[Gmail]/Trash",
                name: "Trash",
                separator: "/",
                role: .trash,
                mailboxID: nil,
                attributes: ["\\Trash"]
            ),
            IMAPMailbox(
                path: "[Gmail]/Starred",
                name: "Starred",
                separator: "/",
                role: .none,
                mailboxID: nil,
                attributes: ["\\Flagged"]
            ),
            IMAPMailbox(
                path: "[Gmail]/Important",
                name: "Important",
                separator: "/",
                role: .none,
                mailboxID: nil,
                attributes: []
            ),
        ]
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: [
                "IMAP4REV1", "IDLE", "CONDSTORE", "MOVE", "SPECIAL-USE", "X-GM-EXT-1",
            ]),
            folders: folders,
            mailboxes: [
                "INBOX": inbox,
                allMailPath: allMail,
                "[Gmail]/Sent Mail": ScriptedMailbox(path: "[Gmail]/Sent Mail", uidValidity: 22),
                "[Gmail]/Drafts": ScriptedMailbox(path: "[Gmail]/Drafts", uidValidity: 22),
                "[Gmail]/Spam": ScriptedMailbox(path: "[Gmail]/Spam", uidValidity: 22),
                "[Gmail]/Trash": ScriptedMailbox(path: "[Gmail]/Trash", uidValidity: 22),
                "[Gmail]/Starred": ScriptedMailbox(path: "[Gmail]/Starred", uidValidity: 22),
                "[Gmail]/Important": ScriptedMailbox(path: "[Gmail]/Important", uidValidity: 22),
            ]
        )
        world.isGmail = true
        let (engine, _) = makeEngine(store: store, world: world, dir: dir, window: 2)
        await engine.start()

        try await waitUntil(timeout: .seconds(10)) {
            let summaries = try await store.fetchFolders(account: sampleConfig().id)
            return summaries.contains {
                $0.path == "INBOX" && $0.totalCount == 1 && $0.backfill == .complete
            } && summaries.contains { $0.path == allMailPath }
        }
        let inboxFolder = try #require(await inboxFolder(store))
        let firstPage = try await store.page(in: inboxFolder.id, after: nil, limit: 10, sort: .newest)
        let message = try #require(firstPage.rows.first)
        let generation = try #require(await store.liveGeneration(for: inboxFolder.id))
        let initialState = try #require(await store.fetchSyncState(for: generation))
        #expect(initialState.deltaPath == .condstore)

        world.updateMailbox("INBOX") { mailbox in
            mailbox.messages[1]?.flags = ["\\Seen"]
            mailbox.messages[1]?.modSeq = 12
            mailbox.highestModSeq = 12
        }
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            let page = try await store.page(in: inboxFolder.id, after: nil, limit: 10, sort: .newest)
            let state = try await store.fetchSyncState(for: generation)
            return page.rows.first?.isRead == true && state?.deltaPath == .condstore
        }

        try await store.enqueueMove(message: message.id, to: .archive)
        try await waitUntil(timeout: .seconds(5)) {
            try await store.snapshotMoveQueue().isEmpty
                && world.archiveCommandSnapshot() == ["MOVE INBOX \(allMailPath) 1"]
        }
        #expect(world.mailbox("INBOX").messages[1] == nil)
        #expect(world.mailbox(allMailPath).messages[1] != nil)
        let errors = try await store.fetchErrorLog()
        #expect(!errors.contains { $0.message.localizedCaseInsensitiveContains("unsupported") })
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
        let page = try await store.page(in: inbox.id, after: nil, limit: 10, sort: .newest)
        #expect(page.rows.count == 2)
        await engine.stop()
    }
}

@Test func engineBisectsPoisonedMetadataWindowAndAdvancesCursor() async throws {
    try await withSyncStore { store, dir in
        let poisonedUID: UInt32 = 40
        let box = populatedInbox(uidValidity: 1, count: 1_000, prefix: "bisect")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.parseFailingUIDs = [poisonedUID]
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(
                dir: dir,
                window: 1_000,
                seenPoll: .seconds(3_600),
                periodicTick: .seconds(3_600),
                cleanupTick: .seconds(3_600)
            )
        )

        await engine.start()
        try await waitUntil(timeout: .seconds(15)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            return folders.contains {
                $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 1_000
            }
        }

        let inbox = try #require(await inboxFolder(store))
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        let uids = try await store.uids(in: generation)
        #expect(uids.count == 1_000)
        var quarantined: [UInt32] = []
        for uid in uids {
            let id = try #require(await store.messageID(generation: generation, uid: uid))
            if try await store.detail(id).isQuarantined {
                quarantined.append(uid.rawValue)
            }
        }
        #expect(quarantined == [poisonedUID])
        #expect(world.snapshotMetadataFetchRanges().count <= 40)
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
        try await store.enqueueFlag(account: sampleConfig().id,
        folder: inbox.id,
        uidValidity: 3,
        uid: IMAPUID(rawValue: 1), flag: .seen, set: true)
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotFlagQueue().isEmpty && world.seenUIDs().contains(1)
        }

        world.storeSeenError = IMAPError.taggedNO(tag: "t", message: "nope", code: nil)
        try await store.enqueueFlag(account: sampleConfig().id,
        folder: inbox.id,
        uidValidity: 3,
        uid: IMAPUID(rawValue: 2), flag: .seen, set: true)
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotFlagQueue().isEmpty
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
        let page = try await store.page(in: inbox.id, after: nil, limit: 1, sort: .newest)
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
        let page = try await store.page(in: inbox.id, after: nil, limit: 1, sort: .newest)
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
        let page = try await store.page(in: inbox.id, after: nil, limit: 1, sort: .newest)
        let id = try #require(page.rows.first?.id)
        let ref = try #require(await store.messageRef(id))
        let oldGeneration = ref.generation
        #expect(oldGeneration.uidValidity == 1)

        let caches = dir.appendingPathComponent("Caches", isDirectory: true)
        func cacheListing() -> [String] {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(atPath: caches.path) else { return [] }
            return (enumerator.allObjects as? [String] ?? []).sorted()
        }
        let before = cacheListing()
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
        let detail = try await store.detail(id)
        #expect(detail.envelope.subject == "src")
        #expect(try await store.uids(in: oldGeneration) == [IMAPUID(rawValue: 1)])

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

@Test(arguments: [
    ["IMAP4REV1", "IDLE", "CONDSTORE"],
    ["IMAP4REV1", "IDLE", "CONDSTORE", "QRESYNC", "ENABLE"],
])
func engineReconcilesOfflineFlagsWithoutUIDNEXTChange(_ tokens: [String]) async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        box.messages[1] = makePlainMessage(uid: 1, subject: "cached", modSeq: 1)
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: tokens),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let first = makeEngine(store: store, world: world, dir: dir).0
        await first.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 1 }
        }
        await first.stop()
        world.updateMailbox("INBOX") { live in
            live.messages[1]?.flags = ["\\Seen"]
            live.messages[1]?.modSeq = 2
            live.highestModSeq = 2
        }
        let second = makeEngine(store: store, world: world, dir: dir).0
        await second.start()
        do {
            try await waitUntil(timeout: .seconds(3)) {
                try await store.fetchFolders(account: sampleConfig().id)
                    .contains { $0.role == .inbox && $0.totalCount == 1 && $0.unreadCount == 0 }
            }
        } catch {
            await second.stop()
            throw error
        }
        await second.stop()
    }
}

@Test(arguments: [
    ["IMAP4REV1", "IDLE"],
    ["IMAP4REV1", "IDLE", "CONDSTORE"],
    ["IMAP4REV1", "IDLE", "CONDSTORE", "QRESYNC", "ENABLE"],
])
func engineIngestsOfflineMailOnReconnectWithoutRefetchingHistory(_ tokens: [String]) async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 4, highestModSeq: 4)
        box.messages[1] = makePlainMessage(uid: 1, subject: "old-1", body: "alpha", modSeq: 3)
        box.messages[2] = makePlainMessage(uid: 2, subject: "old-2", body: "beta", modSeq: 3)
        box.messages[3] = makePlainMessage(uid: 3, subject: "old-3", body: "gamma", modSeq: 3)
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: tokens),
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
            live.messages[1]?.flags = ["\\Seen"]
            live.messages[1]?.modSeq = 7
            live.messages[4] = makePlainMessage(uid: 4, subject: "offline", body: "delta live")
            live.uidNext = 5
            live.highestModSeq = 8
        }

        let second = makeEngine()
        let mail = await second.newMail
        await second.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("delta", limit: 5).count == 1
        }
        let event = try await nextMailEvent(from: mail, timeout: .seconds(2))
        #expect(event.subject == "offline")
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        #expect(inbox.totalCount == 4)
        #expect(inbox.unreadCount == 3)
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
        // IDLE is opened only after the initial backfill pass. Wait for its
        // scripted readiness before publishing the UIDVALIDITY replacement so
        // the refresh cannot race socket setup.
        await world.waitForIdleStart()

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
        let page = try await store.page(in: inbox.id, after: nil, limit: 10, sort: .newest)
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
            guard state?.backfillPhase == .halted && inbox.totalCount >= 2 else { return false }
            let logs = try await store.fetchErrorLog(limit: 20)
            return logs.contains { $0.message.contains("halted") }
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
        let logs = try await store.fetchErrorLog(limit: 20)
        #expect(!logs.contains {
            $0.kind == .sync && $0.detail?.contains("Connection closed") == true
        })
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
        world.cancelMetadataFetchContainingUID = 4

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
            guard let inbox = try await store.fetchFolders(account: sampleConfig().id)
                .first(where: { $0.role == .inbox }),
                let generation = try await store.liveGeneration(for: inbox.id)
            else { return false }
            return try await store.fetchSyncState(for: generation)?.lowWaterUID?.rawValue == 5
        }
        try await waitUntil(timeout: .seconds(2)) { world.didCancelMetadataFetch() }
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
        let mail = await second.newMail
        await second.start()
        try await waitUntil(timeout: .seconds(8)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 8 }
        }
        let logs = try await store.fetchErrorLog()
        #expect(logs.contains { $0.message == "resuming backfill from cursor" })

        world.updateMailbox("INBOX") { live in
            live.messages[9] = makePlainMessage(uid: 9, subject: "live-new", body: "fresh")
            live.uidNext = 10
            live.highestModSeq = 12
        }
        await second.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("fresh", limit: 5).count == 1
        }
        let event = try await nextMailEvent(from: mail, timeout: .seconds(2))
        #expect(event.subject == "live-new")
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
    let page = try await store.page(in: inbox.id, after: nil, limit: 10, sort: .newest)
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

@Test func engineSurfacesTerminalAuthFailureAndStopsRetrying() async throws {
    try await withSyncStore { store, dir in
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": ScriptedMailbox(path: "INBOX")]
        )
        world.setConnectError(IMAPError.auth("Invalid credentials"))
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        let seen = EventCountLog()
        let stream = await engine.failures
        let collector = Task {
            for await failure in stream {
                if case .authentication = failure { seen.append(1) }
            }
        }
        await engine.start()
        try await waitUntil(timeout: .seconds(2)) { seen.snapshot().contains(1) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(world.snapshotConnectAttempts() == 1)
        await engine.stop()
        collector.cancel()
    }
}

@Test func seenDrainDropsStoreWhenSelectUIDValidityDiffers() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 3, uidNext: 2, highestModSeq: 4)
        box.messages[1] = makePlainMessage(uid: 1, subject: "orig")
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
            disk: ampleDisk(),
            clock: { Date() },
            settings: testSettings(dir: dir)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 1 }
        }
        world.updateMailbox("INBOX") { live in
            live.uidValidity = 99
            live.uidNext = 2
            live.messages = [
                1: makePlainMessage(uid: 1, subject: "replacement", flags: []),
            ]
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        try await store.enqueueFlag(account: sampleConfig().id,
        folder: inbox.id,
        uidValidity: 3,
        uid: IMAPUID(rawValue: 1), flag: .seen, set: true)
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotFlagQueue().isEmpty
        }
        #expect(world.seenUIDs().isEmpty)
        await engine.stop()
    }
}

@Test(
    "equal-EXISTS expunge across a paused quarantine fallback never resurrects the expunged UID",
    arguments: EqualExistsRacePath.allCases
)
func staleQuarantineFallbackCannotResurrectExpungedUID(
    path: EqualExistsRacePath
) async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 3, highestModSeq: 2)
        box.messages[1] = makePlainMessage(uid: 1, subject: "keep")
        box.messages[2] = makePlainMessage(uid: 2, subject: "stale")
        let world = ScriptedWorld(
            capabilities: path.capabilities,
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        // The first backfill metadata FETCH fails, forcing quarantineUnknown.
        world.fetchError = ScriptedFetchError.metadata
        world.fetchErrorAfter = 1
        world.pauseFlagFallback = true
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )
        await engine.start()
        // Deadlines here are generous: under full-suite parallel load the
        // scripted engine can take several seconds to reach the fallback.
        try await waitUntil(timeout: .seconds(15)) {
            world.flagFallbackDidEnter()
        }

        // FLAGS captured UID 2 before the EXPUNGE. Queue a refresh behind
        // the in-flight command, then publish the authoritative replacement
        // while the stale response remains paused.
        await Task.yield()
        let refreshTask = Task(priority: .high) {
            await engine.refreshNow()
        }
        world.updateMailbox("INBOX") { live in
            live.messages.removeValue(forKey: 2)
            live.messages[3] = makePlainMessage(uid: 3, subject: "replacement", body: "new")
            live.uidNext = 4
            live.highestModSeq = 3
        }
        world.releaseFlagFallback()
        await refreshTask.value

        let inbox = try #require(await inboxFolder(store))
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        try await waitUntil(timeout: .seconds(15)) {
            guard world.flagFallbackDidReturn() else { return false }
            return try await store.uids(in: generation) == [
                IMAPUID(rawValue: 1),
                IMAPUID(rawValue: 3),
            ]
        }
        let stored = try await store.uids(in: generation)
        let authoritative = world.mailbox("INBOX")
        await engine.stop()

        let page = try await store.page(in: inbox.id, after: nil, limit: 10, sort: .newest)
        #expect(authoritative.exists == 2)
        #expect(authoritative.uidNext == 4)
        #expect(authoritative.messages.keys.sorted() == [1, 3])
        #expect(stored == [IMAPUID(rawValue: 1), IMAPUID(rawValue: 3)])
        #expect(try await store.messageID(generation: generation, uid: IMAPUID(rawValue: 2)) == nil)
        #expect(page.rows.count == 2)
        // Under parallel load, the failed UID 1 FETCH may be repaired by a
        // later delta before this assertion. The invariant is that the
        // authoritative replacement is present and stale UID 2 is absent.
        #expect(page.rows.contains { $0.subject == "replacement" })
        let replacementID = try #require(await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 3)
        ))
        #expect(try await store.detail(replacementID).isQuarantined == false)
    }
}

@Test func engineStopCancelsPausedFlagFallbackWithoutStaleQuarantine() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 3, highestModSeq: 2)
        box.messages[1] = makePlainMessage(uid: 1, subject: "keep")
        box.messages[2] = makePlainMessage(uid: 2, subject: "paused")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        // Force the first metadata FETCH into quarantineUnknown, then pause
        // its FLAGS fallback until stop closes the scripted client.
        world.fetchError = ScriptedFetchError.metadata
        world.fetchErrorAfter = 1
        world.pauseFlagFallback = true
        let factory = ScriptedFactory(world: world)
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )

        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            world.flagFallbackDidEnter()
        }

        // Do not release the gate here: stop must cancel the operation and
        // close the client, which releases the paused FLAGS continuation.
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await engine.stop()
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw WaitTimeout()
            }
            let stopped = try await group.next()!
            group.cancelAll()
            #expect(stopped)
        }

        // The dedicated INBOX IDLE socket and the primary command socket are
        // both closed during teardown.
        #expect(await factory.closedClientCount() == 2)
        let inbox = try #require(await inboxFolder(store))
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        let state = try #require(await store.fetchSyncState(for: generation))
        #expect(state.lowWaterUID == nil)
        #expect(try await store.uids(in: generation).isEmpty)
        #expect(try await store.page(in: inbox.id, after: nil, limit: 10, sort: .newest).rows.isEmpty)
        try await assertStoreInvariants(store)
    }
}

@Test func ingestWindowDiscardsWhenGenerationChangesMidFetch() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 5, highestModSeq: 2)
        for n in 1...4 {
            let uid = UInt32(n)
            box.messages[uid] = makePlainMessage(uid: uid, subject: "g1-\(uid)", body: "body-\(uid)")
        }
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.fetchNanos = 400_000_000
        world.stallFetchesAfter = 0
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date() },
            settings: testSettings(dir: dir, window: 2)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(2)) { world.snapshotFetchCount() >= 1 }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let captured = try #require(await store.liveGeneration(for: inbox.id))
        #expect(captured.uidValidity == 1)
        await engine.adoptFolderGenerationForTesting(
            inbox.id,
            MailboxGeneration(folder: inbox.id, uidValidity: 99)
        )
        try await Task.sleep(for: .milliseconds(600))
        await engine.stop()

        let oldUIDs = try await store.uids(in: captured).map(\.rawValue)
        #expect(!oldUIDs.contains(3))
        #expect(!oldUIDs.contains(4))
        let oldState = try await store.fetchSyncState(for: captured)
        #expect(oldState?.lowWaterUID == nil)
    }
}

@Test func basicPathReconcileExpungesInBoundedWindows() async throws {
    try await withSyncStore { store, dir in
        var box = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 6, highestModSeq: 2)
        for n in 1...5 {
            let uid = UInt32(n)
            box.messages[uid] = makePlainMessage(uid: uid, subject: "keep-\(uid)")
        }
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
            disk: ampleDisk(),
            clock: { Date() },
            settings: testSettings(dir: dir, window: 2, flagSweep: 2)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 5 }
        }
        world.updateMailbox("INBOX") { live in
            live.messages.removeValue(forKey: 2)
            live.messages.removeValue(forKey: 5)
        }
        world.resetFlagFetchRanges()
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.totalCount == 3 }
        }
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        #expect(try await store.uids(in: generation).map(\.rawValue) == [1, 3, 4])
        let sweeps = world.snapshotFlagFetchRanges()
        #expect(sweeps.contains { $0 == [1...2] })
        #expect(sweeps.contains { $0 == [3...4] })
        #expect(sweeps.contains { $0 == [5...5] })
        #expect(!sweeps.contains { $0 == [1...5] })
        await engine.stop()
    }
}

@Test func engineUsesAnEightyMessageFirstWindowThenConfiguredThroughput() async throws {
    try await withSyncStore { store, dir in
        let box = populatedInbox(uidValidity: 1, count: 2_000, highestModSeq: 2)
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
            disk: ampleDisk(),
            clock: { Date() },
            settings: testSettings(dir: dir, window: 1_000)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(8)) {
            world.snapshotMetadataFetchRanges().count >= 2
        }
        let ranges = world.snapshotMetadataFetchRanges()
        #expect(ranges[0] == [1_921...2_000])
        #expect(ranges[1] == [921...1_920])
        await engine.stop()
    }
}

@Test func engineRepairsLegacyCompleteBackfillWithoutResettingHealthyGeneration() async throws {
    try await withSyncStore { store, dir in
        let box = populatedInbox(uidValidity: 1, count: 10, highestModSeq: 2)
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let lowDisk = FixedDisk(freeBytes: 1, volumeBytes: 100 * 1024 * 1024 * 1024)
        let incomplete = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: lowDisk,
            clock: { Date() },
            settings: testSettings(dir: dir, window: 2)
        )
        await incomplete.start()
        try await waitUntil(timeout: .seconds(5)) {
            let folders = try await store.fetchFolders(account: sampleConfig().id)
            guard let inbox = folders.first(where: { $0.role == .inbox }),
                  let generation = try await store.liveGeneration(for: inbox.id),
                  let state = try await store.fetchSyncState(for: generation)
            else { return false }
            return state.backfillPhase == .halted && inbox.totalCount == 2
        }
        await incomplete.stop()

        let folders = try await store.fetchFolders(account: sampleConfig().id)
        let inbox = try #require(folders.first { $0.role == .inbox })
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        var legacyState = try #require(await store.fetchSyncState(for: generation))
        legacyState.backfillPhase = .complete
        legacyState.progress = 1
        legacyState.haltedThrough = nil
        try await store.saveSyncState(legacyState)

        let repair = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date() },
            settings: testSettings(dir: dir, window: 2)
        )
        await repair.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete && $0.totalCount == 10 }
        }
        let repairLogs = try await store.fetchErrorLog()
        #expect(repairLogs.contains { $0.message == "repairing incomplete completed backfill" })
        let metadataAfterRepair = world.snapshotMetadataFetchRanges().count
        await repair.stop()

        // A complete generation whose local count matches the latest EXISTS
        // must remain complete and must not trigger another history walk.
        let healthy = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date() },
            settings: testSettings(dir: dir, window: 2)
        )
        await healthy.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(world.snapshotMetadataFetchRanges().count == metadataAfterRepair)
        await healthy.stop()
    }
}

@Test func engineReconcilesQresyncExpungeAfterRestartDeliverBurst() async throws {
    try await withSyncStore { store, dir in
        let box = populatedInbox(uidValidity: 1, count: 200, highestModSeq: 20)
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.fetchNanos = 10_000_000
        let factory = ScriptedFactory(world: world)
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store),
                  let generation = try await store.liveGeneration(for: inbox.id),
                  let state = try await store.fetchSyncState(for: generation)
            else { return false }
            return inbox.totalCount >= 2 && state.backfillPhase != .complete
        }

        // Drop both live connections and let the engine reconnect while history
        // remains in flight.
        await factory.emitAll(.bye("scripted restart"))
        try await waitUntil(timeout: .seconds(5)) {
            world.snapshotConnectAttempts() >= 2
        }

        // New UIDs arrive while the resumed backward walk is still active.
        world.updateMailbox("INBOX") { live in
            for uid in UInt32(201)...UInt32(220) {
                live.messages[uid] = makePlainMessage(uid: uid, subject: "burst-\(uid)")
            }
            live.uidNext = 221
            live.highestModSeq = 40
        }
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.search("burst-220", limit: 5).count == 1
        }

        // Model an expunge burst whose IDLE hint races the follow-up SELECT:
        // the selected QRESYNC response has no VANISHED list, so the delta must
        // use the observed EXISTS decrease to reconcile stored UIDs.
        world.updateMailbox("INBOX") { live in
            live.messages.removeValue(forKey: 201)
            live.messages.removeValue(forKey: 202)
            live.messages.removeValue(forKey: 203)
            live.highestModSeq = 43
            live.vanished = []
            live.vanishedEarlier = []
        }
        await engine.refreshNow()
        // Convergence walks ~110 two-UID windows at fetchNanos each; under
        // parallel-suite load 10s is marginal. Deadline is generous on purpose.
        try await waitUntil(timeout: .seconds(30)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            let complete = inbox.backfill == .complete
            return complete && inbox.totalCount == world.mailbox("INBOX").exists
        }
        let converged = try await requireInbox(store)
        #expect(converged.totalCount == 217)
        await engine.stop()
    }
}

@Test func engineRetriesBackfillAfterExpungeRevisionWithoutPeriodicPass() async throws {
    try await withSyncStore { store, dir in
        let box = populatedInbox(uidValidity: 1, count: 4, highestModSeq: 20)
        let world = ScriptedWorld(
            capabilities: qresyncCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        world.pauseMetadataFetch = true
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(
                dir: dir,
                window: 2,
                periodicTick: .seconds(3600)
            )
        )
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            world.metadataFetchDidEnter()
        }
        let inbox = try #require(await inboxFolder(store))

        // The paused FETCH captured all four UIDs. Remove one on the scripted
        // server and advance the same revision that a delta would publish.
        world.updateMailbox("INBOX") { live in
            live.messages.removeValue(forKey: 4)
        }
        await engine.bumpExpungeRevisionForTesting(inbox.id)
        world.releaseMetadataFetch()

        // A retry in backfillAll must complete this pass; the one-hour
        // periodic tick makes a later retry unable to mask the regression.
        try await waitUntil(timeout: .seconds(5)) {
            guard let latest = try await inboxFolder(store) else { return false }
            return latest.backfill == .complete && latest.totalCount == 3
        }
        await engine.stop()
    }
}

@Test func engineDrainsUnreadFlagAndTrashMoveWithExactCommands() async throws {
    try await withSyncStore { store, dir in
        var inbox = ScriptedMailbox(path: "INBOX", uidValidity: 4, uidNext: 2, highestModSeq: 2)
        inbox.messages[1] = makePlainMessage(uid: 1, subject: "mutate")
        let trash = ScriptedMailbox(path: "Trash", uidValidity: 1, uidNext: 1, highestModSeq: 1)
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]),
            folders: [inboxMailbox(), trashMailbox()],
            mailboxes: ["INBOX": inbox, "Trash": trash]
        )
        let engine = makeEngine(store: store, world: world, dir: dir, window: 1).0
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.fetchFolders(account: sampleConfig().id).contains { $0.role == .inbox && $0.totalCount == 1 }
        }
        let folder = try #require(await inboxFolder(store))
        try await store.enqueueFlag(
            account: sampleConfig().id,
            folder: folder.id,
            uidValidity: 4,
            uid: IMAPUID(rawValue: 1),
            flag: .seen,
            set: false
        )
        try await store.enqueueFlag(
            account: sampleConfig().id,
            folder: folder.id,
            uidValidity: 4,
            uid: IMAPUID(rawValue: 1),
            flag: .flagged,
            set: true
        )
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotFlagQueue().isEmpty
                && world.flagCommandSnapshot() == [
                    "STORE INBOX 1 -FLAGS.SILENT (\\Seen)",
                    "STORE INBOX 1 +FLAGS.SILENT (\\Flagged)",
                ]
        }
        try await store.enqueueMove(
            account: sampleConfig().id,
            folder: folder.id,
            uidValidity: 4,
            uid: IMAPUID(rawValue: 1),
            to: .trash
        )
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotMoveQueue().isEmpty
                && world.archiveCommandSnapshot() == ["MOVE INBOX Trash 1"]
        }
        await engine.stop()
    }
}
private func schedulerMailbox(
    path: String,
    role: FolderRole,
    count: Int
) -> (mailbox: IMAPMailbox, scripted: ScriptedMailbox) {
    let mailbox = IMAPMailbox(
        path: path,
        name: path,
        separator: "/",
        role: role,
        mailboxID: nil,
        attributes: []
    )
    var scripted = ScriptedMailbox(
        path: path,
        uidValidity: 1,
        uidNext: UInt32(count + 1),
        highestModSeq: 2
    )
    if count > 0 {
        for uid in 1...count {
            scripted.messages[UInt32(uid)] = makePlainMessage(
                uid: UInt32(uid),
                subject: "\(path)-\(uid)"
            )
        }
    }
    return (mailbox, scripted)
}

private func schedulerFolders() -> [
    (mailbox: IMAPMailbox, scripted: ScriptedMailbox)
] {
    [
        schedulerMailbox(path: "INBOX", role: .inbox, count: 4),
        schedulerMailbox(path: "Sent", role: .sent, count: 4),
        schedulerMailbox(path: "Projects", role: .none, count: 4),
    ]
}

private func prepareSchedulerFolders(
    _ store: MailStore,
    account: AccountConfig,
    keepLocally: Bool = true
) async throws -> [FolderID] {
    try await store.upsertAccount(account)
    var ids: [FolderID] = []
    for item in schedulerFolders().dropFirst() {
        let id = try await store.upsertFolder(
            account: account.id,
            path: item.mailbox.path,
            name: item.mailbox.name,
            separator: item.mailbox.separator,
            role: item.mailbox.role,
            objectID: nil
        )
        try await store.setKeepLocally(keepLocally, for: id)
        ids.append(id)
    }
    return ids
}

@Test func backfillSchedulerSkipsDisabledFoldersWithoutFetch() async throws {
    try await withSyncStore { store, dir in
        let config = sampleConfig()
        let fixtures = schedulerFolders()
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: fixtures.map(\.mailbox),
            mailboxes: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.scripted.path, $0.scripted) })
        )
        let engine = SyncEngine(
            store: store,
            config: config,
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )

        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            let summaries = try await store.fetchFolders(account: config.id)
            return summaries.contains {
                $0.path == "INBOX" && $0.backfill == .complete && $0.totalCount == 4
            }
        }
        #expect(!world.snapshotMetadataFetchPaths().contains("Projects"))
        let projects = try #require(
            try await store.fetchFolders(account: config.id).first { $0.path == "Projects" }
        )
        #expect(projects.keepLocally == false)
        #expect(projects.totalCount == 4)
        await engine.stop()
    }
}

@Test func enablingFolderQueuesBackfillWithinOneSchedulerTick() async throws {
    try await withSyncStore { store, dir in
        let config = sampleConfig()
        let fixtures = schedulerFolders()
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: fixtures.map(\.mailbox),
            mailboxes: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.scripted.path, $0.scripted) })
        )
        let factory = ScriptedFactory(world: world)
        let engine = SyncEngine(
            store: store,
            config: config,
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )

        await engine.start()
        let projects = try await waitUntilFolder(store, account: config.id, path: "Projects")
        try await store.setKeepLocally(true, for: projects.id)
        try await waitUntil(timeout: .seconds(2), poll: .milliseconds(10)) {
            await engine.setKeepLocally(true, for: projects.id)
            return world.snapshotMetadataFetchPaths().contains("Projects")
        }
        #expect(world.snapshotMetadataFetchPaths().contains("Projects"))
        await engine.stop()
    }
}

@Test func disablingFolderMidBackfillCancelsFetchAndKeepsRows() async throws {
    try await withSyncStore { store, dir in
        let config = sampleConfig()
        let fixtures = [schedulerMailbox(path: "Projects", role: .none, count: 20)]
        try await store.upsertAccount(config)
        let folderID = try await store.upsertFolder(
            account: config.id,
            path: "Projects",
            name: "Projects",
            separator: "/",
            role: .none,
            objectID: nil
        )
        try await store.setKeepLocally(true, for: folderID)
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [fixtures[0].mailbox],
            mailboxes: ["Projects": fixtures[0].scripted]
        )
        world.fetchNanos = 100_000_000
        let engine = SyncEngine(
            store: store,
            config: config,
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )

        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            (try await store.fetchFolderSummary(folderID))?.totalCount ?? 0 >= 2
        }
        let pathsBefore = world.snapshotMetadataFetchPaths().count
        try await store.setKeepLocally(false, for: folderID)
        await engine.setKeepLocally(false, for: folderID)
        try await Task.sleep(for: .milliseconds(250))
        let summary = try #require(await store.fetchFolderSummary(folderID))
        #expect(summary.keepLocally == false)
        #expect(summary.totalCount >= 2)
        #expect(world.snapshotMetadataFetchPaths().count <= pathsBefore + 1)
        await engine.stop()
    }
}

@Test func backfillInterleavesThreeFoldersAcrossThreeConnections() async throws {
    try await withSyncStore { store, dir in
        let config = sampleConfig()
        let ids = try await prepareSchedulerFolders(store, account: config)
        let fixtures = schedulerFolders()
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: fixtures.map(\.mailbox),
            mailboxes: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.scripted.path, $0.scripted) })
        )
        world.fetchNanos = 50_000_000
        let factory = ScriptedFactory(world: world)
        let engine = SyncEngine(
            store: store,
            config: config,
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )

        await engine.start()
        try await waitUntil(timeout: .seconds(10)) {
            try await store.fetchFolders(account: config.id).filter { $0.totalCount == 4 }.count == 3
        }
        #expect(ids.count == 2)
        let clientCount = factory.clientCount()
        #expect(clientCount == 4) // primary + IDLE + two workers
        #expect(world.snapshotMaxConcurrentFetches() >= 2)
        #expect(Set(world.snapshotMetadataFetchPaths()) == ["INBOX", "Sent", "Projects"])
        await engine.stop()
    }
}

@Test func backfillConnectionCapFallsBackToTwoWorkers() async throws {
    try await withSyncStore { store, dir in
        let config = sampleConfig()
        _ = try await prepareSchedulerFolders(store, account: config)
        let fixtures = schedulerFolders()
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: fixtures.map(\.mailbox),
            mailboxes: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.scripted.path, $0.scripted) })
        )
        world.fetchNanos = 40_000_000
        let factory = ScriptedFactory(
            world: world,
            secondConnectError: IMAPError.taggedNO(
                tag: "t",
                message: "Too many connections",
                code: nil
            ),
            connectErrorFromAttempt: 4
        )
        let engine = SyncEngine(
            store: store,
            config: config,
            credentials: StaticPassword(value: "pw"),
            clientFactory: factory,
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(dir: dir, window: 2)
        )

        await engine.start()
        try await waitUntil(timeout: .seconds(10)) {
            try await store.fetchFolders(account: config.id).filter { $0.totalCount == 4 }.count == 3
        }
        let clientCount = factory.clientCount()
        let closedClientCount = await factory.closedClientCount()
        #expect(clientCount == 4) // fourth attempt is rejected
        #expect(closedClientCount == 1) // rejected attempt
        #expect(world.snapshotMaxConcurrentFetches() >= 2)
        await engine.stop()
    }
}

private actor FolderSummaryResult {
    private var value: FolderSummary?

    func set(_ value: FolderSummary?) {
        self.value = value
    }

    func get() -> FolderSummary? {
        value
    }
}

private func waitUntilFolder(
    _ store: MailStore,
    account: AccountID,
    path: String
) async throws -> FolderSummary {
    let result = FolderSummaryResult()
    try await waitUntil(timeout: .seconds(5)) {
        let value = try await store.fetchFolders(account: account).first { $0.path == path }
        await result.set(value)
        return value != nil
    }
    return try #require(await result.get())
}
