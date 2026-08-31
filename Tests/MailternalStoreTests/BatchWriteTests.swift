import Foundation
import Testing
@testable import MailternalStore

@Test func batchedWriteHonorsRowAndByteBudgets() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let messages = (1...10).map { uid in
            makeMessage(
                generation: generation,
                uid: UInt32(uid),
                subject: "n\(uid)",
                decodedBytes: 100
            )
        }

        let byRows = try await store.upsertMessages(
            messages,
            budget: WriteBudget(maxRows: 3, maxDecodedBytes: 10_000)
        )
        #expect(byRows.committedCount == 10)
        #expect(byRows.transactionCount == 4) // 3+3+3+1
        #expect(byRows.committedDecodedBytes == 1000)
        #expect(try await store.page(in: folder, after: nil, limit: 20).rows.count == 10)

        // Replace same UIDs so we can measure a second ingest split by bytes.
        let byBytes = try await store.upsertMessages(
            messages,
            budget: WriteBudget(maxRows: 100, maxDecodedBytes: 250)
        )
        #expect(byBytes.committedCount == 10)
        #expect(byBytes.transactionCount == 5) // 2 rows × 100 bytes per tx
        #expect(byBytes.lastCommittedUID?.rawValue == 10)
    }
}

@Test func singleMessageExceedingByteBudgetStillCommits() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let result = try await store.upsertMessages(
            [makeMessage(generation: generation, uid: 1, decodedBytes: 9_999)],
            budget: WriteBudget(maxRows: 10, maxDecodedBytes: 100)
        )
        #expect(result.transactionCount == 1)
        #expect(result.committedCount == 1)
        #expect(try await store.page(in: folder, after: nil, limit: 5).rows.count == 1)
    }
}

@Test func quarantineStoresParseDefect() async throws {
    try await withStore { store, _ in
        let (_, _, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(
                generation: generation,
                uid: 8,
                subject: "bad",
                body: nil,
                isQuarantined: true,
                parseDefect: "malformed boundary"
            ),
        ])
        let id = try await store.messageID(generation: generation, uid: IMAPUID(rawValue: 8))!
        let detail = try await store.detail(id)
        #expect(detail.isQuarantined)
        #expect(detail.bodyText == nil)
        let errors = try await store.fetchErrorLog()
        #expect(errors.contains { $0.kind == .parse && $0.message == "malformed boundary" })
    }
}
