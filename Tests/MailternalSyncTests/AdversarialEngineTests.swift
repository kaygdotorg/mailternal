import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

/// Scripted, deterministic adversarial coverage for persisted mutation queues.
/// Each scenario uses its own in-memory server world and a serialized suite so
/// no timing or shared-server state can affect the result.
@Suite(.serialized)
struct AdversarialEngineTests {
    @Test
    func badMoveDropsOperationRestoresOptimisticMessageAndLogsError() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 1, capabilities: moveCapabilities())
            world.moveError = IMAPError.taggedBAD(tag: "t", message: "MOVE rejected", code: nil)
            let engine = makeEngine(store: store, world: world, dir: dir).0
            await engine.start()
            let inbox = try await waitForAdversarialInbox(store, count: 1)
            let message = try #require(try await store.page(in: inbox.id, after: nil, limit: 10).rows.first)

            let completedFetches = world.snapshotCompletedFetchCount()
            try await store.enqueueMove(message: message.id, to: .archive)
            try await waitUntil(timeout: .seconds(5)) {
                let queue = try await store.snapshotMoveQueue()
                let errors = try await store.fetchErrorLog()
                return queue.isEmpty && errors.contains {
                    $0.kind == .archive && $0.message.contains("BAD")
                }
            }

            #expect(world.mailbox("INBOX").messages[1] != nil)
            #expect(world.mailbox("Archive").messages[1] == nil)
            await world.waitForFetchCompletion(after: completedFetches)
            try await waitUntil(timeout: .seconds(5)) {
                try await store.page(in: inbox.id, after: nil, limit: 10).rows.count == 1
            }
            #expect(world.archiveCommandSnapshot().isEmpty)
            await engine.stop()
        }
    }

    @Test
    func moveCapabilityLossUsesCopyStoreExpungeFallback() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 1, capabilities: moveCapabilities())
            let engine = makeEngine(store: store, world: world, dir: dir).0
            await engine.start()
            let inbox = try await waitForAdversarialInbox(store, count: 1)
            let message = try #require(try await store.page(in: inbox.id, after: nil, limit: 10).rows.first)

            // The first session advertised MOVE. Remove it only after the
            // generation is synchronized, then enqueue the operation.
            setWorldCapabilities(world, basicCaps())
            try await store.enqueueMove(message: message.id, to: .archive)

            try await waitUntil(timeout: .seconds(5)) {
                try await store.snapshotMoveQueue().isEmpty
                    && world.archiveCommandSnapshot() == [
                        "COPY INBOX Archive 1",
                        "STORE INBOX 1",
                        "EXPUNGE INBOX 1",
                    ]
            }
            #expect(world.mailbox("INBOX").messages[1] == nil)
            #expect(world.mailbox("Archive").messages[1] != nil)
            await engine.stop()
        }
    }

    @Test
    func halfFlagStoresTaggedNoDropOnlyRejectedUIDs() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 4, capabilities: basicCaps())
            let factory = HalfNoFactory(world: world)
            let engine = SyncEngine(
                store: store,
                config: sampleConfig(),
                credentials: StaticPassword(value: "pw"),
                clientFactory: factory,
                disk: ampleDisk(),
                clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                settings: chaosSettings(dir: dir, window: 2, allowEnableQResync: false)
            )
            await engine.start()
            let inbox = try await waitForAdversarialInbox(store, count: 4)
            let rows = try await store.page(in: inbox.id, after: nil, limit: 10).rows
            for row in rows {
                try await store.enqueueFlag(message: row.id, flag: .seen, set: true)
            }

            try await waitUntil(timeout: .seconds(5)) {
                let queue = try await store.snapshotFlagQueue()
                let errors = try await store.fetchErrorLog()
                return queue.isEmpty && errors.filter { $0.kind == .seen }.count == 2
            }
            let errors = try await store.fetchErrorLog()
            #expect(errors.filter { $0.kind == .seen }.count == 2)
            #expect(world.flagCommandSnapshot().count == 2)
            for uid in [UInt32(1), UInt32(3)] {
                #expect(world.mailbox("INBOX").messages[uid]?.flags.contains("\\Seen") == true)
            }
            for uid in [UInt32(2), UInt32(4)] {
                #expect(world.mailbox("INBOX").messages[uid]?.flags.contains("\\Seen") != true)
            }
            await engine.stop()
        }
    }

    @Test
    func expungedUIDInMoveAndFlagQueuesDrainsBothWithoutGhostRow() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 1, capabilities: basicCaps())
            let engine = makeEngine(store: store, world: world, dir: dir, allowEnableQResync: false).0
            await engine.start()
            let inbox = try await waitForAdversarialInbox(store, count: 1)
            let generation = try #require(await store.liveGeneration(for: inbox.id))
            await engine.stop()

            try await store.enqueueFlag(
                account: sampleConfig().id,
                folder: inbox.id,
                uidValidity: generation.uidValidity,
                uid: IMAPUID(rawValue: 1),
                flag: .seen,
                set: true
            )
            try await store.enqueueMove(
                account: sampleConfig().id,
                folder: inbox.id,
                uidValidity: generation.uidValidity,
                uid: IMAPUID(rawValue: 1),
                to: .archive
            )
            #expect(try await store.snapshotFlagQueue().count == 1)
            #expect(try await store.snapshotMoveQueue().count == 1)

            await engine.start()
            try await waitUntil(timeout: .seconds(5)) {
                let flags = try await store.snapshotFlagQueue()
                let moves = try await store.snapshotMoveQueue()
                return flags.isEmpty && moves.isEmpty
            }
            #expect(world.flagCommandSnapshot() == ["STORE INBOX 1 +FLAGS.SILENT (\\Seen)"])
            #expect(world.archiveCommandSnapshot() == [
                "COPY INBOX Archive 1",
                "STORE INBOX 1",
                "EXPUNGE INBOX 1",
            ])
            #expect(world.mailbox("INBOX").messages[1] == nil)
            #expect(world.mailbox("Archive").messages[1] != nil)
            #expect(try await store.page(in: inbox.id, after: nil, limit: 10).rows.isEmpty)
            await engine.stop()
        }
    }

    @Test
    func uidValidityBumpDropsBothQueuesWithoutServerWrites() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 1, capabilities: basicCaps())
            let engine = makeEngine(store: store, world: world, dir: dir, allowEnableQResync: false).0
            await engine.start()
            let inbox = try await waitForAdversarialInbox(store, count: 1)
            let generation = try #require(await store.liveGeneration(for: inbox.id))
            await engine.stop()

            try await store.enqueueFlag(
                account: sampleConfig().id,
                folder: inbox.id,
                uidValidity: generation.uidValidity,
                uid: IMAPUID(rawValue: 1),
                flag: .seen,
                set: true
            )
            try await store.enqueueMove(
                account: sampleConfig().id,
                folder: inbox.id,
                uidValidity: generation.uidValidity,
                uid: IMAPUID(rawValue: 1),
                to: .archive
            )
            world.updateMailbox("INBOX") { $0.uidValidity = 2 }

            await engine.start()
            try await waitUntil(timeout: .seconds(10)) {
                guard let live = try await store.liveGeneration(for: inbox.id) else { return false }
                let flags = try await store.snapshotFlagQueue()
                let moves = try await store.snapshotMoveQueue()
                return live.uidValidity == 2 && flags.isEmpty && moves.isEmpty
            }
            #expect(world.flagCommandSnapshot().isEmpty)
            #expect(world.archiveCommandSnapshot().isEmpty)
            await engine.stop()
        }
    }

    @Test
    func thousandMoveOperationsSurviveThreeRestartsAndDrainInBatches() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 1_000, capabilities: moveCapabilities())
            let engine = makeEngine(store: store, world: world, dir: dir, window: 100).0
            await engine.start()
            let inbox = try await waitForAdversarialInbox(store, count: 1_000, timeout: .seconds(30))
            let rows = try await store.page(in: inbox.id, after: nil, limit: 1_000).rows
            #expect(rows.count == 1_000)
            await engine.stop()

            let archive = try #require(
                (try await store.fetchFolders(account: sampleConfig().id))
                    .first(where: { $0.role == .archive })?.id
            )
            try await store.enqueueMove(messages: rows.map(\.id), to: archive)
            let queued = try await store.snapshotMoveQueue(limit: 2_000).count
            #expect(queued == 1_000)

            // Two failed sessions prove the queue is retained; the third
            // restart clears the transport fault and drains every batch.
            world.moveError = IMAPError.transport("simulated connection loss")
            for _ in 1...2 {
                await engine.start()
                try await waitUntil(timeout: .seconds(5)) {
                    try await store.snapshotMoveQueue(limit: 2_000).count == 1_000
                }
                await engine.stop()
            }
            world.moveError = nil
            await engine.start()
            try await waitUntil(timeout: .seconds(30)) {
                try await store.snapshotMoveQueue().isEmpty
                    && world.mailbox("Archive").messages.count == 1_000
            }
            #expect(world.mailbox("INBOX").messages.isEmpty)
            #expect(world.archiveCommandSnapshot().count == 32)
            await engine.stop()
        }
    }

    @Test
    func twoEnginesSharingOneStoreSerializeQueueAndDoNotDuplicateMove() async throws {
        try await withSyncStore { store, dir in
            let world = adversarialWorld(count: 1, capabilities: moveCapabilities())
            let (first, _) = makeEngine(store: store, world: world, dir: dir)
            let (second, _) = makeEngine(store: store, world: world, dir: dir)
            await first.start()
            await second.start()
            let inbox = try await waitForAdversarialInbox(store, count: 1)
            let row = try #require(try await store.page(in: inbox.id, after: nil, limit: 10).rows.first)
            try await store.enqueueMove(message: row.id, to: .archive)

            try await waitUntil(timeout: .seconds(10)) {
                try await store.snapshotMoveQueue().isEmpty
                    && world.mailbox("INBOX").messages[1] == nil
                    && world.mailbox("Archive").messages[1] != nil
            }
            #expect(world.archiveCommandSnapshot() == ["MOVE INBOX Archive 1"])
            try await assertStoreInvariants(store)
            await first.stop()
            await second.stop()
        }
    }
}

