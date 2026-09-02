#if os(macOS)
import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

private enum QAChaos {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" }
    static var mutate: Bool { ProcessInfo.processInfo.environment["MAILTERNAL_QA_CHAOS"] == "1" }

    static let user = "qa@mailternal.test"
    static let password = "qa-password"
    static let host = "127.0.0.1"

    static func installTrust() throws {
        let env = ProcessInfo.processInfo.environment["MAILTERNAL_QA_CERT"]
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa/certs/dovecot.crt")
        let url = env.map(URL.init(fileURLWithPath:)) ?? home
        let pem = try Data(contentsOf: url)
        IMAPSession.installAdditionalTrustRoots(pem: [pem])
    }

    static func config(port: Int) -> AccountConfig {
        AccountConfig(
            id: AccountID(rawValue: "qa-chaos-\(port)"),
            accountLinkID: AccountLinkID(
                uuidString: "00000000-0000-4000-8000-000000000020"
            )!,
            displayName: "QA Chaos",
            emailAddress: user,
            username: user,
            imap: IMAPEndpoint(host: host, port: port, security: .startTLS)
        )
    }

    static func engine(
        store: MailStore,
        port: Int,
        dir: URL,
        allowEnableQResync: Bool = true
    ) -> SyncEngine {
        var settings = chaosSettings(dir: dir, window: SyncPolicy.defaultWindowSize, allowEnableQResync: allowEnableQResync)
        settings.seenPoll = .seconds(1)
        settings.periodicTick = .seconds(5)
        settings.cleanupTick = .seconds(5)
        return SyncEngine(
            store: store,
            config: config(port: port),
            credentials: StaticPassword(value: password),
            clientFactory: LiveIMAPClientFactory(),
            disk: FixedDisk(
                freeBytes: 200 * 1024 * 1024 * 1024,
                volumeBytes: 500 * 1024 * 1024 * 1024
            ),
            clock: { Date() },
            settings: settings
        )
    }

    static func probe(port: Int) async throws {
        let session = IMAPSession(
            endpoint: IMAPEndpoint(host: host, port: port, security: .startTLS),
            username: user,
            password: password
        )
        try await session.connect()
        await session.close()
    }

    @discardableResult
    static func chaos(_ args: String...) throws -> String {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa/chaos.sh")
        let process = Process()
        process.executableURL = script
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["QA_REMOTE": "1"]
        ) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        print("MAILTERNAL_QA chaos \(args.joined(separator: " "))\n\(text)")
        if process.terminationStatus != 0 {
            throw ChaosCommandError(status: process.terminationStatus, output: text)
        }
        return text
    }
    static func uidSet(_ output: String, marker: String) throws -> Set<UInt32> {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: {
            $0.contains(marker)
        }),
        let token = line.split(whereSeparator: \.isWhitespace).first(where: {
            $0.hasPrefix("uids=")
        })
        else {
            throw WaitTimeout()
        }
        let value = token.dropFirst("uids=".count)
        guard value != "unavailable", !value.isEmpty else { throw WaitTimeout() }
        var result = Set<UInt32>()
        for piece in value.split(separator: ",") {
            let bounds = piece.split(separator: ":", maxSplits: 1).compactMap { UInt32($0) }
            guard bounds.count == 1 || bounds.count == 2 else { throw WaitTimeout() }
            let lower = bounds[0]
            let upper = bounds.count == 1 ? lower : bounds[1]
            guard lower <= upper else { throw WaitTimeout() }
            result.formUnion(lower...upper)
        }
        return result
    }

    static func serverCount(_ output: String, marker: String) throws -> Int {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: {
            $0.contains(marker)
        }),
        let value = line.split(whereSeparator: \.isWhitespace).last,
        let count = Int(value)
        else {
            throw WaitTimeout()
        }
        return count
    }


    static func inbox(store: MailStore, port: Int) async throws -> FolderSummary? {
        try await store.fetchFolders(account: config(port: port).id).first(where: {
            $0.role == .inbox || $0.path.compare("INBOX", options: [.caseInsensitive]) == .orderedSame
        })
    }

    static func requireInbox(store: MailStore, port: Int) async throws -> FolderSummary {
        guard let inbox = try await inbox(store: store, port: port) else { throw WaitTimeout() }
        return inbox
    }
}

private struct ChaosCommandError: Error, CustomStringConvertible {
    var status: Int32
    var output: String
    var description: String { "chaos.sh exited \(status): \(output)" }
}

