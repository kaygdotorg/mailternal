import Foundation
import Testing
@testable import MailternalStore

@Test func keysetPagingEqualDateTies() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = (1...5).map { uid in
            makeMessage(generation: generation, uid: UInt32(uid), subject: "m\(uid)", date: date, body: "body \(uid)")
        }
        _ = try await store.upsertMessages(messages, budget: .backfill)

        let page1 = try await store.page(in: folder, after: nil, limit: 2)
        #expect(page1.rows.map(\.subject) == ["m5", "m4"])
        #expect(page1.next != nil)
        #expect(page1.next?.uid.rawValue == 4)
        #expect(page1.next?.internalDate == date)

        let page2 = try await store.page(in: folder, after: page1.next, limit: 2)
        #expect(page2.rows.map(\.subject) == ["m3", "m2"])
        #expect(page2.next?.uid.rawValue == 2)

        let page3 = try await store.page(in: folder, after: page2.next, limit: 2)
        #expect(page3.rows.map(\.subject) == ["m1"])
        #expect(page3.next == nil)

        // Cursor at uid 4 must not repeat 4 or skip 3.
        let afterFour = try await store.page(
            in: folder,
            after: MessagePageCursor(internalDate: date, uid: IMAPUID(rawValue: 4)),
            limit: 10
        )
        #expect(afterFour.rows.map(\.subject) == ["m3", "m2", "m1"])
    }
}

@Test func pageProjectionsExcludeBodies() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(
                generation: generation,
                uid: 7,
                subject: "Secret",
                body: "this body must not leak into the list preview beyond truncation"
            ),
        ])
        let page = try await store.page(in: folder, after: nil, limit: 10)
        #expect(page.rows.count == 1)
        #expect(page.rows[0].subject == "Secret")
        #expect(page.rows[0].from == "Alice")
        #expect(!page.rows[0].preview.isEmpty)

        let id = page.rows[0].id
        let detail = try await store.detail(id)
        #expect(detail.bodyText?.contains("must not leak") == true)
        #expect(detail.envelope.rfcMessageID == "<7@example.com>")
        #expect(detail.envelope.references == ["<1@example.com>"])
    }
}

@Test func mixedDatesStillUidTieBreakOnEqualDay() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "old-high", date: older),
            makeMessage(generation: generation, uid: 9, subject: "old-low-uid-wait", date: older),
            makeMessage(generation: generation, uid: 3, subject: "new", date: newer),
        ])
        // uid 9 and uid 1 share `older`; uid DESC puts 9 first among equals, but both
        // trail the newer date.
        let page = try await store.page(in: folder, after: nil, limit: 10)
        #expect(page.rows.map(\.subject) == ["new", "old-low-uid-wait", "old-high"])
    }
}
