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

        let page1 = try await store.page(in: folder, after: nil, limit: 2, sort: .newest)
        #expect(page1.rows.map(\.subject) == ["m5", "m4"])
        #expect(page1.next != nil)
        #expect(page1.next?.uid.rawValue == 4)
        #expect(page1.next?.value == MessagePageCursorValue.date(date))

        let page2 = try await store.page(in: folder, after: page1.next, limit: 2, sort: .newest)
        #expect(page2.rows.map(\.subject) == ["m3", "m2"])
        #expect(page2.next?.uid.rawValue == 2)

        let page3 = try await store.page(in: folder, after: page2.next, limit: 2, sort: .newest)
        #expect(page3.rows.map(\.subject) == ["m1"])
        #expect(page3.next == nil)

        // Cursor at uid 4 must not repeat 4 or skip 3.
        let afterFour = try await store.page(
            in: folder,
            after: MessagePageCursor(
                sort: .newest,
                value: .date(date),
                uid: IMAPUID(rawValue: 4)
            ),
            limit: 10,
            sort: .newest
        )
        #expect(afterFour.rows.map(\.subject) == ["m3", "m2", "m1"])
    }
}

@Test func pageQueryPlanUsesKeysetIndexNotTableScan() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for origin in stride(from: 1, through: 2_400, by: 400) {
            let chunk = (origin..<origin + 400).map { uid in
                makeMessage(
                    generation: generation,
                    uid: UInt32(uid),
                    subject: "m\(uid)",
                    date: base.addingTimeInterval(Double(uid)),
                    body: "body \(uid)"
                )
            }
            _ = try await store.upsertMessages(chunk)
        }

        func assertKeyset(_ plan: String) {
            let upper = plan.uppercased()
            #expect(plan.contains("messages_page_idx"), "\(plan)")
            #expect(!upper.contains("USE TEMP B-TREE FOR ORDER BY"), "\(plan)")
            let scannedWithoutIndex = upper.split(separator: "\n").contains { line in
                line.contains("SCAN") && line.contains("MESSAGES") && !line.contains("USING INDEX")
            }
            #expect(!scannedWithoutIndex, "\(plan)")
        }

        let first = try await store.explainPageQueryPlan(
            in: folder,
            after: nil,
            limit: 80,
            sort: .newest
        )
        assertKeyset(first)
        let page = try await store.page(in: folder, after: nil, limit: 80, sort: .newest)
        let next = try await store.explainPageQueryPlan(
            in: folder,
            after: page.next,
            limit: 80,
            sort: .newest
        )
        assertKeyset(next)
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
        let page = try await store.page(in: folder, after: nil, limit: 10, sort: .newest)
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
        let page = try await store.page(in: folder, after: nil, limit: 10, sort: .newest)
        #expect(page.rows.map(\.subject) == ["new", "old-low-uid-wait", "old-high"])
    }
}

@Test func configurableSortsUseStableKeysetsAndMatchIDEnumeration() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        var alpha = makeMessage(
            generation: generation,
            uid: 2,
            subject: "alpha",
            fromName: "Alpha",
            date: sameDate,
            isRead: true,
            isFlagged: true
        )
        alpha.attachments = [
            AttachmentInfo(
                id: "1",
                filename: "one.txt",
                mimeType: "text/plain",
                sizeEstimate: 1,
                contentID: nil
            )
        ]
        var zuluWithAttachment = makeMessage(
            generation: generation,
            uid: 4,
            subject: "",
            fromName: "Zulu",
            date: sameDate,
            isRead: true
        )
        zuluWithAttachment.attachments = [
            AttachmentInfo(
                id: "1",
                filename: "two.txt",
                mimeType: "text/plain",
                sizeEstimate: 1,
                contentID: nil
            )
        ]
        _ = try await store.upsertMessages([
            makeMessage(
                generation: generation,
                uid: 1,
                subject: "beta",
                fromName: "Zulu",
                date: sameDate
            ),
            alpha,
            makeMessage(
                generation: generation,
                uid: 3,
                subject: "alpha",
                fromName: "Alpha",
                date: sameDate,
                isFlagged: true
            ),
            zuluWithAttachment,
        ])

        let cases: [(MailListSort, [String])] = [
            (MailListSort(field: .date, direction: .ascending), ["beta", "alpha", "alpha", ""]),
            (.newest, ["", "alpha", "alpha", "beta"]),
            (MailListSort(field: .sender, direction: .ascending), ["alpha", "alpha", "beta", ""]),
            (MailListSort(field: .sender, direction: .descending), ["", "beta", "alpha", "alpha"]),
            (MailListSort(field: .subject, direction: .ascending), ["", "alpha", "alpha", "beta"]),
            (MailListSort(field: .subject, direction: .descending), ["beta", "alpha", "alpha", ""]),
            (MailListSort(field: .read, direction: .ascending), ["beta", "alpha", "alpha", ""]),
            (MailListSort(field: .read, direction: .descending), ["", "alpha", "alpha", "beta"]),
            (MailListSort(field: .flagged, direction: .ascending), ["beta", "", "alpha", "alpha"]),
            (MailListSort(field: .flagged, direction: .descending), ["alpha", "alpha", "", "beta"]),
            (MailListSort(field: .attachments, direction: .ascending), ["beta", "alpha", "alpha", ""]),
            (MailListSort(field: .attachments, direction: .descending), ["", "alpha", "alpha", "beta"]),
        ]

        for (sort, expectedSubjects) in cases {
            let ids = try await store.messageIDs(in: folder, sort: sort)
            var cursor: MessagePageCursor?
            var pagedIDs: [MessageID] = []
            var pagedSubjects: [String] = []
            repeat {
                let page = try await store.page(
                    in: folder,
                    after: cursor,
                    limit: 2,
                    sort: sort
                )
                pagedIDs += page.rows.map(\.id)
                pagedSubjects += page.rows.map(\.subject)
                if let next = page.next {
                    #expect(next.sort == sort)
                }
                cursor = page.next
            } while cursor != nil
            #expect(pagedIDs == ids)
            #expect(pagedSubjects == expectedSubjects)
        }

        let senderPage = try await store.page(
            in: folder,
            after: nil,
            limit: 2,
            sort: MailListSort(field: .sender, direction: .ascending)
        )
        await #expect(throws: MailStoreError.invalidPageCursor) {
            _ = try await store.page(
                in: folder,
                after: senderPage.next,
                limit: 2,
                sort: MailListSort(field: .subject, direction: .ascending)
            )
        }
    }
}

@Test func observedPageKeepsRequestedSortOrder() async throws {
    try await withStore(observationDebounce: .milliseconds(0)) { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "zulu"),
            makeMessage(generation: generation, uid: 2, subject: "alpha"),
        ])
        let sort = MailListSort(field: .subject, direction: .ascending)
        var iterator = store.observePage(
            in: folder,
            after: nil,
            limit: 10,
            sort: sort
        ).makeAsyncIterator()
        let page = await iterator.next()
        #expect(page?.rows.map(\.subject) == ["alpha", "zulu"])
    }
}