@Suite(.serialized)
struct QAChaosTests {
    @Test(.enabled(if: QAChaos.enabled && QAChaos.mutate))
    func liveUidvalidityRestartExpungeDeliverTwice() async throws {
        try QAChaos.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAChaos.probe(port: 1143)

        try await withSyncStore { store, dir in
            let engine = QAChaos.engine(store: store, port: 1143, dir: dir)
            let events = EventLog()
            let collector = Task {
                for await event in await engine.newMail { events.append(event) }
            }
            await engine.start()
            do {

            try await waitUntil(timeout: .seconds(240), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                return inbox.totalCount >= 8_000 && inbox.backfill != .complete
            }
            let mid = try await QAChaos.requireInbox(store: store, port: 1143)
            let oldLive = try #require(await store.liveGeneration(for: mid.id))
            let oldCount = mid.totalCount
            #expect(oldCount >= 8_000)
            print("MAILTERNAL_QA mid-backfill count=\(oldCount) uv=\(oldLive.uidValidity)")

            _ = try QAChaos.chaos("uidvalidity", "INBOX")

            try await waitUntil(timeout: .seconds(480), poll: .milliseconds(500)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                guard let live = try await store.liveGeneration(for: inbox.id) else { return false }
                return live.uidValidity != oldLive.uidValidity
                    && inbox.backfill == .complete
                    && inbox.totalCount >= 1_000
            }
            let afterUV = try await QAChaos.requireInbox(store: store, port: 1143)
            let newLive = try #require(await store.liveGeneration(for: afterUV.id))
            #expect(newLive.uidValidity != oldLive.uidValidity)
            #expect(events.snapshot().isEmpty)
            _ = try await pageSubjects(store, folder: afterUV.id, limit: 40)
            try await assertStoreInvariants(store)

            let beforeRestart = afterUV.totalCount
            _ = try QAChaos.chaos("restart")
            try await waitUntil(timeout: .seconds(60), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                return inbox.totalCount >= beforeRestart / 2
            }

            let page = try await store.page(in: afterUV.id, after: nil, limit: 1)
            if let row = page.rows.first {
                try await store.enqueueFlag(message: row.id, flag: .seen, set: true)
            }

            _ = try QAChaos.chaos("deliver", "80", "INBOX")
            try await waitUntil(timeout: .seconds(60), poll: .milliseconds(400)) {
                (try await QAChaos.inbox(store: store, port: 1143))?.totalCount ?? 0 > beforeRestart
            }
            let afterDeliver = try await QAChaos.requireInbox(store: store, port: 1143)
            #expect(afterDeliver.totalCount > beforeRestart)
            #expect(events.snapshot().count <= afterDeliver.totalCount - beforeRestart + 8)

            _ = try QAChaos.chaos("expunge", "200", "INBOX")
            try await waitUntil(timeout: .seconds(90), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                return inbox.totalCount < afterDeliver.totalCount
            }
            try await waitUntil(timeout: .seconds(20)) {
                try await store.snapshotFlagQueue().isEmpty
            }

            try await drainRetired(store)
            try await assertStoreInvariants(store, drain: true, expectEmptySeen: true)

            collector.cancel()
            await engine.stop()
            await collector.value
            print("MAILTERNAL_QA live sequence events=\(events.snapshot().count) final=\(try await QAChaos.requireInbox(store: store, port: 1143).totalCount)")
            } catch {
                collector.cancel()
                await engine.stop()
                await collector.value
                throw error
            }
        }
    }

    @Test(.enabled(if: QAChaos.enabled))
    func liveCondstorePathVia1143NoEnable() async throws {
        try QAChaos.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAChaos.probe(port: 1143)
        try await withSyncStore { store, dir in
            let engine = QAChaos.engine(store: store, port: 1143, dir: dir, allowEnableQResync: false)
            await engine.start()
            do {
            try await waitUntil(timeout: .seconds(90), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
                let state = try await store.fetchSyncState(for: gen)
                return state?.deltaPath == .condstore && inbox.totalCount >= 200
            }
            let inbox = try await QAChaos.requireInbox(store: store, port: 1143)
            let gen = try #require(await store.liveGeneration(for: inbox.id))
            let state = try #require(await store.fetchSyncState(for: gen))
            #expect(state.deltaPath == .condstore)
            try await assertStoreInvariants(store)
            await engine.stop()
            print("MAILTERNAL_QA condstore path=\(state.deltaPath) count=\(inbox.totalCount)")
            } catch {
                await engine.stop()
                throw error
            }
        }
    }

