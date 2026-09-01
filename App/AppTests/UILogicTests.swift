import XCTest

final class UILogicTests: XCTestCase {
    func testListRowTodayUsesRelativeNamedNarrowFormat() {
        let now = Date()
        let calendar = Calendar.current
        let expected = now.formatted(.relative(presentation: .named, unitsStyle: .narrow))
        XCTAssertEqual(MailDateFormat.listRow(now, now: now, calendar: calendar), expected)
    }

    func testListRowYesterdayIsLiteralYesterday() {
        let now = Date()
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(MailDateFormat.listRow(yesterday, now: now, calendar: calendar), "Yesterday")
    }

    func testListRowWithinWeekUsesWeekdayName() {
        let now = Date()
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        XCTAssertEqual(
            MailDateFormat.listRow(threeDaysAgo, now: now, calendar: calendar),
            threeDaysAgo.formatted(.dateTime.weekday(.wide))
        )
    }

    func testListRowOlderThanAWeekUsesAbsoluteDate() {
        let now = Date()
        let calendar = Calendar.current
        let older = calendar.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(
            MailDateFormat.listRow(older, now: now, calendar: calendar),
            older.formatted(.dateTime.month(.abbreviated).day().year())
        )
    }

    func testEnvelopeAndSyncedThroughFormats() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            MailDateFormat.envelope(date),
            date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
        )
        XCTAssertEqual(
            MailDateFormat.syncedThrough(date),
            date.formatted(.dateTime.month(.abbreviated).day().year())
        )
    }

    func testPrefetchWindowTriggersNearEndOfLoadedPage() {
        XCTAssertEqual(MessageListPrefetch.pageSize, 80)
        XCTAssertEqual(MessageListPrefetch.margin, 24)
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 10, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 55, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertTrue(MessageListPrefetch.shouldLoadMore(near: 56, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertTrue(MessageListPrefetch.shouldLoadMore(near: 79, loadedCount: 80, hasMore: true, isPaging: false))
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 79, loadedCount: 80, hasMore: true, isPaging: true))
        XCTAssertFalse(MessageListPrefetch.shouldLoadMore(near: 79, loadedCount: 80, hasMore: false, isPaging: false))
    }

    func testSearchNormalizesQueryAndTreatsWhitespaceAsEmpty() {
        XCTAssertNil(SearchQueryPolicy.normalizedQuery(""))
        XCTAssertNil(SearchQueryPolicy.normalizedQuery("   \t"))
        XCTAssertEqual(SearchQueryPolicy.normalizedQuery("  Lunch  "), "Lunch")
        XCTAssertEqual(SearchQueryPolicy.debounce, .milliseconds(120))
    }

    func testSearchDebounceCancelsSupersededQueries() async {
        actor Collector {
            var values: [String] = []
            func add(_ value: String) { values.append(value) }
            func snapshot() -> [String] { values }
        }
        let collector = Collector()
        var task: Task<Void, Never>?
        func schedule(_ text: String) {
            task?.cancel()
            guard let query = SearchQueryPolicy.normalizedQuery(text) else { return }
            task = Task {
                try? await Task.sleep(for: SearchQueryPolicy.debounce)
                guard !Task.isCancelled else { return }
                await collector.add(query)
            }
        }
        schedule("L")
        schedule("   ")
        schedule("Lu")
        schedule("Lunch")
        await task?.value
        let values = await collector.snapshot()
        XCTAssertEqual(values, ["Lunch"])
    }

    func testFindRangesAreCaseInsensitiveAndNonOverlapping() {
        let text = "Aaa aa A"
        let ranges = MessageFind.ranges(in: text, query: "aa")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(String(text[ranges[0]]), "Aa")
        XCTAssertEqual(String(text[ranges[1]]), "aa")
        XCTAssertTrue(MessageFind.ranges(in: text, query: "").isEmpty)
        XCTAssertTrue(MessageFind.ranges(in: "hello", query: "z").isEmpty)
    }

    func testFindAdvanceWrapsForwardAndBackward() {
        XCTAssertEqual(MessageFind.advance(index: 0, count: 3, step: .next), 1)
        XCTAssertEqual(MessageFind.advance(index: 1, count: 3, step: .next), 2)
        XCTAssertEqual(MessageFind.advance(index: 2, count: 3, step: .next), 0)
        XCTAssertEqual(MessageFind.advance(index: 0, count: 3, step: .previous), 2)
        XCTAssertEqual(MessageFind.advance(index: 2, count: 3, step: .previous), 1)
        XCTAssertEqual(MessageFind.advance(index: 0, count: 1, step: .next), 0)
        XCTAssertEqual(MessageFind.advance(index: 0, count: 1, step: .previous), 0)
    }

    func testFindAdvanceNilIndexStartsAtEndForPrevious() {
        XCTAssertEqual(MessageFind.advance(index: nil, count: 4, step: .next), 0)
        XCTAssertEqual(MessageFind.advance(index: nil, count: 4, step: .previous), 3)
        XCTAssertNil(MessageFind.advance(index: 0, count: 0, step: .next))
        XCTAssertNil(MessageFind.advance(index: nil, count: 0, step: .previous))
    }

    func testFindRestartAndClampAndSelectedMatchNumber() {
        XCTAssertEqual(MessageFind.restartIndex(count: 5), 0)
        XCTAssertNil(MessageFind.restartIndex(count: 0))
        XCTAssertEqual(MessageFind.clamp(4, count: 2), 1)
        XCTAssertEqual(MessageFind.clamp(-1, count: 2), 0)
        XCTAssertNil(MessageFind.clamp(0, count: 0))

        let text = "one two one"
        let snapshot = MessageFind.make(text: text, query: "one", index: 7)
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.selectedMatchNumber, 2)
        XCTAssertEqual(snapshot.selectedRange.map { String(text[$0]) }, "one")

        let empty = MessageFind.make(text: text, query: "zzz", index: 0)
        XCTAssertEqual(empty.count, 0)
        XCTAssertNil(empty.index)
        XCTAssertNil(empty.selectedMatchNumber)
    }

    func testFindHaystackPrefersRawThenBodyThenStrippedHTML() {
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: "plain",
                html: "<p>html</p>",
                raw: "RAW",
                showingRaw: true
            ),
            "RAW"
        )
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: "plain",
                html: "<p>html</p>",
                raw: "RAW",
                showingRaw: false
            ),
            "plain"
        )
        XCTAssertEqual(
            MessageFind.haystack(
                bodyText: nil,
                html: "<p>Hello <b>world</b></p>",
                raw: nil,
                showingRaw: false
            ),
            "Hello world"
        )
        XCTAssertEqual(MessageFind.visibleText(fromHTML: "<div>A</div><div>B</div>"), "AB")
    }
}
