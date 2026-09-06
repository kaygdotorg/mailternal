import Foundation
import Testing
@testable import MailternalStore

@Test func detailsPreservesInputOrderDeduplicatesAndOmitsMissingRows() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let fullBody = String(repeating: "first body ", count: 200)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "first", body: fullBody),
            makeMessage(generation: generation, uid: 2, subject: "second", body: "second body"),
        ])

        let rows = try await store.page(in: folder, after: nil, limit: 10, sort: .newest)
        let newest = try #require(rows.rows.first { $0.subject == "second" })
        let oldest = try #require(rows.rows.first { $0.subject == "first" })
        let missing = MessageID(rawValue: 999_999)

        let actual = try await store.details([oldest.id, missing, newest.id, oldest.id, missing])
        #expect(actual.map(\.id) == [oldest.id, newest.id])

        #expect(actual.map(\.envelope.subject) == ["first", "second"])
        #expect(actual.map(\.bodyText) == [fullBody, "second body"])
    }
}
