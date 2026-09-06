import XCTest
import MailternalInterfaces

@MainActor
final class MessageDetailLoaderTests: XCTestCase {
    private actor ReleaseGate {
        private var released = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            released = true
            for continuation in continuations { continuation.resume() }
            continuations.removeAll()
        }
    }

    private func detail(_ id: MessageID, body: String = "body") -> MessageDetail {
        let address = MailAddress(displayName: nil, address: "sender@example.test")
        let envelope = Envelope(
            subject: "Subject \(id.rawValue)",
            from: [address],
            to: [address],
            cc: [],
            replyTo: [],
            internalDate: Date(timeIntervalSince1970: 0),
            headerDate: nil,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: []
        )
        return MessageDetail(
            id: id,
            envelope: envelope,
            bodyText: body,
            sanitizedHTML: nil,
            attachments: [],
            isQuarantined: false
        )
    }

    func testRepeatedInteractiveLoadsShareOneInFlightFetch() async throws {
        let id = MessageID(rawValue: 1)
        let gate = ReleaseGate()
        let started = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        var fetchCount = 0
        let loader = MessageDetailLoader(
            fetch: { [self] requestedID in
                fetchCount += 1
                started.continuation.yield(())
                await gate.wait()
                return self.detail(requestedID)
            },
            fetchBatch: { [self] requestedIDs in
                requestedIDs.map { self.detail($0) }
            }
        )
        let first = Task { @MainActor in try await loader.load(id) }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let second = Task { @MainActor in
            secondStarted.continuation.yield(())
            return try await loader.load(id)
        }
        var secondStarts = secondStarted.stream.makeAsyncIterator()
        _ = await secondStarts.next()

        await gate.release()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNotNil(loader.cachedDetail(for: id))
    }

    func testInvalidationCancelsGenerationAndRejectsLateCompletion() async {
        let id = MessageID(rawValue: 2)
        let gate = ReleaseGate()
        let started = AsyncStream<Void>.makeStream()
        let loader = MessageDetailLoader(
            fetch: { [self] requestedID in
                started.continuation.yield(())
                await gate.wait()
                return self.detail(requestedID, body: "old")
            },
            fetchBatch: { [self] requestedIDs in
                requestedIDs.map { self.detail($0, body: "old") }
            }
        )
        let request = Task { @MainActor in try await loader.load(id) }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        loader.invalidate(id)
        await gate.release()

        do {
            _ = try await request.value
            XCTFail("invalidated detail must not publish")
        } catch is CancellationError {
            // Expected stale-generation rejection.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(loader.cachedDetail(for: id))
    }

    func testAdjacentPrefetchUsesOneBoundedBatchAndJoinsInteractiveLoad() async throws {
        let ids = (1...MessageDetailLoader.speculativeBatchCapacity).map {
            MessageID(rawValue: Int64($0))
        }
        let gate = ReleaseGate()
        let started = AsyncStream<Void>.makeStream()
        var batchRequests: [[MessageID]] = []
        var singleFetchCount = 0
        let loader = MessageDetailLoader(
            fetch: { [self] id in
                singleFetchCount += 1
                return self.detail(id, body: "single")
            },
            fetchBatch: { [self] requestedIDs in
                batchRequests.append(requestedIDs)
                started.continuation.yield(())
                await gate.wait()
                return requestedIDs.map { self.detail($0, body: "batch") }
            }
        )

        loader.prefetch(ids)
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        let selected = Task { @MainActor in try await loader.load(ids[0]) }

        // ReleaseGate also handles this release arriving before the batch
        // reaches its wait, so this test does not depend on Task.yield().
        await gate.release()
        let loaded = try await selected.value

        XCTAssertEqual(loaded.id, ids[0])
        XCTAssertEqual(batchRequests, [ids])
        XCTAssertEqual(singleFetchCount, 0)
        XCTAssertEqual(
            ids.filter { loader.cachedDetail(for: $0) != nil }.count,
            ids.count
        )
    }

    func testFailedNeighborPrefetchDoesNotDiscardInteractiveSelection() async throws {
        let selectedID = MessageID(rawValue: 40)
        let malformedNeighbor = MessageID(rawValue: 41)
        let gate = ReleaseGate()
        let batchStarted = AsyncStream<Void>.makeStream()
        let selectionStarted = AsyncStream<Void>.makeStream()
        let loader = MessageDetailLoader(
            fetch: { [self] id in detail(id) },
            fetchBatch: { _ in
                batchStarted.continuation.yield(())
                await gate.wait()
                throw MessageDetailLoaderError.missing(malformedNeighbor)
            }
        )
        loader.prefetch([selectedID, malformedNeighbor])
        var batches = batchStarted.stream.makeAsyncIterator()
        _ = await batches.next()
        let selection = Task { @MainActor in
            selectionStarted.continuation.yield(())
            return try await loader.load(selectedID)
        }
        var selections = selectionStarted.stream.makeAsyncIterator()
        _ = await selections.next()
        await gate.release()

        let loaded = try await selection.value
        XCTAssertEqual(loaded.id, selectedID)
    }

    func testBatchPublishesAllResultsBeforeStartingNextBatch() async throws {
        let ids = (1...(MessageDetailLoader.speculativeBatchCapacity * 2)).map {
            MessageID(rawValue: Int64($0))
        }
        let firstGate = ReleaseGate()
        let secondGate = ReleaseGate()
        let firstStarted = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        var batchRequests: [[MessageID]] = []
        var singleFetchCount = 0
        let loader = MessageDetailLoader(
            fetch: { [self] id in
                singleFetchCount += 1
                return self.detail(id, body: "single")
            },
            fetchBatch: { [self] requestedIDs in
                batchRequests.append(requestedIDs)
                switch batchRequests.count {
                case 1:
                    firstStarted.continuation.yield(())
                    await firstGate.wait()
                case 2:
                    secondStarted.continuation.yield(())
                    await secondGate.wait()
                default:
                    XCTFail("prefetch must keep one batch in flight")
                }
                return requestedIDs.map { self.detail($0, body: "batch") }
            }
        )

        loader.prefetch(ids)
        var firstStarts = firstStarted.stream.makeAsyncIterator()
        _ = await firstStarts.next()
        await firstGate.release()
        var secondStarts = secondStarted.stream.makeAsyncIterator()
        _ = await secondStarts.next()

        XCTAssertEqual(batchRequests, [Array(ids.prefix(12)), Array(ids.suffix(12))])
        XCTAssertEqual(
            ids.prefix(12).filter { loader.cachedDetail(for: $0) != nil }.count,
            12
        )
        XCTAssertEqual(singleFetchCount, 0)

        await secondGate.release()
        _ = try await loader.load(ids[ids.count - 1])
    }


    func testBatchInvalidationDropsStaleIDButRetainsValidNeighbor() async throws {
        let staleID = MessageID(rawValue: 20)
        let neighborID = MessageID(rawValue: 21)
        let gate = ReleaseGate()
        let started = AsyncStream<Void>.makeStream()
        var batchRequests: [[MessageID]] = []
        var singleFetchCount = 0
        let loader = MessageDetailLoader(
            fetch: { [self] id in
                singleFetchCount += 1
                return self.detail(id, body: "single")
            },
            fetchBatch: { [self] requestedIDs in
                batchRequests.append(requestedIDs)
                started.continuation.yield(())
                await gate.wait()
                return requestedIDs
                    .filter { $0 != staleID }
                    .map { self.detail($0, body: "fresh") }
            }
        )

        loader.prefetch([staleID, neighborID])
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        loader.invalidate(staleID)
        await gate.release()

        // Joining (or observing the completed cache hit) makes completion
        // deterministic without relying on a scheduler yield.
        _ = try await loader.load(neighborID)
        XCTAssertEqual(batchRequests, [[staleID, neighborID]])
        XCTAssertEqual(singleFetchCount, 0)
        XCTAssertNil(loader.cachedDetail(for: staleID))
        XCTAssertEqual(loader.cachedDetail(for: neighborID)?.bodyText, "fresh")
    }

    func testCanceledPrefetchIsNotJoinedByLaterInteractiveLoad() async throws {
        let id = MessageID(rawValue: 30)
        let gate = ReleaseGate()
        let batchStarted = AsyncStream<Void>.makeStream()
        let singleStarted = AsyncStream<Void>.makeStream()
        var batchCount = 0
        var singleFetchCount = 0
        let loader = MessageDetailLoader(
            fetch: { [self] requestedID in
                singleFetchCount += 1
                singleStarted.continuation.yield(())
                return self.detail(requestedID, body: "single")
            },
            fetchBatch: { [self] requestedIDs in
                batchCount += 1
                batchStarted.continuation.yield(())
                await gate.wait()
                return requestedIDs.map { self.detail($0, body: "stale") }
            }
        )

        loader.prefetch([id])
        var batchStarts = batchStarted.stream.makeAsyncIterator()
        _ = await batchStarts.next()
        loader.cancelPrefetch()

        let request = Task { @MainActor in try await loader.load(id) }
        var singleStarts = singleStarted.stream.makeAsyncIterator()
        _ = await singleStarts.next()
        let loaded = try await request.value

        XCTAssertEqual(loaded.bodyText, "single")
        XCTAssertEqual(batchCount, 1)
        XCTAssertEqual(singleFetchCount, 1)
        await gate.release()
    }

    func testReplenishingPrefetchDoesNotEvictAnUpcomingCachedMessage() async throws {
        let loader = MessageDetailLoader(
            fetch: { [self] id in detail(id) },
            fetchBatch: { [self] ids in ids.map { detail($0) } }
        )
        let oldest = MessageID(rawValue: 1)
        for value in 1...MessageDetailLoader.navigationCapacity {
            _ = try await loader.load(MessageID(rawValue: Int64(value)))
        }
        let next = MessageID(rawValue: Int64(MessageDetailLoader.navigationCapacity + 1))
        let farther = MessageID(rawValue: next.rawValue + 1)

        loader.prefetch([oldest, next, farther])
        _ = try await loader.load(next)

        XCTAssertEqual(loader.cachedDetail(for: oldest)?.id, oldest)
        XCTAssertEqual(loader.cachedDetail(for: farther)?.id, farther)
    }

    func testProtectedEntriesSurviveNavigationCountAndByteBudgets() async throws {
        let protectedID = MessageID(rawValue: 0)
        let body = String(repeating: "x", count: 1_000_000)
        let loader = MessageDetailLoader(
            fetch: { [self] id in
                detail(id, body: body)
            },
            fetchBatch: { [self] ids in
                ids.map { self.detail($0, body: body) }
            }
        )
        loader.setProtectedMessageIDs([protectedID])
        _ = try await loader.load(protectedID)

        let navigationIDs = (1...(MessageDetailLoader.navigationCapacity + 4)).map {
            MessageID(rawValue: Int64($0))
        }
        for id in navigationIDs {
            _ = try await loader.load(id)
        }

        XCTAssertNotNil(loader.cachedDetail(for: protectedID))
        let retainedNavigation = navigationIDs.filter { loader.cachedDetail(for: $0) != nil }
        XCTAssertLessThanOrEqual(retainedNavigation.count, MessageDetailLoader.navigationCapacity)
        let retainedBytes = retainedNavigation.reduce(0) { total, _ in total + body.utf8.count }
        XCTAssertLessThanOrEqual(retainedBytes, MessageDetailLoader.navigationByteBudget)
    }
}
