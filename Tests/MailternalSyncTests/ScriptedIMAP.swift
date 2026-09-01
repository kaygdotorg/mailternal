import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
@testable import MailternalSync

final class ScriptedWorld: @unchecked Sendable {
    let lock = NSLock()
    var capabilities: IMAPCapabilities
    var folders: [IMAPMailbox]
    var mailboxes: [String: ScriptedMailbox]
    var failQResync = false
    var failSelect: Error?
    var storeSeenError: Error?
    var storedSeen: [UInt32] = []
    var isGmail = false
    var fetchNanos: UInt64 = 0

    init(
        capabilities: IMAPCapabilities,
        folders: [IMAPMailbox],
        mailboxes: [String: ScriptedMailbox]
    ) {
        self.capabilities = capabilities
        self.folders = folders
        self.mailboxes = mailboxes
    }

    func snapshotCapabilities() -> IMAPCapabilities {
        lock.lock()
        defer { lock.unlock() }
        return capabilities
    }

    func discovery() -> (folders: [IMAPMailbox], isGmail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (folders, isGmail)
    }

    func qresyncShouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failQResync
    }

    func selectFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failSelect
    }

    func seenError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storeSeenError
    }

    func mailbox(_ path: String) -> ScriptedMailbox {
        lock.lock()
        defer { lock.unlock() }
        if let existing = mailboxes[path] { return existing }
        let created = ScriptedMailbox(path: path)
        mailboxes[path] = created
        return created
    }

    func seenUIDs() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return storedSeen
    }

    func updateMailbox(_ path: String, _ body: (inout ScriptedMailbox) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var box = mailboxes[path] ?? ScriptedMailbox(path: path)
        body(&box)
        mailboxes[path] = box
    }

    func applyStoreSeen(path: String, uids: IMAPUIDSet) {
        lock.lock()
        defer { lock.unlock() }
        guard var box = mailboxes[path] else { return }
        for (uid, var message) in box.messages {
            if SyncPolicy.contains(uids, uid: uid) {
                if !message.flags.contains(where: { $0.lowercased().contains("seen") }) {
                    message.flags.append("\\Seen")
                }
                box.messages[uid] = message
                storedSeen.append(uid)
            }
        }
        mailboxes[path] = box
    }

    func fetchSleepNanos() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return fetchNanos
    }
}

struct ScriptedMessage: Sendable {
    var uid: UInt32
    var flags: [String]
    var internalDate: Date
    var envelope: IMAPEnvelope
    var structure: IMAPBodyStructure
    var header: Data
    var parts: [String: Data]
    var modSeq: UInt64
}

struct ScriptedMailbox: Sendable {
    var path: String
    var uidValidity: UInt32 = 1
    var uidNext: UInt32 = 1
    var highestModSeq: UInt64? = 10
    var noModSeq = false
    var vanishedEarlier: [UInt32] = []
    var vanished: [UInt32] = []
    var messages: [UInt32: ScriptedMessage] = [:]

    var exists: Int { messages.count }
}

