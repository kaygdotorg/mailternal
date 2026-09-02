import Foundation
import Testing
@testable import MailternalStore

actor ObservationReadyGate {
    private var isReady = false
    private var isReleased = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalReady() {
        isReady = true
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            if isReady {
                continuation.resume()
            } else {
                readyWaiters.append(continuation)
            }
        }
    }

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

actor CountCollector {
    private(set) var values: [FolderCounts] = []

    func add(_ value: FolderCounts) {
        values.append(value)
    }

    func snapshot() -> [FolderCounts] {
        values
    }
}

@Test func observationDebounceCoalescesBursts() async throws {
    let clock = ManualObservationClock()
    try await withStore(
        observationDebounce: .milliseconds(180),
        observationSleep: { duration in
            try await clock.sleep(for: duration)
        }
    ) { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "one"),
        ])

        let collector = CountCollector()
        let ready = ObservationReadyGate()
        let stream = store.observeCounts(in: folder)
        let listen = Task {
            var first = true
            for await counts in stream {
                await collector.add(counts)
                if first {
                    first = false
                    await ready.signalReady()
                    await ready.waitForRelease()
                }
            }
        }
        defer {
            listen.cancel()
            Task { await ready.release() }
        }

        let gotFirst = await waitUntil(timeout: .milliseconds(500)) {
            await collector.snapshot().count >= 1
        }
        try #require(gotFirst)
        await ready.waitUntilReady()
        #expect(await collector.snapshot().first?.total == 1)
        let baseline = await collector.snapshot().count

        var sleepCalls = await clock.sleepCallCount()
        for uid in 2...6 {
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: UInt32(uid), subject: "m\(uid)"),
            ])
            // Do not advance until this commit's observation callback has
            // reached the debouncer; otherwise a late callback can consume
            // the manual tick and schedule a second delivery.
            await clock.waitUntilSleeping(after: sleepCalls)
            sleepCalls = await clock.sleepCallCount()
        }

        #expect(await collector.snapshot().count == baseline, "burst must not deliver immediately")

        await ready.release()
        await clock.advance()
        let gotSecond = await waitUntil(timeout: .milliseconds(700)) {
            await collector.snapshot().count > baseline
        }
        #expect(gotSecond)
        let values = await collector.snapshot()
        #expect(values.count == baseline + 1)
        #expect(values.last?.total == 6)
    }
}

@Test func observationFirstDeliveryIsImmediate() async throws {
    try await withStore(observationDebounce: .milliseconds(250)) { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1),
        ])
        let stream = store.observeCounts(in: folder)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.total == 1)
        #expect(first?.unread == 1)
    }
}

private func waitUntil(timeout: Duration, _ predicate: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

private actor ManualObservationClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var nextSleepWaiters: [
        (after: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var sleepCalls = 0
    private var advancePending = false

    func sleep(for _: Duration) async throws {
        try Task.checkCancellation()
        sleepCalls += 1
        let waiters = nextSleepWaiters.filter { $0.after < sleepCalls }
        nextSleepWaiters.removeAll { $0.after < sleepCalls }
        for waiter in waiters {
            waiter.continuation.resume()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if advancePending {
                advancePending = false
                continuation.resume()
            } else {
                sleepers.append(continuation)
            }
        }
        try Task.checkCancellation()
    }

    func sleepCallCount() -> Int {
        sleepCalls
    }

    func waitUntilSleeping(after count: Int) async {
        if sleepCalls > count { return }
        await withCheckedContinuation { continuation in
            if sleepCalls > count {
                continuation.resume()
            } else {
                nextSleepWaiters.append((count, continuation))
            }
        }
    }

    func advance() {
        let waiters = sleepers
        sleepers.removeAll()
        advancePending = true
        for waiter in waiters {
            waiter.resume()
        }
    }
}
