import Foundation
import Testing
@testable import MailternalStore

@Test func ftsUpdateDeleteAndGenerationCleanupHaveNoGhostHits() async throws {
    try await withStore { store, _ in
        let (_, folder, live) = try await seedInbox(store, uidValidity: 1)

        _ = try await store.upsertMessages([
            makeMessage(
                generation: live,
                uid: 10,
                subject: "alpha subject",
                body: "uniquealpha token in the body"
            ),
        ])

        var hits = try await store.search("uniquealpha", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].preview.contains("uniquealpha") || hits[0].subject.contains("alpha"))
        #expect(try await store.ftsUnfilteredCount(matching: "uniquealpha") == 1)

        // Update replaces the unique token.
        _ = try await store.upsertMessages([
            makeMessage(
                generation: live,
                uid: 10,
                subject: "beta subject",
                body: "uniquebeta token in the body"
            ),
        ])
        hits = try await store.search("uniquealpha", limit: 10)
        #expect(hits.isEmpty)
        #expect(try await store.ftsUnfilteredCount(matching: "uniquealpha") == 0)
        hits = try await store.search("uniquebeta", limit: 10)
        #expect(hits.count == 1)
        #expect(hits[0].preview.contains("uniquebeta") || hits[0].subject.contains("beta"))

        // Delete the live row.
        _ = try await store.deleteUIDs(generation: live, uids: [IMAPUID(rawValue: 10)])
        #expect(try await store.search("uniquebeta", limit: 10).isEmpty)
        #expect(try await store.ftsUnfilteredCount(matching: "uniquebeta") == 0)

        // Replacement generation: old snapshot stays searchable until switch;
        // after cleanup, FTS has no ghosts even unfiltered.
        _ = try await store.upsertMessages([
            makeMessage(generation: live, uid: 11, subject: "keep-old", body: "oldghosttoken body"),
        ])
        let replacement = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 2,
            baselineUID: IMAPUID(rawValue: 50)
        )
        _ = try await store.upsertMessages([
            makeMessage(generation: replacement, uid: 1, subject: "new-only", body: "newghosttoken body"),
        ])

        #expect(try await store.search("oldghosttoken", limit: 10).count == 1)
        #expect(try await store.search("newghosttoken", limit: 10).isEmpty)

        try await store.activateReplacementGeneration(folder: folder)
        #expect(try await store.search("oldghosttoken", limit: 10).isEmpty)
        #expect(try await store.search("newghosttoken", limit: 10).count == 1)
        // Retiring rows still occupy FTS until cleanup.
        #expect(try await store.ftsUnfilteredCount(matching: "oldghosttoken") == 1)

        var deleted = 0
        repeat {
            let n = try await store.cleanupRetiredGenerations(batchSize: 1)
            deleted += n
            if n == 0 { break }
        } while true
        #expect(deleted >= 1)
        #expect(try await store.ftsUnfilteredCount(matching: "oldghosttoken") == 0)
        #expect(try await store.search("oldghosttoken", limit: 10).isEmpty)
        #expect(try await store.search("newghosttoken", limit: 10).count == 1)

        let integrity = try await store.checkFTSIntegrity()
        #expect(integrity == .ok)
    }
}

@Test func searchEmptyQueryReturnsNothing() async throws {
    try await withStore { store, _ in
        let (_, _, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([makeMessage(generation: generation, uid: 1)])
        #expect(try await store.search("", limit: 10).isEmpty)
        #expect(try await store.search("   ", limit: 10).isEmpty)
    }
}

@Test func searchQueryPlanUsesFTSIndex() async throws {
    try await withStore { store, _ in
        let (_, _, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "alpha", body: "needle token"),
        ])
        let plan = try await store.explainSearchQueryPlan("needle", limit: 10)
        let upper = plan.uppercased()
        #expect(upper.contains("MESSAGES_FTS"), "\(plan)")
        let scannedMessages = upper.split(separator: "\n").contains { line in
            line.contains("SCAN MESSAGES") && !line.contains("FTS") && !line.contains("USING INDEX") && !line.contains("VIRTUAL")
        }
        #expect(!scannedMessages, "\(plan)")
    }
}