actor ScriptedIMAPClient: IMAPClient {
    let world: ScriptedWorld
    let connectError: Error?
    private var connected = false
    private var selectedPath: String?
    private let eventStream: AsyncStream<IMAPMailboxEvent>
    private let eventContinuation: AsyncStream<IMAPMailboxEvent>.Continuation
    private var idleContinuation: AsyncStream<IMAPMailboxEvent>.Continuation?

    init(world: ScriptedWorld, connectError: Error? = nil) {
        self.world = world
        self.connectError = connectError
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    nonisolated var events: AsyncStream<IMAPMailboxEvent> { eventStream }

    func emit(_ event: IMAPMailboxEvent) {
        eventContinuation.yield(event)
        idleContinuation?.yield(event)
    }

    func capabilities() async -> IMAPCapabilities { world.snapshotCapabilities() }
    func selectedMailbox() async -> IMAPSelectedMailbox? {
        guard let selectedPath else { return nil }
        return makeSelected(world.mailbox(selectedPath), name: selectedPath)
    }

    func connect() async throws {
        if let connectError { throw connectError }
        connected = true
    }

    func close() async {
        connected = false
        idleContinuation?.finish()
        idleContinuation = nil
        eventContinuation.finish()
    }

    func listFolders() async throws -> IMAPFolderDiscovery {
        let discovery = world.discovery()
        return IMAPFolderDiscovery(folders: discovery.folders, isGmail: discovery.isGmail)
    }

    func select(_ mailbox: String, qresync: IMAPQResyncSelect?) async throws -> IMAPSelectedMailbox {
        if let fail = world.selectFailure() { throw fail }
        if qresync != nil, world.qresyncShouldFail() {
            throw IMAPError.taggedBAD(tag: "t", message: "QRESYNC failed", code: nil)
        }
        selectedPath = mailbox
        return makeSelected(world.mailbox(mailbox), name: mailbox)
    }

    func enableQResync() async throws {
        if world.qresyncShouldFail() {
            throw IMAPError.taggedBAD(tag: "t", message: "ENABLE QRESYNC failed", code: nil)
        }
    }

    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        let delay = world.fetchSleepNanos()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        guard let selectedPath else { return [] }
        let box = world.mailbox(selectedPath)
        var results: [IMAPFetchedMessage] = []
        for (uid, message) in box.messages.sorted(by: { $0.key < $1.key }) {
            if !SyncPolicy.contains(request.uids, uid: uid) { continue }
            if let changed = request.changedSince, message.modSeq <= changed { continue }
            var parts: [IMAPPeekedPart] = []
            for peek in request.peek {
                let spec = peek.specifier
                if spec.uppercased() == "HEADER" {
                    parts.append(IMAPPeekedPart(specifier: "HEADER", binary: false, data: message.header))
                } else if spec.isEmpty {
                    let body = message.parts["1"] ?? Data()
                    var full = message.header
                    if full.suffix(4) != Data("\r\n\r\n".utf8) {
                        full.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
                    }
                    full.append(body)
                    let capped: Data
                    if let origin = peek.origin, let length = peek.length {
                        let start = min(origin, full.count)
                        capped = Data(full.dropFirst(start).prefix(length))
                    } else {
                        capped = full
                    }
                    parts.append(IMAPPeekedPart(specifier: "", binary: false, data: capped))
                } else if let data = message.parts[spec] ?? (spec == "1" ? message.parts["TEXT"] : nil) {
                    parts.append(IMAPPeekedPart(specifier: spec, binary: false, data: data))
                }
            }
            results.append(IMAPFetchedMessage(
                uid: uid,
                sequence: uid,
                flags: message.flags,
                internalDate: message.internalDate,
                envelope: request.envelope ? message.envelope : nil,
                bodyStructure: request.bodyStructure ? message.structure : nil,
                rfc822Size: nil,
                modSeq: request.modSeq ? message.modSeq : nil,
                parts: parts
            ))
        }
        return results
    }

    func storeSeen(uids: IMAPUIDSet) async throws {
        if let error = world.seenError() { throw error }
        guard let selectedPath else { return }
        world.applyStoreSeen(path: selectedPath, uids: uids)
    }

    func beginIdle() async throws -> IMAPIdle {
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        let stream = AsyncStream<IMAPMailboxEvent> { continuation = $0 }
        idleContinuation = continuation
        return IMAPIdle(events: stream)
    }

    func endIdle() async throws {
        idleContinuation?.finish()
        idleContinuation = nil
    }

    func renewIdle() async throws -> IMAPIdle {
        try await endIdle()
        return try await beginIdle()
    }

    private func makeSelected(_ box: ScriptedMailbox, name: String) -> IMAPSelectedMailbox {
        IMAPSelectedMailbox(
            name: name,
            exists: box.exists,
            uidValidity: box.uidValidity,
            uidNext: box.uidNext,
            highestModSeq: box.highestModSeq,
            noModSeq: box.noModSeq,
            mailboxID: nil,
            flags: ["\\Seen", "\\Flagged"],
            vanishedEarlier: box.vanishedEarlier,
            vanished: box.vanished,
            isReadWrite: true
        )
    }
}