private func adversarialWorld(count: UInt32, capabilities: IMAPCapabilities) -> ScriptedWorld {
    let inbox = populatedInbox(uidValidity: 1, count: count, prefix: "adversarial")
    let archive = ScriptedMailbox(path: "Archive", uidValidity: 1)
    return ScriptedWorld(
        capabilities: capabilities,
        folders: [inboxMailbox(), adversarialArchiveMailbox()],
        mailboxes: ["INBOX": inbox, "Archive": archive]
    )
}

private func adversarialArchiveMailbox() -> IMAPMailbox {
    IMAPMailbox(
        path: "Archive",
        name: "Archive",
        separator: "/",
        role: .archive,
        mailboxID: nil,
        attributes: ["\\Archive"]
    )
}

private func moveCapabilities() -> IMAPCapabilities {
    IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"])
}

private func waitForAdversarialInbox(
    _ store: MailStore,
    count: Int,
    timeout: Duration = .seconds(10)
) async throws -> FolderSummary {
    try await waitUntil(timeout: timeout) {
        guard let inbox = try await inboxFolder(store) else { return false }
        return inbox.totalCount == count && inbox.backfill == .complete
    }
    guard let inbox = try await inboxFolder(store) else { throw WaitTimeout() }
    return inbox
}

private struct HalfNoIMAPClient: IMAPClient {
    let base: ScriptedIMAPClient

