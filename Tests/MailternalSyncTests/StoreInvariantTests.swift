import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

@Test func storeInvariantCheckerAcceptsCleanSyncAndFlagsCursorAndFTSDrift() async throws {
    try await withSyncStore { store, dir in
        let empty = try await store.checkInvariants()
        #expect(empty.isClean)
        #expect(empty.messageCount == 0)
        #expect(empty.ftsCount == 0)

        let box = populatedInbox(uidValidity: 3, count: 4, prefix: "inv")
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": box]
        )
        let (engine, _) = makeEngine(store: store, world: world, dir: dir)
        await engine.start()
        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.totalCount == 4 && inbox.backfill == .complete
        }
        await engine.stop()

        try await assertStoreInvariants(store, drain: true, expectEmptySeen: true, expectNoReplacement: true)
        let clean = try await store.checkInvariants()
        #expect(clean.messageCount == 4)
        #expect(clean.ftsCount == 4)

        let inbox = try await requireInbox(store)
        let generation = try #require(await store.liveGeneration(for: inbox.id))
        var state = try #require(await store.fetchSyncState(for: generation))
        state.lowWaterUID = IMAPUID(rawValue: 99)
        try await store.saveSyncState(state)
        let drifted = try await store.checkInvariants()
        #expect(!drifted.isClean)
        #expect(drifted.cursorBeyondUidNextCount == 1)
        #expect(drifted.issues.contains { $0.contains("UIDNEXT") })

        state.lowWaterUID = IMAPUID(rawValue: 1)
        try await store.saveSyncState(state)
        let restored = try await store.checkInvariants()
        #expect(restored.cursorBeyondUidNextCount == 0)
    }
}
