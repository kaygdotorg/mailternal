#if os(macOS)
import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

private enum QAArchive {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" }
    /// Archive tests mutate the shared seeded mailbox and require an explicit gate.
    static var mutate: Bool { ProcessInfo.processInfo.environment["MAILTERNAL_QA_ARCHIVE"] == "1" }

    static let user = "qa@mailternal.test"
    static let password = "qa-password"
    static let host = "127.0.0.1"
    static let port = 1143
    static let accountID = AccountID(rawValue: "qa-archive-1143")

    static func installTrust() throws {
        let env = ProcessInfo.processInfo.environment["MAILTERNAL_QA_CERT"]
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa/certs/dovecot.crt")
        let url = env.map(URL.init(fileURLWithPath:)) ?? home
        let pem = try Data(contentsOf: url)
        IMAPSession.installAdditionalTrustRoots(pem: [pem])
    }

    static func config() -> AccountConfig {
        AccountConfig(
            id: accountID,
            accountLinkID: AccountLinkID(
                uuidString: "00000000-0000-4000-8000-000000000023"
            )!,
            displayName: "QA Archive",
            emailAddress: user,
            username: user,
            imap: IMAPEndpoint(host: host, port: port, security: .startTLS)
        )
    }

    static func engine(store: MailStore, dir: URL) -> SyncEngine {
        var settings = chaosSettings(
            dir: dir,
            window: SyncPolicy.defaultWindowSize,
            allowEnableQResync: true
        )
        // Leave an observable window for the adversarial expunge. The queue is
        // still drained promptly enough for a live test.
        settings.seenPoll = .seconds(2)
        settings.periodicTick = .seconds(5)
        settings.cleanupTick = .seconds(5)
        return SyncEngine(
            store: store,
            config: config(),
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

    static func probe() async throws {
        try await withSession { session in
            _ = try await session.select("INBOX")
        }
    }

    static func withSession<T>(
        _ body: (IMAPSession) async throws -> T
    ) async throws -> T {
        let session = IMAPSession(
            endpoint: IMAPEndpoint(host: host, port: port, security: .startTLS),
            username: user,
            password: password
        )
        try await session.connect()
        do {
            let value = try await body(session)
            await session.close()
            return value
        } catch {
            await session.close()
            throw error
        }
    }

    static func serverCounts() async throws -> (inbox: Int, archive: Int, archiveUIDNext: UInt32?) {
        try await withSession { session in
            let inbox = try await session.select("INBOX")
            let archive = try await session.select("Archive")
            return (inbox.exists, archive.exists, archive.uidNext)
        }
    }
    static func waitForServerCounts(
        inbox expectedInbox: Int,
        archive expectedArchive: Int,
        timeout: Duration
    ) async throws -> (inbox: Int, archive: Int) {
        try await withSession { session in
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            var latest = (inbox: -1, archive: -1)
            while clock.now < deadline {
                let inbox = try await session.select("INBOX")
                let archive = try await session.select("Archive")
                latest = (inbox.exists, archive.exists)
                if latest.inbox == expectedInbox && latest.archive == expectedArchive {
                    return latest
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            throw WaitTimeout()
        }
    }

    static func fetch(
        session: IMAPSession,
        mailbox: String,
        uids: IMAPUIDSet,
        envelope: Bool = false
    ) async throws -> [IMAPFetchedMessage] {
        _ = try await session.select(mailbox)
        return try await session.fetch(IMAPFetchRequest(
            uids: uids,
            envelope: envelope,
            flags: false
        ))
    }

    static func archiveAdded(
        session: IMAPSession,
        after uidNext: UInt32?,
        subjects: Set<String>
    ) async throws -> [UInt32] {
        guard let uidNext, uidNext < UInt32.max else { return [] }
        let fetched = try await fetch(
            session: session,
            mailbox: "Archive",
            uids: IMAPUIDSet(ranges: [uidNext...UInt32.max]),
            envelope: true
        )
        return fetched.compactMap { message in
            guard let uid = message.uid,
                  let subject = message.envelope?.subject,
                  subjects.contains(subject)
            else { return nil }
            return uid
        }
    }

    static func restoreArchive(
        after uidNext: UInt32?,
        subjects: Set<String>
    ) async throws -> (inbox: Int, archive: Int) {
        let counts = try await withSession { session in
            let uids = try await archiveAdded(
                session: session,
                after: uidNext,
                subjects: subjects
            )
            if !uids.isEmpty {
                _ = try await session.select("Archive")
                try await session.move(
                    uids: IMAPUIDSet(ranges: uids.map { $0...$0 }),
                    to: "INBOX"
                )
            }
            let inbox = try await session.select("INBOX")
            let archive = try await session.select("Archive")
            return (inbox.exists, archive.exists)
        }
        return counts
    }

    static func requireInbox(_ store: MailStore) async throws -> FolderSummary {
        guard let inbox = try await store.fetchFolders(account: accountID).first(where: {
            $0.role == .inbox || $0.path.compare("INBOX", options: [.caseInsensitive]) == .orderedSame
        }) else { throw WaitTimeout() }
        return inbox
    }

    static func waitForSyncedInbox(_ store: MailStore) async throws -> FolderSummary {
        do {
            try await waitUntil(timeout: .seconds(300), poll: .milliseconds(400)) {
                let inbox = try? await requireInbox(store)
                // The queue is usable as soon as a few hundred rows are present;
                // waiting for the complete 93k-message history would make this
                // write-path test unnecessarily long.
                return (inbox?.totalCount ?? 0) >= 300
            }
        } catch {
            if let inbox = try? await requireInbox(store) {
                print(
                    "MAILTERNAL_QA archive sync timeout local=\(inbox.totalCount) "
                        + "backfill=\(inbox.backfill)"
                )
            }
            throw error
        }
        return try await requireInbox(store)
    }

    static func localUIDs(_ store: MailStore, folder: FolderID, limit: Int) async throws -> [(MessageID, IMAPUID)] {
        let page = try await store.page(in: folder, after: nil, limit: limit)
        var result: [(MessageID, IMAPUID)] = []
        result.reserveCapacity(page.rows.count)
        for row in page.rows {
            if let ref = try await store.messageRef(row.id) {
                result.append((row.id, ref.uid))
            }
        }
        return result
    }
    static func messagesGone(_ store: MailStore, ids: [MessageID]) async throws -> Bool {
        for id in ids {
            if try await store.messageRef(id) != nil { return false }
        }
        return true
    }

    /// True when none of the UIDs exist in the folder's given generation.
    /// Deliberately not `messageRef`-by-id: row ids are date-bucketed and a
    /// moved message's Archive-folder row can legitimately reproduce the id
    /// the INBOX row freed (same internal-date bucket), so id-based absence
    /// checks misreport the archive as "resurrected".
    static func goneFromGeneration(
        _ store: MailStore,
        generation: MailboxGeneration,
        uids: [IMAPUID]
    ) async throws -> Bool {
        for uid in uids {
            if try await store.messageID(generation: generation, uid: uid) != nil {
                return false
            }
        }
        return true
    }
}

@Suite(.serialized)
struct QAArchiveLiveTests {
    @Test(.enabled(if: QAArchive.enabled && QAArchive.mutate))
    func liveArchiveMoveOptimisticDeleteAndDelta() async throws {
        try QAArchive.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAArchive.probe()

        var restoreNext: UInt32?
        var restoreSubjects = Set<String>()
        do {
            try await withSyncStore { store, dir in
                let engine = QAArchive.engine(store: store, dir: dir)
                await engine.start()
                do {
                    let inbox = try await QAArchive.waitForSyncedInbox(store)
                    let countsBefore = try await QAArchive.serverCounts()
                    restoreNext = countsBefore.archiveUIDNext
                    let pair = try #require(try await QAArchive.localUIDs(store, folder: inbox.id, limit: 1).first)
                    let message = try await store.detail(pair.0)
                    restoreSubjects = [message.envelope.subject]
                    let ref = try #require(await store.messageRef(pair.0))
                    #expect(ref.uid == pair.1)
                    #expect(countsBefore.inbox >= inbox.totalCount)

                    try await store.enqueueMove(message: pair.0, to: .archive)
                    let afterEnqueueRef = try await store.messageRef(pair.0)
                    #expect(afterEnqueueRef == nil)
                    try await waitUntil(timeout: .seconds(30), poll: .milliseconds(200)) {
                        try await store.snapshotMoveQueue().isEmpty
                    }

                    let moved = try await QAArchive.withSession { side in
                        let archiveHits = try await QAArchive.archiveAdded(
                            session: side,
                            after: countsBefore.archiveUIDNext,
                            subjects: restoreSubjects
                        )
                        let inboxHits = try await QAArchive.fetch(
                            session: side,
                            mailbox: "INBOX",
                            uids: IMAPUIDSet(uid: ref.uid.rawValue)
                        )
                        return (archiveHits, inboxHits)
                    }
                    #expect(moved.0.count == 1)
                    #expect(moved.1.isEmpty)

                    await engine.refreshNow()
                    try await waitUntil(timeout: .seconds(30), poll: .milliseconds(300)) {
                        guard let generation = try await store.liveGeneration(for: inbox.id) else { return false }
                        return try await store.messageID(generation: generation, uid: ref.uid) == nil
                    }
                    // The successful post-mutation refresh below demonstrates that
                    // the engine's session remained usable.
                    print(
                        "MAILTERNAL_QA archive single inbox=\(countsBefore.inbox)->\(try await QAArchive.serverCounts().inbox) "
                            + "archive=\(countsBefore.archive)->\(try await QAArchive.serverCounts().archive)"
                    )
                } catch {
                    await engine.stop()
                    throw error
                }
                await engine.stop()
            }
            let restored = try await QAArchive.restoreArchive(after: restoreNext, subjects: restoreSubjects)
            print("MAILTERNAL_QA archive single restored inbox=\(restored.inbox) archive=\(restored.archive)")
        } catch {
            if !restoreSubjects.isEmpty {
                let restored = try? await QAArchive.restoreArchive(after: restoreNext, subjects: restoreSubjects)
                if let restored { print("MAILTERNAL_QA archive single recovery inbox=\(restored.inbox) archive=\(restored.archive)") }
            }
            throw error
        }
    }

    @Test(.enabled(if: QAArchive.enabled && QAArchive.mutate))
    func liveArchiveBurstDrainsExactly25() async throws {
        try QAArchive.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAArchive.probe()

        var restoreNext: UInt32?
        var restoreSubjects = Set<String>()
        var probePairs: [(MessageID, IMAPUID)] = []
        do {
            try await withSyncStore { store, dir in
                let engine = QAArchive.engine(store: store, dir: dir)
                await engine.start()
                do {
                    let t0 = ContinuousClock.now
                    func mark(_ label: String) {
                        print("MAILTERNAL_QA archive burst t=\(ContinuousClock.now - t0) \(label)")
                    }
                    let inbox = try await QAArchive.waitForSyncedInbox(store)
                    mark("synced")
                    let countsBefore = try await QAArchive.serverCounts()
                    mark("counts-before \(countsBefore)")
                    restoreNext = countsBefore.archiveUIDNext
                    let pairs = try await QAArchive.localUIDs(store, folder: inbox.id, limit: 25)
                    try #require(pairs.count == 25)
                    let generation = try #require(await store.liveGeneration(for: inbox.id))
                    let details = try await pairs.asyncMap { try await store.detail($0.0) }
                    restoreSubjects = Set(details.map { $0.envelope.subject })
                    #expect(restoreSubjects.count == 25)
                    for pair in pairs { try await store.enqueueMove(message: pair.0, to: .archive) }
                    probePairs = pairs
                    mark("enqueued")
                    let immediateGone = try await QAArchive.goneFromGeneration(
                        store,
                        generation: generation,
                        uids: pairs.map(\.1)
                    )
                    #expect(immediateGone)
                    try await waitUntil(timeout: .seconds(120), poll: .milliseconds(250)) {
                        try await store.snapshotMoveQueue().isEmpty
                    }
                    mark("queue-empty")
                    let countsAfter = try await QAArchive.waitForServerCounts(
                        inbox: countsBefore.inbox - 25,
                        archive: countsBefore.archive + 25,
                        timeout: .seconds(60)
                    )
                    mark("counts-after \(countsAfter)")
                    #expect(countsAfter.inbox == countsBefore.inbox - 25)
                    #expect(countsAfter.archive == countsBefore.archive + 25)
                    #expect(try await store.snapshotMoveQueue().isEmpty)
                    await engine.refreshNow()
                    mark("refreshed")
                    try await waitUntil(timeout: .seconds(30), poll: .milliseconds(300)) {
                        try await QAArchive.goneFromGeneration(
                            store,
                            generation: generation,
                            uids: pairs.map(\.1)
                        )
                    }
                    mark("gone-stable")
                    print(
                        "MAILTERNAL_QA archive burst inbox=\(countsBefore.inbox)->\(countsAfter.inbox) "
                            + "archive=\(countsBefore.archive)->\(countsAfter.archive) queue=0"
                    )
                } catch {
                    // Post-mortem before the temp store vanishes: every archive
                    // dequeue path that skips the server must leave a log row.
                    let pending = (try? await store.snapshotMoveQueue()) ?? []
                    let logs = (try? await store.fetchErrorLog()) ?? []
                    print("MAILTERNAL_QA archive burst postmortem pending=\(pending.count)")
                    for op in pending {
                        print("MAILTERNAL_QA archive burst pending op uid=\(op.uid.rawValue) uv=\(op.uidValidity) copied=\(op.copied)")
                    }
                    for entry in logs.suffix(40) {
                        print("MAILTERNAL_QA archive burst log kind=\(entry.kind) message=\(entry.message) detail=\(entry.detail ?? "")")
                    }
                    for (id, uid) in probePairs {
                        let ref = try? await store.messageRef(id)
                        if let ref {
                            print(
                                "MAILTERNAL_QA archive burst survivor id=\(id.rawValue) "
                                    + "expectedUID=\(uid.rawValue) actualUID=\(ref.uid.rawValue)"
                            )
                        }
                    }
                    await engine.stop()
                    throw error
                }
                await engine.stop()
            }
            let restored = try await QAArchive.restoreArchive(after: restoreNext, subjects: restoreSubjects)
            print("MAILTERNAL_QA archive burst restored inbox=\(restored.inbox) archive=\(restored.archive)")
        } catch {
            if !restoreSubjects.isEmpty {
                let restored = try? await QAArchive.restoreArchive(after: restoreNext, subjects: restoreSubjects)
                if let restored { print("MAILTERNAL_QA archive burst recovery inbox=\(restored.inbox) archive=\(restored.archive)") }
            }
            throw error
        }
    }

    @Test(.enabled(if: QAArchive.enabled && QAArchive.mutate))
    func liveArchiveExpungeBeforeDrainDoesNotWedge() async throws {
        try QAArchive.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAArchive.probe()

        var restoreNext: UInt32?
        var restoreSubjects = Set<String>()
        do {
            try await withSyncStore { store, dir in
                let engine = QAArchive.engine(store: store, dir: dir)
                await engine.start()
                do {
                    let inbox = try await QAArchive.waitForSyncedInbox(store)
                    let countsBefore = try await QAArchive.serverCounts()
                    restoreNext = countsBefore.archiveUIDNext
                    let pair = try #require(try await QAArchive.localUIDs(store, folder: inbox.id, limit: 1).first)
                    let detail = try await store.detail(pair.0)
                    restoreSubjects = [detail.envelope.subject]
                    let ref = try #require(await store.messageRef(pair.0))
                    try await store.enqueueMove(message: pair.0, to: .archive)
                    let afterEnqueueRef = try await store.messageRef(pair.0)
                    #expect(afterEnqueueRef == nil)
                    let pendingBeforeExpunge = !(try await store.snapshotMoveQueue()).isEmpty
                    if !pendingBeforeExpunge {
                        print("MAILTERNAL_QA archive adversarial race: drain completed before side EXPUNGE")
                    }

                    let expunged = try await QAArchive.withSession { side in
                        let before = try await QAArchive.fetch(
                            session: side,
                            mailbox: "INBOX",
                            uids: IMAPUIDSet(uid: ref.uid.rawValue)
                        )
                        guard !before.isEmpty else { return false }
                        _ = try await side.select("INBOX")
                        try await side.storeDeleted(uids: IMAPUIDSet(uid: ref.uid.rawValue))
                        try await side.expunge(uids: IMAPUIDSet(uid: ref.uid.rawValue))
                        return true
                    }
                    if !expunged {
                        print("MAILTERNAL_QA archive adversarial race: UID already drained before side EXPUNGE")
                    }

                    try await waitUntil(timeout: .seconds(45), poll: .milliseconds(250)) {
                        try await store.snapshotMoveQueue().isEmpty
                    }
                    await engine.refreshNow()
                    try await waitUntil(timeout: .seconds(30), poll: .milliseconds(300)) {
                        try await QAArchive.messagesGone(store, ids: [pair.0])
                    }
                    let errors = try await store.fetchErrorLog()
                    #expect(errors.allSatisfy { $0.kind != .archive || !$0.message.isEmpty })
                    // The successful post-mutation refresh below demonstrates that
                    // the engine's session remained usable.
                    let countsAfter = try await QAArchive.serverCounts()
                    #expect(countsAfter.inbox == countsBefore.inbox - 1)
                    print(
                        "MAILTERNAL_QA archive adversarial inbox=\(countsBefore.inbox)->\(countsAfter.inbox) "
                            + "archive=\(countsBefore.archive)->\(countsAfter.archive) queue=0 "
                            + "archiveErrors=\(errors.filter { $0.kind == .archive }.count)"
                    )
                } catch {
                    await engine.stop()
                    throw error
                }
                await engine.stop()
            }
            let restored = try await QAArchive.restoreArchive(after: restoreNext, subjects: restoreSubjects)
            print("MAILTERNAL_QA archive adversarial cleanup inbox=\(restored.inbox) archive=\(restored.archive) (expunged UID remains intentionally absent)")
        } catch {
            if !restoreSubjects.isEmpty {
                let restored = try? await QAArchive.restoreArchive(after: restoreNext, subjects: restoreSubjects)
                if let restored { print("MAILTERNAL_QA archive adversarial recovery inbox=\(restored.inbox) archive=\(restored.archive)") }
            }
            throw error
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
#endif