    var events: AsyncStream<IMAPMailboxEvent> { base.events }

    func capabilities() async -> IMAPCapabilities { await base.capabilities() }
    func selectedMailbox() async -> IMAPSelectedMailbox? { await base.selectedMailbox() }
    func connect() async throws { try await base.connect() }
    func close() async { await base.close() }
    func listFolders() async throws -> IMAPFolderDiscovery { try await base.listFolders() }
    func select(_ mailbox: String, qresync: IMAPQResyncSelect?) async throws -> IMAPSelectedMailbox {
        try await base.select(mailbox, qresync: qresync)
    }
    func enableQResync() async throws { try await base.enableQResync() }
    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        try await base.fetch(request)
    }
    func storeFlags(uids: IMAPUIDSet, flag: FlagKind, set: Bool) async throws {
        let reject = uids.ranges.contains { $0.contains(2) || $0.contains(4) }
        if reject {

            throw IMAPError.taggedNO(tag: "t", message: "half UID set rejected", code: nil)
        }
        try await base.storeFlags(uids: uids, flag: flag, set: set)
    }
    func storeSeen(uids: IMAPUIDSet) async throws { try await base.storeSeen(uids: uids) }
    func move(uids: IMAPUIDSet, to mailbox: String) async throws {
        try await base.move(uids: uids, to: mailbox)
    }
    func copy(uids: IMAPUIDSet, to mailbox: String) async throws {
        try await base.copy(uids: uids, to: mailbox)
    }
    func storeDeleted(uids: IMAPUIDSet) async throws { try await base.storeDeleted(uids: uids) }
    func expunge(uids: IMAPUIDSet) async throws { try await base.expunge(uids: uids) }
    func beginIdle() async throws -> IMAPIdle { try await base.beginIdle() }
    func endIdle() async throws { try await base.endIdle() }
    func renewIdle() async throws -> IMAPIdle { try await base.renewIdle() }
}

private final class HalfNoFactory: IMAPClientFactory, @unchecked Sendable {
    let world: ScriptedWorld

    init(world: ScriptedWorld) { self.world = world }

    func makeClient(endpoint: IMAPEndpoint, username: String, password: String) -> any IMAPClient {
        HalfNoIMAPClient(base: ScriptedIMAPClient(world: world))
    }
}
private func setWorldCapabilities(_ world: ScriptedWorld, _ capabilities: IMAPCapabilities) {
    world.lock.lock()
    world.capabilities = capabilities
    world.lock.unlock()
}
