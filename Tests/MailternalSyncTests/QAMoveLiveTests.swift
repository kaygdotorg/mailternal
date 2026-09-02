#if os(macOS)
import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

/// Live write-path coverage for the basic-IMAP endpoint. Every fixture uses
/// short-lived, test-only mailboxes so UIDVALIDITY bumps, EXPUNGEs, and DELETEs
/// cannot disturb the shared INBOX or role folders used by other QA agents.
private enum QAMoveQA {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1"
            && ProcessInfo.processInfo.environment["MAILTERNAL_QA_MOVE"] == "1"
    }

    static let user = "qa@mailternal.test"
    static let password = "qa-password"
    static let host = "127.0.0.1"
    static let port = 2143
    static let accountID = AccountID(rawValue: "qa-127.0.0.1-1143")
    static let accountLinkID = AccountLinkID(
        uuidString: "00000000-0000-4000-8000-000000000024"
    )!

    struct State: Sendable, CustomStringConvertible {
        var exists: Int
        var uidNext: UInt32?
        var uidValidity: UInt32
        var highestModSeq: UInt64?
        var description: String {
            let next = uidNext.map(String.init) ?? "nil"
            let modseq = highestModSeq.map(String.init) ?? "nil"
            return "exists=\(exists) uidNext=\(next) uidValidity=\(uidValidity) modseq=\(modseq)"
        }
    }

    struct LocalMessage: Sendable {
        var id: MessageID
        var uid: IMAPUID
        var key: String
        var isRead: Bool
        var isFlagged: Bool
    }

    static func config() -> AccountConfig {
        AccountConfig(
            id: accountID,
            accountLinkID: accountLinkID,
            displayName: "QA Move",
            emailAddress: user,
            username: user,
            imap: IMAPEndpoint(host: host, port: port, security: .startTLS)
        )
    }

    static func installTrust() throws {
        let env = ProcessInfo.processInfo.environment["MAILTERNAL_QA_CERT"]
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa/certs/dovecot.crt")
        let pem = try Data(contentsOf: env.map(URL.init(fileURLWithPath:)) ?? home)
        IMAPSession.installAdditionalTrustRoots(pem: [pem])
    }

    static func engine(store: MailStore, dir: URL) -> SyncEngine {
        var settings = chaosSettings(
            dir: dir,
            window: SyncPolicy.defaultWindowSize,
            allowEnableQResync: true
        )
        settings.seenPoll = .seconds(1)
        settings.periodicTick = .seconds(4)
        settings.cleanupTick = .seconds(4)
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

    static func withSession<T>(_ body: (IMAPSession) async throws -> T) async throws -> T {
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

    static func probe() async throws {
        try await withSession { _ in () }
    }
    private static func runQAMoveStore(
        _ body: (MailStore, URL) async throws -> Void,
        dir: URL,
        databaseURL: URL
    ) async throws {
        let store = try MailStore(
            databaseURL: databaseURL,
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        try await body(store, dir)
    }

    private static func snapshotStore(
        from template: URL,
        to destination: URL
    ) throws {
        guard FileManager.default.isReadableFile(atPath: template.path) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", template.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let destinationPath = destination.path.replacingOccurrences(of: "'", with: "''")
        let sql = "PRAGMA busy_timeout=10000;\nVACUUM INTO '\(destinationPath)';\n"

        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let outputText = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0,
              FileManager.default.isReadableFile(atPath: destination.path)
        else {
            throw InvariantFailure(
                issues: [
                    "sqlite snapshot failed (\(process.terminationStatus)): \(outputText)"
                ]
            )
        }
    }

    static func withQAMoveStore(
        _ body: (MailStore, URL) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailternal-qamove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let template = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa-ReaderIslands/store.sqlite")
        let destination = dir.appendingPathComponent("mail.sqlite")

        do {
            try snapshotStore(from: template, to: destination)
            try await runQAMoveStore(body, dir: dir, databaseURL: destination)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        try? FileManager.default.removeItem(at: dir)
    }

    static func state(_ mailbox: String) async throws -> State {
        try await withSession { session in
            let selected = try await session.select(mailbox)
            return State(
                exists: selected.exists,
                uidNext: selected.uidNext,
                uidValidity: selected.uidValidity,
                highestModSeq: selected.highestModSeq
            )
        }
    }

    static func fetch(
        mailbox: String,
        uids: IMAPUIDSet,
        envelope: Bool = true
    ) async throws -> [IMAPFetchedMessage] {
        try await withSession { session in
            _ = try await session.select(mailbox)
            return try await session.fetch(IMAPFetchRequest(
                uids: uids,
                envelope: envelope,
                flags: true
            ))
        }
    }

    static func fetchAdded(
        mailbox: String,
        after uidNext: UInt32?,
        keys: Set<String>? = nil
    ) async throws -> [(key: String, uid: IMAPUID)] {
        let start = uidNext ?? 1
        guard start < UInt32.max else { return [] }
        let fetched = try await fetch(
            mailbox: mailbox,
            uids: IMAPUIDSet(ranges: [start...UInt32.max])
        )
        return fetched.compactMap { message in
            guard let uid = message.uid, let envelope = message.envelope else { return nil }
            let key = stableKey(messageID: envelope.messageID, subject: envelope.subject, uid: uid)
            guard keys == nil || keys!.contains(key) else { return nil }
            return (key, IMAPUID(rawValue: uid))
        }
    }

    static func stableKey(messageID: String?, subject: String?, uid: UInt32) -> String {
        if let messageID, !messageID.isEmpty {
            return "mid:\(messageID.lowercased())"
        }
        return "subject:\(subject ?? "")|uid:\(uid)"
    }

    static func folder(_ store: MailStore, path: String) async throws -> FolderSummary? {
        try await store.fetchFolders(account: accountID).first {
            $0.path.compare(path, options: [.caseInsensitive]) == .orderedSame
        }
    }

    static func requireFolder(_ store: MailStore, path: String) async throws -> FolderSummary {
        guard let folder = try await folder(store, path: path) else { throw WaitTimeout() }
        return folder
    }

    static func waitForFolder(
        _ store: MailStore,
        path: String,
        count: Int,
        timeout: Duration = .seconds(30)
    ) async throws -> FolderSummary {
        try await waitUntil(timeout: timeout, poll: .milliseconds(350)) {
            guard let summary = try await folder(store, path: path) else { return false }
            return summary.totalCount == count
        }
        return try await requireFolder(store, path: path)
    }

    static func localMessages(
        _ store: MailStore,
        folder: FolderID,
        limit: Int
    ) async throws -> [LocalMessage] {
        let page = try await store.page(in: folder, after: nil, limit: limit)
        var result: [LocalMessage] = []
        result.reserveCapacity(page.rows.count)
        for row in page.rows {
            guard let ref = try await store.messageRef(row.id) else { continue }
            let detail = try await store.detail(row.id)
            let key = stableKey(
                messageID: detail.envelope.rfcMessageID,
                subject: detail.envelope.subject,
                uid: ref.uid.rawValue
            )
            result.append(LocalMessage(
                id: row.id,
                uid: ref.uid,
                key: key,
                isRead: row.isRead,
                isFlagged: row.isFlagged
            ))
        }
        return result
    }

    static func localIDs(
        _ store: MailStore,
        folder: FolderID,
        generation: MailboxGeneration,
        serverMessages: [(key: String, uid: IMAPUID)]
    ) async throws -> [MessageID] {
        var result: [MessageID] = []
        result.reserveCapacity(serverMessages.count)
        for message in serverMessages {
            if let id = try await store.messageID(generation: generation, uid: message.uid) {
                result.append(id)
            }
        }
        return result
    }

    static func createOrDelete(_ operation: String, mailboxes: [String]) throws {
        let source = """
        import imaplib, ssl, sys
        ctx = ssl._create_unverified_context()
        c = imaplib.IMAP4("127.0.0.1", \(port))
        typ, _ = c.starttls(ssl_context=ctx)
        if typ != "OK": raise RuntimeError("STARTTLS failed")
        typ, _ = c.login("qa@mailternal.test", "qa-password")
        if typ != \"OK\": raise RuntimeError(\"LOGIN failed\")
        op = sys.argv[1]
        for mailbox in sys.argv[2:]:
            if op == \"create\":
                typ, data = c.create(mailbox)
                if typ != \"OK\":
                    raise RuntimeError(f\"CREATE {mailbox}: {typ} {data}\")
            elif op == \"delete\":
                typ, data = c.delete(mailbox)
                if typ != \"OK\":
                    raise RuntimeError(f\"DELETE {mailbox}: {typ} {data}\")
            else:
                raise RuntimeError(\"unknown operation\")
        c.logout()
        print(op, \" \".join(sys.argv[2:]))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", source, operation] + mailboxes
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("MAILTERNAL_QA move python \(operation) \(mailboxes.joined(separator: " "))\n\(output)")
        if process.terminationStatus != 0 {
            throw InvariantFailure(issues: ["python \(operation) failed: \(output)"])
        }
    }

    @discardableResult
    static func chaos(_ args: String...) throws -> String {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa/chaos.sh")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = script
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging([
            "QA_REMOTE": "1",
            "QA_IMAP_HOST": host,
            "QA_IMAP_PORT": String(port),
            "QA_IMAP_TLS": "starttls",
        ]) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        print("MAILTERNAL_QA move chaos \(args.joined(separator: " "))\n\(output)")
        if process.terminationStatus != 0 {
            throw InvariantFailure(issues: ["chaos.sh failed: \(output)"])
        }
        return output
    }

    static func append(_ count: Int, to mailbox: String) throws {
        _ = try chaos("deliver", String(count), mailbox)
    }

    static func directRestore(
        mailbox: String,
        to destination: String,
        after uidNext: UInt32?,
        keys: Set<String>
    ) async throws {
        let added = try await fetchAdded(mailbox: mailbox, after: uidNext, keys: keys)
        guard !added.isEmpty else { return }
        let uids = IMAPUIDSet(ranges: added.map { $0.uid.rawValue...$0.uid.rawValue })
        try await withSession { session in
            _ = try await session.select(mailbox)
            try await session.copy(uids: uids, to: destination)
            try await session.storeDeleted(uids: uids)
            try await session.expunge(uids: uids)
        }
    }

    static func expungeExact(
        mailbox: String,
        uids: [IMAPUID]
    ) async throws {
        guard !uids.isEmpty else { return }
        try await withSession { session in
            _ = try await session.select(mailbox)
            let set = IMAPUIDSet(ranges: uids.map { $0.rawValue...$0.rawValue })
            try await session.storeDeleted(uids: set)
            try await session.expunge(uids: set)
        }
    }

    static func assertIntegrity(_ store: MailStore, dir: URL, label: String) async throws {
        try await assertStoreInvariants(store, drain: true)
        let report = try await store.checkInvariants()
        guard report.isClean else { throw InvariantFailure(issues: report.issues) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "sqlite3",
            dir.appendingPathComponent("mail.sqlite").path,
            "PRAGMA integrity_check;"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, output == "ok" else {
            throw InvariantFailure(issues: ["sqlite integrity_check: \(output)"])
        }
        print("MAILTERNAL_QA move \(label) integrity_check=ok messages=\(report.messageCount) fts=\(report.ftsCount)")
    }

    static func deleteFixture(_ source: String, _ destination: String) {
        try? createOrDelete("delete", mailboxes: [source, destination])
    }
}

@Suite(.serialized)
struct QAMoveLiveTests {
    @Test(.enabled(if: QAMoveQA.enabled))
    func liveBatchMoveToCustomFolderAndBack() async throws {
        try QAMoveQA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAMoveQA.probe()
        let source = "QAMove-Src-\(UUID().uuidString.prefix(8))"
        let destination = "QAMove-Dst-\(UUID().uuidString.prefix(8))"
        defer { QAMoveQA.deleteFixture(source, destination) }
        try QAMoveQA.createOrDelete("create", mailboxes: [source, destination])
        try QAMoveQA.append(25, to: source)

        try await QAMoveQA.withQAMoveStore { store, dir in
            let engine = QAMoveQA.engine(store: store, dir: dir)
            await engine.start()
            do {
                let sourceFolder = try await QAMoveQA.waitForFolder(store, path: source, count: 25)
                let destinationFolder = try await QAMoveQA.requireFolder(store, path: destination)
                let destinationGeneration = try #require(await store.liveGeneration(for: destinationFolder.id))
                let selected = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 25)
                try #require(selected.count == 25)
                let keys = Set(selected.map(\.key))
                try #require(keys.count == 25)
                let beforeSource = try await QAMoveQA.state(source)
                let beforeDestination = try await QAMoveQA.state(destination)

                try await store.enqueueMove(messages: selected.map(\.id), to: destinationFolder.id)
                try await waitUntil(timeout: .seconds(120), poll: .milliseconds(250)) {
                    try await store.snapshotMoveQueue().isEmpty
                }
                let afterMoveSource = try await QAMoveQA.state(source)
                let afterMoveDestination = try await QAMoveQA.state(destination)
                #expect(afterMoveSource.exists == beforeSource.exists - 25)
                #expect(afterMoveDestination.exists == beforeDestination.exists + 25)
                let moveSourceDelta = (afterMoveSource.highestModSeq ?? 0) &- (beforeSource.highestModSeq ?? 0)
                let moveDestinationDelta = (afterMoveDestination.highestModSeq ?? 0) &- (beforeDestination.highestModSeq ?? 0)
                print("MAILTERNAL_QA move custom batch operations=1 sourceModseqDelta=\(moveSourceDelta) destinationModseqDelta=\(moveDestinationDelta)")

                try await waitUntil(timeout: .seconds(120), poll: .milliseconds(300)) {
                    let live = try await store.liveGeneration(for: destinationFolder.id) ?? destinationGeneration
                    let added = try await QAMoveQA.fetchAdded(
                        mailbox: destination,
                        after: beforeDestination.uidNext,
                        keys: keys
                    )
                    guard added.count == 25 else { return false }
                    let ids = try await QAMoveQA.localIDs(
                        store,
                        folder: destinationFolder.id,
                        generation: live,
                        serverMessages: added
                    )
                    return ids.count == 25
                }
                let added = try await QAMoveQA.fetchAdded(mailbox: destination, after: beforeDestination.uidNext, keys: keys)
                let destinationIDs = try await QAMoveQA.localIDs(
                    store,
                    folder: destinationFolder.id,
                    generation: try #require(await store.liveGeneration(for: destinationFolder.id)),
                    serverMessages: added
                )
                try #require(destinationIDs.count == 25)
                try await store.enqueueMove(messages: destinationIDs, to: sourceFolder.id)
                try await waitUntil(timeout: .seconds(120), poll: .milliseconds(250)) {
                    try await store.snapshotMoveQueue().isEmpty
                }
                let finalSource = try await QAMoveQA.state(source)
                let finalDestination = try await QAMoveQA.state(destination)
                #expect(finalSource.exists == beforeSource.exists)
                #expect(finalDestination.exists == beforeDestination.exists)
                #expect(finalSource.uidValidity == beforeSource.uidValidity)
                #expect(finalDestination.uidValidity == beforeDestination.uidValidity)
                let _ = try await QAMoveQA.waitForFolder(store, path: source, count: 25)
                try await QAMoveQA.assertIntegrity(store, dir: dir, label: "custom-move")
            } catch {
                await engine.stop()
                throw error
            }
            await engine.stop()
        }
    }

    @Test(.enabled(if: QAMoveQA.enabled))
    func liveTrashBatchWithSideExpunge() async throws {
        try QAMoveQA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAMoveQA.probe()
        let source = "QAMove-TrashSrc-\(UUID().uuidString.prefix(8))"
        let trash = "QAMove-Trash-\(UUID().uuidString.prefix(8))"
        defer { QAMoveQA.deleteFixture(source, trash) }
        try QAMoveQA.createOrDelete("create", mailboxes: [source, trash])
        try QAMoveQA.append(25, to: source)

        try await QAMoveQA.withQAMoveStore { store, dir in
            let engine = QAMoveQA.engine(store: store, dir: dir)
            await engine.start()
            do {
                let sourceFolder = try await QAMoveQA.waitForFolder(store, path: source, count: 25)
                let trashFolder = try await QAMoveQA.requireFolder(store, path: trash)
                let selected = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 25)
                try #require(selected.count == 25)
                let keys = Set(selected.map(\.key))
                let beforeSource = try await QAMoveQA.state(source)
                let beforeTrash = try await QAMoveQA.state(trash)
                let errorsBefore = try await store.fetchErrorLog().count
                let victims = Array(selected.prefix(5).map(\.uid))
                let expunger = Task { () throws -> Bool in
                    let deadline = ContinuousClock.now + .seconds(90)
                    while ContinuousClock.now < deadline {
                        if !(try await store.snapshotMoveQueue()).isEmpty {
                            try await QAMoveQA.expungeExact(mailbox: source, uids: victims)
                            return true
                        }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    return false
                }
                try await store.enqueueMove(messages: selected.map(\.id), to: trashFolder.id)
                let didExpunge = try await expunger.value
                #expect(didExpunge, "side-session EXPUNGE did not overlap the move drain")
                try await waitUntil(timeout: .seconds(120), poll: .milliseconds(250)) {
                    try await store.snapshotMoveQueue().isEmpty
                }
                let afterSource = try await QAMoveQA.state(source)
                let afterTrash = try await QAMoveQA.state(trash)
                #expect(afterSource.exists == beforeSource.exists - 25)
                #expect(afterTrash.exists == beforeTrash.exists + 20)
                let _ = try await QAMoveQA.waitForFolder(store, path: source, count: 0)
                let _ = try await QAMoveQA.waitForFolder(store, path: trash, count: 20)
                let errors = try await store.fetchErrorLog()
                print("MAILTERNAL_QA move trash side-expunge victims=5 errors=\(errors.count - errorsBefore) source=\(afterSource.exists) destination=\(afterTrash.exists)")
                #expect(errors.count >= errorsBefore)

                let moved = try await QAMoveQA.fetchAdded(mailbox: trash, after: beforeTrash.uidNext, keys: keys)
                let trashGeneration = try #require(await store.liveGeneration(for: trashFolder.id))
                let movedIDs = try await QAMoveQA.localIDs(store, folder: trashFolder.id, generation: trashGeneration, serverMessages: moved)
                try #require(movedIDs.count == 20)
                try await store.enqueueMove(messages: movedIDs, to: sourceFolder.id)
                try await waitUntil(timeout: .seconds(120), poll: .milliseconds(250)) {
                    try await store.snapshotMoveQueue().isEmpty
                }
                let restoredSource = try await QAMoveQA.state(source)
                #expect(restoredSource.exists == beforeSource.exists - 5)
                try await QAMoveQA.assertIntegrity(store, dir: dir, label: "trash-side-expunge")
            } catch {
                await engine.stop()
                throw error
            }
            await engine.stop()
        }
    }

    @Test(.enabled(if: QAMoveQA.enabled))
    func liveDestinationDeleteMidDrainDropsMoves() async throws {
        try QAMoveQA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAMoveQA.probe()
        let source = "QAMove-DeleteSrc-\(UUID().uuidString.prefix(8))"
        let destination = "QAMove-DeleteDst-\(UUID().uuidString.prefix(8))"
        defer { QAMoveQA.deleteFixture(source, destination) }
        try QAMoveQA.createOrDelete("create", mailboxes: [source, destination])
        try QAMoveQA.append(25, to: source)

        try await QAMoveQA.withQAMoveStore { store, dir in
            let engine = QAMoveQA.engine(store: store, dir: dir)
            await engine.start()
            do {
                let sourceFolder = try await QAMoveQA.waitForFolder(store, path: source, count: 25)
                let destinationFolder = try await QAMoveQA.requireFolder(store, path: destination)
                let selected = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 25)
                let keys = Set(selected.map(\.key))
                let beforeSource = try await QAMoveQA.state(source)
                let beforeDestination = try await QAMoveQA.state(destination)

                // Stop after discovery, then mutate the server while the move
                // remains queued. Restarting drains against the missing target,
                // making this race-free while still covering the queued path.
                await engine.stop()
                try await store.enqueueMove(messages: selected.map(\.id), to: destinationFolder.id)
                try QAMoveQA.createOrDelete("delete", mailboxes: [destination])
                await engine.start()
                try await waitUntil(timeout: .seconds(120), poll: .milliseconds(250)) {
                    try await store.snapshotMoveQueue().isEmpty
                }
                let errors = try await store.fetchErrorLog()
                let moveErrors = errors.filter {
                    $0.kind == .archive
                        && $0.message.localizedCaseInsensitiveContains(
                            "destination folder \(destinationFolder.id.rawValue)"
                        )
                }
                #expect(
                    !moveErrors.isEmpty,
                    "destination deletion must record a move error naming destination folder \(destinationFolder.id.rawValue)"
                )
                try QAMoveQA.createOrDelete("create", mailboxes: [destination])
                await engine.stop()
                await engine.start()
                try await waitUntil(timeout: .seconds(15), poll: .milliseconds(300)) {
                    try await QAMoveQA.folder(store, path: destination) != nil
                }
                let afterSource = try await QAMoveQA.state(source)
                let afterDestination = try await QAMoveQA.state(destination)
                #expect(afterSource.exists == beforeSource.exists)
                #expect(afterDestination.exists == beforeDestination.exists)
                let destinationAfterRecreate = try await QAMoveQA.folder(store, path: destination)
                #expect(destinationAfterRecreate != nil)
                let stranded = try await QAMoveQA.fetchAdded(mailbox: destination, after: beforeDestination.uidNext, keys: keys)
                #expect(stranded.isEmpty, "deleted destination received queued messages")
                try await QAMoveQA.assertIntegrity(store, dir: dir, label: "destination-delete")
            } catch {
                await engine.stop()
                throw error
            }
            await engine.stop()
        }
    }

    @Test(.enabled(if: QAMoveQA.enabled))
    func liveUIDValidityBumpDropsStaleMoveQueue() async throws {
        try QAMoveQA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAMoveQA.probe()
        let source = "QAMove-UVSrc-\(UUID().uuidString.prefix(8))"
        let destination = "QAMove-UVDst-\(UUID().uuidString.prefix(8))"
        defer { QAMoveQA.deleteFixture(source, destination) }
        try QAMoveQA.createOrDelete("create", mailboxes: [source, destination])
        try QAMoveQA.append(25, to: source)

        try await QAMoveQA.withQAMoveStore { store, dir in
            let engine = QAMoveQA.engine(store: store, dir: dir)
            await engine.start()
            do {
                let sourceFolder = try await QAMoveQA.waitForFolder(store, path: source, count: 25)
                let destinationFolder = try await QAMoveQA.requireFolder(store, path: destination)
                let generation = try #require(await store.liveGeneration(for: sourceFolder.id))
                let selected = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 25)
                let beforeDestination = try await QAMoveQA.state(destination)

                // Queue against the discovered generation, then bump it while
                // the engine is stopped. Restarting must drop the stale rows
                // and discover the replacement generation immediately.
                await engine.stop()
                try await store.enqueueMove(messages: selected.map(\.id), to: destinationFolder.id)
                _ = try QAMoveQA.chaos("uidvalidity", source)
                await engine.start()
                try await waitUntil(timeout: .seconds(60), poll: .milliseconds(350)) {
                    guard let live = try await store.liveGeneration(for: sourceFolder.id) else { return false }
                    let pending = try await store.snapshotMoveQueue()
                    return live.uidValidity != generation.uidValidity && pending.isEmpty
                }
                let afterSource = try await QAMoveQA.state(source)
                let afterDestination = try await QAMoveQA.state(destination)
                #expect(afterSource.exists == 25)
                #expect(afterDestination.exists == beforeDestination.exists)
                #expect((try await store.snapshotMoveQueue()).isEmpty)
                let _ = try await QAMoveQA.waitForFolder(store, path: source, count: 25)
                try await QAMoveQA.assertIntegrity(store, dir: dir, label: "uidvalidity-stale-queue")
            } catch {
                await engine.stop()
                throw error
            }
            await engine.stop()
        }
    }

    @Test(.enabled(if: QAMoveQA.enabled))
    func liveStopRestartResumesMoveQueueWithoutDuplicates() async throws {
        try QAMoveQA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAMoveQA.probe()
        let source = "QAMove-StopSrc-\(UUID().uuidString.prefix(8))"
        let destination = "QAMove-StopDst-\(UUID().uuidString.prefix(8))"
        defer { QAMoveQA.deleteFixture(source, destination) }
        try QAMoveQA.createOrDelete("create", mailboxes: [source, destination])
        try QAMoveQA.append(100, to: source)

        try await QAMoveQA.withQAMoveStore { store, dir in
            let engine = QAMoveQA.engine(store: store, dir: dir)
            await engine.start()
            do {
                let sourceFolder = try await QAMoveQA.waitForFolder(store, path: source, count: 100)
                let destinationFolder = try await QAMoveQA.requireFolder(store, path: destination)
                let selected = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 100)
                let beforeDestination = try await QAMoveQA.state(destination)
                try await store.enqueueMove(messages: selected.map(\.id), to: destinationFolder.id)
                let stopping = Task { await engine.stop() }
                try await Task.sleep(for: .milliseconds(25))
                let pendingAtStop = try await store.snapshotMoveQueue().count
                await stopping.value
                print("MAILTERNAL_QA move stop mid-drain pending=\(pendingAtStop)")
                await engine.start()
                try await waitUntil(timeout: .seconds(180), poll: .milliseconds(250)) {
                    try await store.snapshotMoveQueue().isEmpty
                }
                let afterDestination = try await QAMoveQA.state(destination)
                #expect(afterDestination.exists == beforeDestination.exists + 100)
                let moved = try await QAMoveQA.fetchAdded(mailbox: destination, after: beforeDestination.uidNext)
                #expect(moved.count == 100, "restart created duplicate destination messages")
                try await QAMoveQA.assertIntegrity(store, dir: dir, label: "stop-restart")

                await engine.stop()
                try await QAMoveQA.directRestore(
                    mailbox: destination,
                    to: source,
                    after: beforeDestination.uidNext,
                    keys: Set(moved.map(\.key))
                )
            } catch {
                await engine.stop()
                throw error
            }
        }
    }

    @Test(.enabled(if: QAMoveQA.enabled))
    func liveFlagUnflagUnreadBurstsWithConcurrentDelivery() async throws {
        try QAMoveQA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QAMoveQA.probe()
        let source = "QAMove-FlagSrc-\(UUID().uuidString.prefix(8))"
        let destination = "QAMove-FlagDst-\(UUID().uuidString.prefix(8))"
        defer { QAMoveQA.deleteFixture(source, destination) }
        try QAMoveQA.createOrDelete("create", mailboxes: [source, destination])
        try QAMoveQA.append(100, to: source)

        try await QAMoveQA.withQAMoveStore { store, dir in
            let engine = QAMoveQA.engine(store: store, dir: dir)
            await engine.start()
            do {
                let sourceFolder = try await QAMoveQA.waitForFolder(store, path: source, count: 100)
                let selected = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 100)
                try #require(selected.count == 100)
                let ids = selected.map(\.id)
                let baselineRead = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.isRead) })
                let baselineFlagged = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.isFlagged) })
                let delivery = Task { () throws -> String in
                    try QAMoveQA.chaos("deliver", "100", source)
                }

                try await store.enqueueFlag(messages: ids, flag: .flagged, set: true)
                try await waitUntil(timeout: .seconds(90), poll: .milliseconds(200)) {
                    try await store.snapshotFlagQueue().isEmpty
                }
                try await store.enqueueFlag(messages: ids, flag: .flagged, set: false)
                try await waitUntil(timeout: .seconds(90), poll: .milliseconds(200)) {
                    try await store.snapshotFlagQueue().isEmpty
                }
                try await store.enqueueFlag(messages: ids, flag: .seen, set: false)
                try await waitUntil(timeout: .seconds(90), poll: .milliseconds(200)) {
                    try await store.snapshotFlagQueue().isEmpty
                }
                _ = try await delivery.value
                try await store.enqueueFlag(
                    messages: ids.filter { baselineRead[$0] == true },
                    flag: .seen,
                    set: true
                )
                try await store.enqueueFlag(
                    messages: ids.filter { baselineRead[$0] == false },
                    flag: .seen,
                    set: false
                )
                try await store.enqueueFlag(
                    messages: ids.filter { baselineFlagged[$0] == true },
                    flag: .flagged,
                    set: true
                )
                try await store.enqueueFlag(
                    messages: ids.filter { baselineFlagged[$0] == false },
                    flag: .flagged,
                    set: false
                )
                try await waitUntil(timeout: .seconds(90), poll: .milliseconds(200)) {
                    try await store.snapshotFlagQueue().isEmpty
                }
                await engine.refreshNow()
                let _ = try await QAMoveQA.waitForFolder(store, path: source, count: 200)
                let final = try await QAMoveQA.localMessages(store, folder: sourceFolder.id, limit: 200)
                let finalByID = Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0) })
                #expect(final.count == 200)
                for selectedRow in selected {
                    let row = try #require(finalByID[selectedRow.id])
                    if let expected = baselineRead[selectedRow.id] {
                        #expect(row.isRead == expected)
                    }
                    if let expected = baselineFlagged[selectedRow.id] {
                        #expect(row.isFlagged == expected)
                    }
                }
                try await QAMoveQA.assertIntegrity(store, dir: dir, label: "flag-bursts")
            } catch {
                await engine.stop()
                throw error
            }
            await engine.stop()
        }
    }
}
#endif
