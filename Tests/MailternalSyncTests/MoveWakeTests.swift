import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

@Test
func enqueuedMoveDrainsOnRefreshWithoutPeriodicTick() async throws {
    try await withSyncStore { store, dir in
        var inboxBox = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        inboxBox.messages[1] = makePlainMessage(uid: 1, subject: "wake move", body: "wake body")
        let destinationPath = "Horrors2"
        let destinationMailbox = IMAPMailbox(
            path: destinationPath,
            name: destinationPath,
            separator: "/",
            role: .none,
            mailboxID: nil,
            attributes: []
        )
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]),
            folders: [inboxMailbox(), destinationMailbox],
            mailboxes: [
                "INBOX": inboxBox,
                destinationPath: ScriptedMailbox(path: destinationPath, uidValidity: 1)
            ]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(
                dir: dir,
                seenPoll: .seconds(30),
                periodicTick: .seconds(30)
            )
        )
        await engine.start()
        defer { Task { await engine.stop() } }

        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.totalCount == 1 && inbox.backfill == .complete
        }
        let inboxFolderSummary = try #require(await inboxFolder(store))
        let message = try #require(
            try await store.page(in: inboxFolderSummary.id, after: nil, limit: 10, sort: .newest).rows.first
        )
        let destination = try #require(
            try await store.fetchFolders(account: sampleConfig().id)
                .first(where: { $0.path == destinationPath })
        )
        try await store.enqueueMove(messages: [message.id], to: destination.id)

        let refresh = Task { await engine.refreshNow() }
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(20)) {
            let queued = try await store.snapshotMoveQueue()
            return world.archiveCommandSnapshot() == ["MOVE INBOX \(destinationPath) 1"]
                && queued.isEmpty
        }
        await refresh.value
        #expect(world.mailbox("INBOX").messages[1] == nil)
        #expect(world.mailbox(destinationPath).messages[1] != nil)
    }
}

@Test
func moveWakePreemptsConcurrentBackfill() async throws {
    try await withSyncStore { store, dir in
        let destinationPath = "Horrors2"
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]),
            folders: [inboxMailbox(), IMAPMailbox(
                path: destinationPath,
                name: destinationPath,
                separator: "/",
                role: .archive,
                mailboxID: nil,
                attributes: []
            )],
            mailboxes: [
                "INBOX": populatedInbox(uidValidity: 1, count: 20),
                destinationPath: ScriptedMailbox(path: destinationPath, uidValidity: 1)
            ]
        )
        world.fetchNanos = 50_000_000
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
                seenPoll: .seconds(30),
                periodicTick: .seconds(30)
            )
        )
        let activity = await engine.activity
        let activityLog = ActivityLog()
        let activityTask = Task {
            for await update in activity {
                await activityLog.record(update)
            }
        }
        await engine.start()
        defer {
            activityTask.cancel()
            Task { await engine.stop() }
        }

        try await waitUntil(timeout: .seconds(3)) {
            guard let folder = try await inboxFolder(store) else { return false }
            return try await store.liveGeneration(for: folder.id) != nil
        }
        let inbox = try #require(await inboxFolder(store))
        let generation = try #require(try await store.liveGeneration(for: inbox.id))
        let seed = IncomingMessage(
            generation: generation,
            uid: IMAPUID(rawValue: 1),
            envelope: Envelope(
                subject: "seed",
                from: [MailAddress(displayName: "Alice", address: "alice@example.com")],
                to: [MailAddress(displayName: nil, address: "qa@example.com")],
                cc: [],
                replyTo: [],
                internalDate: Date(timeIntervalSince1970: 1_800_000_000),
                headerDate: nil,
                rfcMessageID: nil,
                inReplyTo: nil,
                references: []
            ),
            bodyText: "seed"
        )
        _ = try await store.upsertMessages([seed])
        let message = try #require(
            try await store.page(in: inbox.id, after: nil, limit: 10, sort: .newest).rows.first
        )
        let destination = try #require(
            try await store.fetchFolders(account: sampleConfig().id)
                .first(where: { $0.path == destinationPath })
        )
        world.pauseMetadataFetch = true
        try await waitUntil(timeout: .seconds(3)) {
            return world.metadataFetchDidEnter()
        }
        let fetchesAtWake = world.snapshotFetchCount()
        try await store.enqueueMove(messages: [message.id], to: destination.id)

        let started = ContinuousClock.now
        let wake = Task { await engine.moveNow() }
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(5)) {
            !world.archiveCommandSnapshot().isEmpty
        }
        let elapsed = started.duration(to: ContinuousClock.now)
        #expect(elapsed < .milliseconds(500))
        let archiveFetches = world.snapshotArchiveFetchCounts()
        #expect((archiveFetches.first ?? .max) - fetchesAtWake <= 1)
        world.releaseMetadataFetch()
        await wake.value
        try await waitUntil(timeout: .seconds(3)) {
            let moving = await activityLog.movingFolders()
            return moving.contains(inbox.id) && moving.contains(destination.id)
        }


        try await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) {
            let rows = try await store.page(
                in: destination.id,
                after: nil,
                limit: 10, sort: .newest
            ).rows
            return !rows.isEmpty
        }
        try await waitUntil(timeout: .seconds(5), poll: .milliseconds(20)) {
            let latest = await activityLog.snapshot()
            return latest[inbox.id] == .idle && latest[destination.id] == .idle
        }
        await engine.stop()
    }
}
private actor ActivityLog {
    private var latest: [FolderID: FolderActivity] = [:]
    private var observedMoving: Set<FolderID> = []

    func record(_ update: FolderActivityUpdate) {
        latest[update.folder] = update.activity
        if update.activity == .moving {
            observedMoving.insert(update.folder)
        }
    }

    func snapshot() -> [FolderID: FolderActivity] {
        latest
    }

    func movingFolders() -> Set<FolderID> {
        observedMoving
    }
}
