import Foundation
import Testing
@testable import MailternalStore

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
    try await withStore(observationDebounce: .milliseconds(180)) { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "one"),
        ])

        let collector = CountCollector()
        let stream = store.observeCounts(in: folder)
        let listen = Task {
            for await counts in stream {
                await collector.add(counts)
            }
        }
        defer { listen.cancel() }

        let gotFirst = await waitUntil(timeout: .milliseconds(500)) {
            await collector.snapshot().count >= 1
        }
        #expect(gotFirst)
        #expect(await collector.snapshot().first?.total == 1)
        let baseline = await collector.snapshot().count

        for uid in 2...6 {
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: UInt32(uid), subject: "m\(uid)"),
            ])
        }

        try await Task.sleep(for: .milliseconds(40))
        #expect(await collector.snapshot().count == baseline, "burst must not deliver immediately")

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