final class ScriptedFactory: IMAPClientFactory, @unchecked Sendable {
    let world: ScriptedWorld
    let secondConnectError: Error?
    private let lock = NSLock()
    private var count = 0
    private(set) var clients: [ScriptedIMAPClient] = []

    init(world: ScriptedWorld, secondConnectError: Error? = nil) {
        self.world = world
        self.secondConnectError = secondConnectError
    }

    func makeClient(endpoint: IMAPEndpoint, username: String, password: String) -> any IMAPClient {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        let error = count >= 2 ? secondConnectError : nil
        let client = ScriptedIMAPClient(world: world, connectError: error)
        clients.append(client)
        return client
    }
}

struct StaticPassword: IMAPCredentialProvider {
    var value: String
    func password(for account: AccountID) async throws -> String { value }
}

struct FixedDisk: DiskSpaceProviding {
    var freeBytes: Int64
    var volumeBytes: Int64
    func snapshot(for url: URL) -> DiskSnapshot {
        DiskSnapshot(freeBytes: freeBytes, volumeBytes: volumeBytes)
    }
}

func makePlainMessage(
    uid: UInt32,
    subject: String,
    from: String = "alice@example.com",
    body: String = "hello",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    flags: [String] = [],
    modSeq: UInt64 = 5
) -> ScriptedMessage {
    let envelope = IMAPEnvelope(
        date: nil,
        subject: subject,
        from: [IMAPAddress(displayName: "Alice", mailbox: "alice", host: "example.com")],
        sender: [],
        replyTo: [],
        to: [IMAPAddress(displayName: nil, mailbox: "qa", host: "mailternal.test")],
        cc: [],
        bcc: [],
        inReplyTo: nil,
        messageID: "<\(uid)@example.com>"
    )
    let structure = IMAPBodyStructure(
        partSpecifier: "",
        type: "text",
        subtype: "plain",
        encoding: "7bit",
        octetCount: body.utf8.count,
        charset: "utf-8",
        filename: nil,
        contentID: nil,
        children: []
    )
    let header = Data("From: Alice <alice@example.com>\r\nSubject: \(subject)\r\nMessage-ID: <\(uid)@example.com>\r\n\r\n".utf8)
    return ScriptedMessage(
        uid: uid,
        flags: flags,
        internalDate: date,
        envelope: envelope,
        structure: structure,
        header: header,
        parts: ["1": Data(body.utf8)],
        modSeq: modSeq
    )
}

func qresyncCaps() -> IMAPCapabilities {
    IMAPCapabilities(tokens: [
        "IMAP4REV1", "IDLE", "QRESYNC", "CONDSTORE", "ENABLE", "STARTTLS", "AUTH=PLAIN",
    ])
}

func basicCaps() -> IMAPCapabilities {
    IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE"])
}

func inboxMailbox() -> IMAPMailbox {
    IMAPMailbox(path: "INBOX", name: "INBOX", separator: "/", role: .inbox, mailboxID: nil, attributes: [])
}

func testSettings(dir: URL, window: UInt32 = 2) -> SyncSettings {
    SyncSettings(
        backfillWindowSize: window,
        idleRenewal: .seconds(3600),
        hintDebounce: .milliseconds(1),
        specialUseDelta: .seconds(3600),
        otherFolderDelta: .seconds(3600),
        seenPoll: .milliseconds(20),
        setupSampleSize: 1000,
        windowedDays: 30,
        diskURL: dir
    )
}

func withSyncStore(_ body: (MailStore, URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailternal-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try MailStore(
        databaseURL: dir.appendingPathComponent("mail.sqlite"),
        cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
    )
    try await body(store, dir)
}

func sampleConfig() -> AccountConfig {
    AccountConfig(
        id: AccountID(rawValue: "qa"),
        displayName: "QA",
        emailAddress: "qa@mailternal.test",
        username: "qa@mailternal.test",
        imap: IMAPEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS)
    )
}

func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(20),
    _ predicate: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: poll)
    }
    throw WaitTimeout()
}

struct WaitTimeout: Error {}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NewMailEvent] = []
    func append(_ event: NewMailEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    func snapshot() -> [NewMailEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
