import Foundation
import Testing
@testable import MailternalStore

@Test func generationSwitchIsAtomicAndKeepsOldReadableUntilThen() async throws {
    try await withStore { store, _ in
        let (_, folder, live) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([
            makeMessage(generation: live, uid: 5, subject: "old-live", body: "old body"),
        ])

        let replacement = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 99,
            baselineUID: IMAPUID(rawValue: 20)
        )
        _ = try await store.upsertMessages([
            makeMessage(generation: replacement, uid: 1, subject: "new-live", body: "new body"),
        ])

        #expect(try await store.generationState(live) == .live)
        #expect(try await store.generationState(replacement) == .replacement)

        let before = try await store.page(in: folder, after: nil, limit: 10)
        #expect(before.rows.map(\.subject) == ["old-live"])
        let liveIDBefore = try await store.liveGenerationID(for: folder)

        try await store.activateReplacementGeneration(folder: folder)

        #expect(try await store.generationState(live) == .retiring)
        #expect(try await store.generationState(replacement) == .live)
        let liveIDAfter = try await store.liveGenerationID(for: folder)
        #expect(liveIDBefore != liveIDAfter)

        let after = try await store.page(in: folder, after: nil, limit: 10)
        #expect(after.rows.map(\.subject) == ["new-live"])
        #expect(after.rows.count == 1)

        let summary = try await store.fetchFolderSummary(folder)
        #expect(summary?.totalCount == 1)
        #expect(summary?.unreadCount == 1)

        let counts = store.observeCounts(in: folder)
        var iterator = counts.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.total == 1)
        #expect(first?.unread == 1)
    }
}

@Test func openLiveGenerationRejectsUidValidityChange() async throws {
    try await withStore { store, _ in
        let (_, folder, _) = try await seedInbox(store, uidValidity: 1)
        await #expect(throws: MailStoreError.uidValidityMismatch) {
            _ = try await store.openLiveGeneration(folder: folder, uidValidity: 2, baselineUID: nil)
        }
    }
}

@Test func syncStateRoundTrips() async throws {
    try await withStore { store, _ in
        let (_, _, generation) = try await seedInbox(store)
        var state = try await store.fetchSyncState(for: generation)
        #expect(state?.deltaPath == .basic)
        #expect(state?.baselineUID?.rawValue == 1000)

        try await store.saveSyncState(FolderSyncState(
            generation: generation,
            deltaPath: .condstore,
            highestModseq: 42,
            backfillPhase: .walking,
            lowWaterUID: IMAPUID(rawValue: 80),
            baselineUID: IMAPUID(rawValue: 1000),
            progress: 0.25,
            haltedThrough: nil
        ))
        state = try await store.fetchSyncState(for: generation)
        #expect(state?.deltaPath == .condstore)
        #expect(state?.highestModseq == 42)
        #expect(state?.backfillPhase == .walking)
        #expect(state?.lowWaterUID?.rawValue == 80)
        #expect(state?.progress == 0.25)
    }
}

@Test func syncStateCursorAndModseqDoNotRegressAfterConcurrentWriters() async throws {
    try await withStore { store, _ in
        let (_, _, generation) = try await seedInbox(store)
        try await store.saveSyncState(FolderSyncState(
            generation: generation,
            highestModseq: 90,
            backfillPhase: .walking,
            lowWaterUID: IMAPUID(rawValue: 80),
            baselineUID: IMAPUID(rawValue: 1000),
            progress: 0.25
        ))
        try await store.saveSyncState(FolderSyncState(
            generation: generation,
            highestModseq: 40,
            backfillPhase: .walking,
            lowWaterUID: IMAPUID(rawValue: 90),
            baselineUID: nil,
            progress: 0.10
        ))

        let state = try #require(await store.fetchSyncState(for: generation))
        #expect(state.highestModseq == 90)
        #expect(state.lowWaterUID?.rawValue == 80)
        #expect(state.baselineUID?.rawValue == 1000)
        #expect(state.progress == 0.25)
        
        try await store.saveSyncState(FolderSyncState(
            generation: generation,
            backfillPhase: .complete,
            lowWaterUID: IMAPUID(rawValue: 80),
            progress: 1
        ))
        try await store.saveSyncState(FolderSyncState(
            generation: generation,
            backfillPhase: .walking,
            lowWaterUID: nil,
            progress: 0
        ))
        let reset = try #require(await store.fetchSyncState(for: generation))
        #expect(reset.lowWaterUID == nil)
        #expect(reset.progress == 0)
    }
}
