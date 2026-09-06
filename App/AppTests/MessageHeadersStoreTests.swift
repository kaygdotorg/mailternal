import XCTest
import MailternalInterfaces

@MainActor
final class MessageHeadersStoreTests: XCTestCase {
    func testCachedRawSourceProducesHeadersWithoutAnotherFetch() {
        let store = MessageHeadersStore { _ in
            XCTFail("cached source must not issue a raw-message request")
            return ""
        }
        let id = MessageID(rawValue: 1)
        store.loadIfNeeded(for: id, cachedSource: "X-Revision: cached\r\n\r\nprivate body")
        guard case .loaded(_, let text) = store.state(for: id) else {
            return XCTFail("cached headers should be available synchronously")
        }
        XCTAssertTrue(text.contains("X-Revision: cached"))
        XCTAssertFalse(text.contains("private body"))
    }

    func testLateCancelledFetchCannotOverwriteCachedHeaders() async {
        let started = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        var continuation: CheckedContinuation<String, Never>?
        let store = MessageHeadersStore { _ in
            let source = await withCheckedContinuation { pending in
                continuation = pending
                started.continuation.yield(())
            }
            finished.continuation.yield(())
            return source
        }
        let id = MessageID(rawValue: 2)
        store.loadIfNeeded(for: id)
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()

        store.loadIfNeeded(for: id, cachedSource: "X-Revision: current\r\n\r\nbody")
        continuation?.resume(returning: "X-Revision: obsolete\r\n\r\nold body")
        var completions = finished.stream.makeAsyncIterator()
        _ = await completions.next()

        guard case .loaded(_, let text) = store.state(for: id) else {
            return XCTFail("cancellation must preserve the current cached headers")
        }
        XCTAssertTrue(text.contains("X-Revision: current"))
        XCTAssertFalse(text.contains("obsolete"))
    }

    func testFailedDemandWaitsForExplicitRetry() async {
        struct FetchFailure: Error {}
        let finished = AsyncStream<Void>.makeStream()
        var attempts = 0
        let store = MessageHeadersStore { _ in
            attempts += 1
            defer { finished.continuation.yield(()) }
            if attempts == 1 { throw FetchFailure() }
            return "X-Revision: retried\r\n\r\nbody"
        }
        let id = MessageID(rawValue: 3)
        var completions = finished.stream.makeAsyncIterator()
        store.loadIfNeeded(for: id)
        _ = await completions.next()
        guard case .failed = store.state(for: id) else {
            return XCTFail("a real failure must remain visible")
        }

        store.loadIfNeeded(for: id)
        XCTAssertEqual(attempts, 1)
        store.retry(id)
        _ = await completions.next()
        guard case .loaded(_, let text) = store.state(for: id) else {
            return XCTFail("explicit retry should recover header loading")
        }
        XCTAssertTrue(text.contains("X-Revision: retried"))
    }
}