    /// Scenarios 2–4 against the full instance (1143). Leaves 2143 running.
    /// Does not bump UIDVALIDITY (that dual-stops the shared volume).
    @Test(.enabled(if: QAChaos.enabled && QAChaos.mutate))
    func liveRestartDeliverExpungeOn1143() async throws {
        try QAChaos.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAChaos.probe(port: 1143)
        try await withSyncStore { store, dir in
            let engine = QAChaos.engine(store: store, port: 1143, dir: dir)
            let events = EventLog()
            let collector = Task {
                for await event in await engine.newMail { events.append(event) }
            }
            await engine.start()
            do {
            try await waitUntil(timeout: .seconds(120), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                return inbox.totalCount >= 300
            }
            let beforeRestart = try await QAChaos.requireInbox(store: store, port: 1143)
            let gen = try #require(await store.liveGeneration(for: beforeRestart.id))
            let path = try #require(await store.fetchSyncState(for: gen)).deltaPath
            print("MAILTERNAL_QA pre-restart count=\(beforeRestart.totalCount) path=\(path)")

            _ = try QAChaos.chaos("restart")
            try await waitUntil(timeout: .seconds(90), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143) else { return false }
                return inbox.totalCount >= min(beforeRestart.totalCount, 200)
            }

            let page = try await store.page(in: beforeRestart.id, after: nil, limit: 1)
            if let row = page.rows.first {
                try await store.enqueueFlag(message: row.id, flag: .seen, set: true)
            }

            let preDeliver = try await QAChaos.requireInbox(store: store, port: 1143).totalCount
            let deliverOutput = try QAChaos.chaos("deliver", "2000", "INBOX")
            let deliveredUIDs = try QAChaos.uidSet(deliverOutput, marker: "DELIVERED mailbox=INBOX")
            let serverAfterDeliver = try QAChaos.serverCount(
                deliverOutput,
                marker: "STATUS INBOX MESSAGES"
            )
            #expect(deliveredUIDs.count == 2_000)
            await engine.refreshNow()
            try await waitUntil(timeout: .seconds(180), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143),
                      let current = try await store.liveGeneration(for: inbox.id)
                else { return false }
                let local = Set(try await store.uids(in: current).map(\.rawValue))
                return deliveredUIDs.isSubset(of: local)
                    && inbox.totalCount <= serverAfterDeliver
            }
            let afterDeliver = try await QAChaos.requireInbox(store: store, port: 1143)
            let deliverGeneration = try #require(await store.liveGeneration(for: afterDeliver.id))
            let localBeforeExpunge = Set(
                try await store.uids(in: deliverGeneration).map(\.rawValue)
            )
            #expect(afterDeliver.totalCount >= preDeliver)
            let newMail = events.snapshot().count
            #expect(newMail <= deliveredUIDs.count + 16)
            print(
                "MAILTERNAL_QA deliver +2000 local=\(afterDeliver.totalCount) "
                    + "server=\(serverAfterDeliver) newMail=\(newMail)"
            )

            let expungeOutput = try QAChaos.chaos("expunge", "5000", "INBOX")
            let expungedUIDs = try QAChaos.uidSet(expungeOutput, marker: "EXPUNGED mailbox=INBOX")
            let serverAfterExpunge = try QAChaos.serverCount(expungeOutput, marker: "now EXISTS")
            let deliveredExpunged = deliveredUIDs.intersection(expungedUIDs)
            let deliveredSurvivors = deliveredUIDs.subtracting(expungedUIDs)
            let localExpunged = localBeforeExpunge.intersection(expungedUIDs)
            #expect(expungedUIDs.count == 5_000)
            #expect(serverAfterDeliver - serverAfterExpunge == expungedUIDs.count)
            #expect(!deliveredExpunged.isEmpty)
            #expect(!deliveredSurvivors.isEmpty)
            #expect(!localExpunged.isEmpty)
            let deliveredSurvivor = try #require(deliveredSurvivors.first)

            await engine.refreshNow()
            try await waitUntil(timeout: .seconds(180), poll: .milliseconds(400)) {
                guard let inbox = try await QAChaos.inbox(store: store, port: 1143),
                      let generation = try await store.liveGeneration(for: inbox.id),
                      let state = try await store.fetchSyncState(for: generation)
                else { return false }
                let local = Set(try await store.uids(in: generation).map(\.rawValue))
                let removed = localExpunged.allSatisfy { !local.contains($0) }
                    && deliveredExpunged.allSatisfy { !local.contains($0) }
                let lowWater = state.lowWaterUID?.rawValue ?? UInt32.max
                let walkPassedExpunged = state.backfillPhase == .complete
                    || lowWater <= (localExpunged.min() ?? 0)
                let countConverged = inbox.backfill == .complete
                    ? inbox.totalCount == serverAfterExpunge
                    : inbox.totalCount <= serverAfterExpunge
                return removed
                    && local.contains(deliveredSurvivor)
                    && walkPassedExpunged
                    && countConverged
            }
            try await waitUntil(timeout: .seconds(30)) {
                try await store.snapshotFlagQueue().isEmpty
            }
            let afterExpunge = try await QAChaos.requireInbox(store: store, port: 1143)
            try await assertStoreInvariants(store, drain: true, expectEmptySeen: true)
            print(
                "MAILTERNAL_QA expunge -\(expungedUIDs.count) local=\(afterExpunge.totalCount) "
                    + "server=\(serverAfterExpunge) backfill=\(afterExpunge.backfill)"
            )

            collector.cancel()
            await collector.value
            await engine.stop()
            } catch {
                collector.cancel()
                await engine.stop()
                await collector.value
                throw error
            }
        }
    }
}
#endif
