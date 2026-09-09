import Foundation
import MailternalInterfaces
import NIO
import NIOIMAP
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// IMAP session actor: TLS/auth/capabilities, LIST discovery, PEEK fetch,
/// UID STORE `\Seen`, archive MOVE/COPY/STORE/EXPUNGE, IDLE, and
/// QRESYNC/CONDSTORE/basic delta primitives.
///
/// Wave-2's sync engine owns policy (which path, when to IDLE, backoff). This
/// type is the wire. A non-peek body fetch cannot be expressed — ``IMAPFetchRequest``
/// only carries ``IMAPPeekSection``.
public actor IMAPSession {
    /// Current advertised capabilities. Empty before ``connect()``. Replaced after
    /// STARTTLS and after AUTH (spec: product.md Transport).
    public private(set) var capabilities: IMAPCapabilities = .none

    /// The mailbox last selected on this connection, if any.
    public private(set) var selected: IMAPSelectedMailbox?

    /// Untagged EXISTS / EXPUNGE / FETCH / VANISHED / BYE for the life of the session.
    public nonisolated var events: AsyncStream<IMAPMailboxEvent> { eventStream }

    /// Best delta path advertised by the server. The engine still downgrades per
    /// folder on tagged `BAD`/`NO`/`NOMODSEQ` (spec: sync.md Change detection).
    public var recommendedDeltaPath: IMAPDeltaPath { capabilities.recommendedDeltaPath }

    private static let defaultEventLoopGroup: EventLoopGroup = {
        // A bounded process-wide pool avoids one NIO thread per account/session.
        // It intentionally has no per-session shutdown path.
        MultiThreadedEventLoopGroup(numberOfThreads: 4)
    }()

    private let endpoint: IMAPEndpoint
    private let username: String
    private let password: String
    private let group: EventLoopGroup
    private var connection: IMAPConnection?
    private var tagCounter: UInt64 = 0
    private var readerTask: Task<Void, Never>?
    private var qresyncEnabled = false
    private var didGreet = false
    private var authenticated = false
    private var idleActive = false
    private var idleTag: String?
    private var idleEvents: AsyncStream<IMAPMailboxEvent>.Continuation?
    private var fetchAssembler = IMAPFetchAssembler()
    private var fetchInFlight = false
    private var taggedWaiter: (tag: String, continuation: CheckedContinuation<TaggedResponse, Error>)?
    private var appendDeadline: (tag: String, timer: Scheduled<Void>)?
    private var greetingWaiter: CheckedContinuation<ResponsePayload, Error>?
    private var greetingPayload: ResponsePayload?
    private var idleStartWaiter: CheckedContinuation<Void, Error>?
    private var pendingAuthPlain: ByteBuffer?
    private var untaggedCollector: ((ResponsePayload) -> Void)?
    private var closed = false
    private let eventStream: AsyncStream<IMAPMailboxEvent>
    private let eventContinuation: AsyncStream<IMAPMailboxEvent>.Continuation

    /// Opens a session against `endpoint`. Call ``connect()`` to run greeting, TLS, and AUTH.
    ///
    /// - Parameters:
    ///   - endpoint: Host, port, and implicit-TLS vs mandatory STARTTLS.
    ///   - username: AUTH/LOGIN identity.
    ///   - password: AUTH/LOGIN secret. Never logged.
    ///   - eventLoopGroup: Injected NIO group. When `nil`, sessions share a
    ///     bounded four-thread process-wide group; neither path is shut down by
    ///     the session.
    public init(
        endpoint: IMAPEndpoint,
        username: String,
        password: String,
        eventLoopGroup: EventLoopGroup? = nil
    ) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.group = eventLoopGroup ?? Self.defaultEventLoopGroup
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    /// Test / in-memory seam: the channel is already pipelined with
    /// `IMAPClientHandler` + a `Response` collector.
    init(
        endpoint: IMAPEndpoint,
        username: String,
        password: String,
        connection: IMAPConnection,
        eventLoopGroup: EventLoopGroup
    ) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.group = eventLoopGroup
        self.connection = connection
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        if let waiter = taggedWaiter {
            waiter.continuation.resume(throwing: IMAPError.transport("Session deallocated"))
        }
        if let waiter = greetingWaiter {
            waiter.resume(throwing: IMAPError.transport("Session deallocated"))
        }
        if let waiter = idleStartWaiter {
            waiter.resume(throwing: IMAPError.transport("Session deallocated"))
        }
        eventContinuation.finish()
        readerTask?.cancel()
    }
}

extension IMAPSession {
    /// Greeting, mandatory TLS (implicit or STARTTLS), LOGIN or AUTH=PLAIN, then
    /// a post-auth CAPABILITY. Refuses to authenticate on a non-TLS connection.
    public func connect() async throws {
        try ensureOpen()
        if connection == nil {
            do {
                connection = try await IMAPNetwork.connect(endpoint: endpoint, group: group)
            } catch let error as IMAPError {
                throw error
            } catch {
                throw IMAPError.transport(String(describing: error))
            }
        }
        startReader()
        if let connection {
            do {
                try await connection.startReading()
            } catch {
                throw IMAPError.transport(String(describing: error))
            }
        }
        try await runConnectSequence()
        authenticated = true
    }

    /// Close the channel. Idempotent. Drops the socket without DONE/LOGOUT so
    /// NIOIMAP cannot fatal on a tagged command while IDLE, and stop() cannot
    /// pin on a stuck write.
    public func close() async {
        let alreadyClosed = closed
        closed = true
        idleActive = false
        idleTag = nil
        idleEvents?.finish()
        idleEvents = nil
        if !alreadyClosed {
            failWaiters(IMAPError.transport("Connection closed"))
        }
        clearFetchState()
        // Drop the socket. Do not write DONE/LOGOUT: NIOIMAP fatals on tagged
        // commands while IDLE, and a stuck write would pin stop().
        let conn = connection
        connection = nil
        // `IMAPConnection.close()` finishes the response producer before
        // closing the socket, allowing a live reader to drain buffered values
        // instead of abandoning them. The process-wide event-loop group is
        // intentionally never shut down by a session.
        eventContinuation.finish()
        await conn?.close()
    }

    /// `LIST` all folders, skip `\Noselect`/`\NonExistent`, map SPECIAL-USE with
    /// name-heuristic fallback, capture MAILBOXID when advertised, and expose
    /// Gmail's capability/host detection to callers.
    public func listFolders() async throws -> IMAPFolderDiscovery {
        try ensureAuthenticated()
        var returnOptions: [ReturnOption] = []
        if capabilities.specialUse {
            returnOptions.append(.specialUse)
        }
        if capabilities.objectID && capabilities.listStatus {
            returnOptions.append(.statusOption([.mailboxID]))
        }
        let command = Command.list(
            nil,
            reference: MailboxName(ByteBuffer(string: "")),
            .pattern([ByteBuffer(string: "*")]),
            returnOptions
        )
        var listed: [MailboxInfo] = []
        var statusIDs: [String: String] = [:]
        let tagged = try await send(command) { payload in
            if case .mailboxData(.list(let info)) = payload {
                listed.append(info)
            }
            if case .mailboxData(.status(let mailbox, let status)) = payload {
                if let id = status.mailboxID {
                    statusIDs[mailbox.debugDescription] = mailboxIDString(id)
                }
            }
        }
        try throwIfFailed(tagged)

        var folders: [IMAPMailbox] = []
        folders.reserveCapacity(listed.count)
        for info in listed {
            if info.hasEffectiveAttribute(.noSelect) || info.hasEffectiveAttribute(.nonExistent) {
                continue
            }
            let components = info.path.displayStringComponents()
            let separator = info.path.pathSeparator
            let path = components.joined(separator: separator.map(String.init) ?? "/")
            let rawName = components.last ?? path
            let name = IMAPRoleMapping.displayName(path: path, name: rawName)
            let id = statusIDs[info.path.name.debugDescription]
            let role = IMAPRoleMapping.role(path: path, name: rawName, attributes: info.attributes)
            folders.append(IMAPMailbox(
                path: path.isEmpty ? rawName : path,
                name: name,
                separator: separator,
                role: role,
                mailboxID: id,
                attributes: info.attributes.map { String($0) }
            ))
        }

        let gmail = capabilities.gmailExtensions || IMAPRoleMapping.isGmailHost(endpoint.host)
        return IMAPFolderDiscovery(folders: folders, isGmail: gmail)
    }

    /// `SELECT` a mailbox. When `qresync` is non-nil and the server advertised
    /// QRESYNC, issues `ENABLE QRESYNC` first (if needed) and passes QRESYNC parameters.
    public func select(_ mailbox: String, qresync: IMAPQResyncSelect? = nil) async throws -> IMAPSelectedMailbox {
        try ensureAuthenticated()
        if qresync != nil, capabilities.qresync, !qresyncEnabled {
            try await enableQResync()
        }
        var parameters: [SelectParameter] = []
        if let qresync, qresyncEnabled {
            let known = qresync.knownUIDs.flatMap { IMAPCommandFactory.uidSet($0) }
            guard let uidValidity = UIDValidity(exactly: qresync.uidValidity) else {
                throw IMAPError.parse("UIDVALIDITY must be greater than 0")
            }
            parameters.append(.qresync(QResyncParameter(
                uidValidity: uidValidity,
                modificationSequenceValue: ModificationSequenceValue(qresync.modificationSequence),
                knownUIDs: known,
                sequenceMatchData: nil
            )))
        }
        selected = IMAPSelectedMailbox(
            name: mailbox,
            exists: 0,
            uidValidity: 0,
            uidNext: nil,
            highestModSeq: nil,
            noModSeq: false,
            mailboxID: nil,
            flags: [],
            vanishedEarlier: [],
            vanished: [],
            isReadWrite: true
        )
        let tagged = try await send(
            .select(MailboxName(ByteBuffer(string: mailbox)), parameters)
        )
        try throwIfFailed(tagged)
        applyTaggedState(tagged.state)
        guard let selected else {
            throw IMAPError.parse("SELECT succeeded without mailbox state")
        }
        return selected
    }
    /// `ENABLE QRESYNC`. Safe to call more than once. Surfaces tagged NO/BAD so
    /// the engine can downgrade the folder. A tagged `OK` alone is not enough:
    /// the server must also return an `ENABLED QRESYNC` response.
    public func enableQResync() async throws {
        try ensureAuthenticated()
        guard capabilities.qresync else {
            throw IMAPError.taggedBAD(
                tag: "",
                message: "QRESYNC is not advertised",
                code: nil
            )
        }
        let enabled = try await enable(tokens: ["QRESYNC"])
        guard enabled.contains(where: { $0.uppercased() == "QRESYNC" }) else {
            throw IMAPError.taggedBAD(
                tag: "",
                message: "ENABLE completed without QRESYNC confirmation",
                code: nil
            )
        }
        qresyncEnabled = true
    }

    /// `ENABLE` the listed capability tokens. Returns the server's ENABLED list.
    /// Tagged NO/BAD throw so the engine can downgrade (spec: sync.md Change detection).
    public func enable(tokens: [String]) async throws -> [String] {
        try ensureAuthenticated()
        var enabled: [Capability] = []
        let tagged = try await send(.enable(tokens.map { Capability($0) })) { payload in
            if case .enableData(let list) = payload {
                enabled.append(contentsOf: list)
            }
        }
        try throwIfFailed(tagged)
        return enabled.map { String($0) }
    }

    /// UID FETCH. Body items are always PEEK. Empty UID sets return `[]`.
    /// Encoded PEEK literals are accounted for before they enter either the
    /// response producer or assembler; the request's cap is clamped to the
    /// transport's 32 MiB ceiling and failures throw
    /// ``IMAPError/responseTooLarge(limit:)``.
    public func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        try ensureAuthenticated()
        guard !request.uids.isEmpty else { return [] }
        guard let set = IMAPCommandFactory.uidSet(request.uids),
              let command = Command.uidFetch(
                messages: set,
                attributes: IMAPCommandFactory.fetchAttributes(request),
                modifiers: IMAPCommandFactory.fetchModifiers(request)
              )
        else { return [] }
        guard let connection else {
            throw IMAPError.transport("Not connected")
        }
        let maximumResponseBytes = min(
            IMAPFetchAssembler.maximumLiteralBytes,
            max(0, request.maximumResponseBytes ?? IMAPFetchAssembler.maximumLiteralBytes)
        )
        fetchAssembler = IMAPFetchAssembler(maximumLiteralBytes: maximumResponseBytes)
        fetchInFlight = true
        connection.beginFetchResponse(maximumBytes: maximumResponseBytes)
        defer {
            fetchInFlight = false
            fetchAssembler = IMAPFetchAssembler()
            connection.endFetchResponse()
        }
        let tagged = try await send(command)
        try throwIfFailed(tagged)
        return fetchAssembler.take()
    }

    /// `UID STORE <uids> +/-FLAGS.SILENT (\Seen|\Flagged)`. Only tagged `OK`
    /// is success.
    public func storeFlags(uids: IMAPUIDSet, flag: FlagKind, set: Bool) async throws {
        try ensureAuthenticated()
        guard let uidSet = IMAPCommandFactory.uidSet(uids),
              let command = Command.uidStore(
                messages: uidSet,
                modifiers: [],
                data: .flags(set
                    ? .add(silent: true, list: [flag == .seen ? .seen : .flagged])
                    : .remove(silent: true, list: [flag == .seen ? .seen : .flagged]))
              )
        else { return }
        let tagged = try await send(command)
        try throwIfFailed(tagged)
    }

    public func storeSeen(uids: IMAPUIDSet) async throws {
        try await storeFlags(uids: uids, flag: .seen, set: true)
    }
 

    /// Renames an IMAP mailbox. The tagged response is authoritative: only
    /// tagged `OK` returns; `NO`/`BAD` are surfaced to the sync queue.
    public func renameMailbox(from source: String, to destination: String) async throws {
        try ensureAuthenticated()
        let tagged = try await send(
            .rename(
                from: MailboxName(ByteBuffer(string: source)),
                to: MailboxName(ByteBuffer(string: destination)),
                parameters: [:]
            )
        )
        try throwIfFailed(tagged)
        if var selected, selected.name == source {
            selected.name = destination
            self.selected = selected
        }
    }
    /// `UID MOVE <uids> <mailbox>`. Returns exact COPYUID identity when supplied;
    /// nil still means tagged success, not permission to retry the mutation.
    @discardableResult
    public func move(uids: IMAPUIDSet, to mailbox: String) async throws -> IMAPCopyUIDMapping? {
        try ensureAuthenticated()
        guard let set = IMAPCommandFactory.uidSet(uids),
              let command = Command.uidMove(
                messages: set,
                mailbox: MailboxName(ByteBuffer(string: mailbox))
              )
        else { return nil }
        return try await sendCopyOrMove(command)
    }

    /// `UID COPY <uids> <mailbox>`. Returns exact COPYUID identity when supplied;
    /// missing identity must never be guessed from message headers.
    @discardableResult
    public func copy(uids: IMAPUIDSet, to mailbox: String) async throws -> IMAPCopyUIDMapping? {
        try ensureAuthenticated()
        guard let set = IMAPCommandFactory.uidSet(uids),
              let command = Command.uidCopy(
                messages: set,
                mailbox: MailboxName(ByteBuffer(string: mailbox))
              )
        else { return nil }
        return try await sendCopyOrMove(command)
    }

    private func sendCopyOrMove(_ command: Command) async throws -> IMAPCopyUIDMapping? {
        var copyCode: ResponseCodeCopy?
        var conflictingCodes = false
        let tagged = try await send(command) { payload in
            guard case .conditionalState(.ok(let text)) = payload,
                  case .uidCopy(let code)? = text.code
            else { return }
            if let previous = copyCode, previous != code { conflictingCodes = true }
            copyCode = code
        }
        try throwIfFailed(tagged)
        if case .ok(let text) = tagged.state, case .uidCopy(let code)? = text.code {
            if let previous = copyCode, previous != code { conflictingCodes = true }
            copyCode = code
        }
        guard !conflictingCodes, let copyCode else { return nil }
        return IMAPCopyUIDMapping(
            destinationUIDValidity: UInt32(copyCode.destinationUIDValidity),
            sourceUIDs: copyCode.sourceUIDs.map { $0.lowerBound.rawValue...$0.upperBound.rawValue },
            destinationUIDs: copyCode.destinationUIDs.map { $0.lowerBound.rawValue...$0.upperBound.rawValue }
        )
    }

    /// `UID STORE <uids> +FLAGS.SILENT (\Deleted)`. Only tagged `OK` is success.
    public func storeDeleted(uids: IMAPUIDSet) async throws {
        try ensureAuthenticated()
        guard let set = IMAPCommandFactory.uidSet(uids),
              let command = Command.uidStore(
                messages: set,
                modifiers: [],
                data: .flags(.add(silent: true, list: [.deleted]))
              )
        else { return }
        let tagged = try await send(command)
        try throwIfFailed(tagged)
    }

    /// `UID EXPUNGE <uids>`. Only tagged `OK` is success.
    public func expunge(uids: IMAPUIDSet) async throws {
        try ensureAuthenticated()
        guard let set = IMAPCommandFactory.uidSet(uids),
              let command = Command.uidExpunge(
                messages: set,
                mailbox: MailboxName(ByteBuffer(string: ""))
              )
        else { return }
        let tagged = try await send(command)
        try throwIfFailed(tagged)
    }

    /// Enter IDLE. Returns a stream of untagged hints. Caller must ``endIdle()``
    /// or ``renewIdle()``; the session does not start a timer.
    public func beginIdle() async throws -> IMAPIdle {
        try ensureAuthenticated()
        guard capabilities.idle else {
            throw IMAPError.taggedBAD(tag: "", message: "IDLE is not advertised", code: nil)
        }
        guard !idleActive else {
            throw IMAPError.transport("IDLE is already active")
        }
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        let stream = AsyncStream<IMAPMailboxEvent> { continuation = $0 }
        idleEvents = continuation
        idleActive = true
        let tag = nextTag()
        idleTag = tag
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.idleStartWaiter = cont
                    Task {
                        do {
                            try await self.sendRaw(.tagged(TaggedCommand(tag: tag, command: .idleStart)))
                        } catch {
                            self.failIdleStart(error)
                        }
                    }
                }
            } onCancel: {
                Task { await self.failIdleStart(CancellationError()) }
            }
        } catch {
            finishIdle()
            throw error
        }
        return IMAPIdle(events: stream)
    }

    /// Send `DONE` and wait for the IDLE tagged OK. Finishes the idle event stream.
    public func endIdle() async throws {
        guard idleActive else { return }
        let tag = idleTag
        try await sendRaw(.idleDone)
        if let tag {
            let tagged = try await waitForTagged(tag)
            try throwIfFailed(tagged)
        }
        finishIdle()
    }

    /// Caller-driven IDLE renewal (spec: sync.md, default 25 minutes): `DONE`,
    /// then a fresh `IDLE`. Returns the new event stream.
    public func renewIdle() async throws -> IMAPIdle {
        try await endIdle()
        return try await beginIdle()
    }
}

extension IMAPSession {
    func runConnectSequence() async throws {
        let greeting = try await waitForGreeting()
        applyPayload(greeting)
        let preauthenticated: Bool
        switch greeting {
        case .conditionalState(.bye(let text)):
            throw IMAPError.transport(text.text)
        case .conditionalState(.preauth):
            preauthenticated = true
        default:
            preauthenticated = false
        }

        try await refreshCapabilities()

        switch endpoint.security {
        case .startTLS:
            guard capabilities.startTLS else {
                throw IMAPError.tls("STARTTLS is not advertised; refusing plaintext")
            }
            let tagged = try await send(.startTLS)
            switch tagged.state {
            case .ok:
                break
            case .no(let text), .bad(let text):
                throw IMAPError.tls("STARTTLS rejected: \(text.text)")
            }
            guard let connection else {
                throw IMAPError.transport("Connection closed during STARTTLS")
            }
            do {
                try await connection.startTLS(hostname: endpoint.host)
            } catch let error as IMAPError {
                throw error
            } catch {
                throw IMAPError.tls(String(describing: error))
            }
            try await refreshCapabilities()
        case .implicitTLS:
            break
        }

        guard connection?.isSecure == true else {
            throw IMAPError.tls("Refusing to authenticate without TLS")
        }

        if !preauthenticated {
            try await authenticate()
        }
        try await refreshCapabilities()
    }

    func refreshCapabilities() async throws {
        var caps: [Capability] = []
        let tagged = try await send(.capability) { payload in
            if case .capabilityData(let list) = payload {
                caps = list
            }
        }
        try throwIfFailed(tagged)
        if !caps.isEmpty {
            capabilities = imapCapabilities(from: caps)
        }
    }

    func authenticate() async throws {
        guard let connection, connection.isSecure else {
            throw IMAPError.tls("Refusing to authenticate without TLS")
        }
        if capabilities.authPlain {
            var buffer = ByteBuffer()
            buffer.writeInteger(UInt8(0))
            buffer.writeString(username)
            buffer.writeInteger(UInt8(0))
            buffer.writeString(password)
            pendingAuthPlain = buffer
            defer { pendingAuthPlain = nil }
            let initial: InitialResponse? = capabilities.saslIR ? InitialResponse(buffer) : nil
            let tagged = try await send(.authenticate(mechanism: .plain, initialResponse: initial))
            try throwIfAuthFailed(tagged)
            return
        }
        if capabilities.loginDisabled {
            throw IMAPError.auth("LOGINDISABLED and AUTH=PLAIN not advertised")
        }
        let tagged = try await send(.login(username: username, password: password))
        try throwIfAuthFailed(tagged)
    }
}

extension IMAPSession {
    func startReader() {
        guard readerTask == nil, let connection else { return }
        let stream = connection.responses
        readerTask = Task { [weak self] in
            for await response in stream {
                await self?.handle(response)
            }
            await self?.handleDisconnect()
        }
    }

    func nextTag() -> String {
        tagCounter += 1
        return "c\(tagCounter)"
    }

    func send(
        _ command: Command,
        collecting: ((ResponsePayload) -> Void)? = nil
    ) async throws -> TaggedResponse {
        if closed { throw IMAPError.transport("Session is closed") }
        let tag = nextTag()
        untaggedCollector = collecting
        defer { untaggedCollector = nil }
        return try await withTaskCancellationHandler {
            try await self.sendAndWait(tag: tag, command: command)
        } onCancel: {
            Task { await self.failTagged(CancellationError()) }
        }
    }

    /// Install the tagged waiter before the write so a fast reply cannot arrive unmatched.
    func sendAndWait(tag: String, command: Command) async throws -> TaggedResponse {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TaggedResponse, Error>) in
            if let existing = taggedWaiter {
                taggedWaiter = nil
                existing.continuation.resume(throwing: IMAPError.transport("Overlapping IMAP command"))
            }
            taggedWaiter = (tag, cont)
            Task {
                do {
                    try await self.sendRaw(.tagged(TaggedCommand(tag: tag, command: command)))
                } catch {
                    self.failTagged(error)
                }
            }
        }
    }

    func sendRaw(_ part: CommandStreamPart) async throws {
        guard let connection else {
            throw IMAPError.transport("Not connected")
        }
        try await connection.send(part)
    }

    func waitForGreeting() async throws -> ResponsePayload {
        if let greetingPayload {
            let value = greetingPayload
            self.greetingPayload = nil
            return value
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ResponsePayload, Error>) in
                self.greetingWaiter = cont
            }
        } onCancel: {
            Task { await self.failGreeting(CancellationError()) }
        }
    }

    func waitForTagged(_ tag: String) async throws -> TaggedResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TaggedResponse, Error>) in
                if let existing = self.taggedWaiter {
                    self.taggedWaiter = nil
                    existing.continuation.resume(throwing: IMAPError.transport("Overlapping IMAP command"))
                }
                self.taggedWaiter = (tag, cont)
            }
        } onCancel: {
            Task { await self.failTagged(CancellationError()) }
        }
    }

    func handle(_ response: Response) {
        switch response {
        case .untagged(let payload):
            if !didGreet, case .conditionalState = payload {
                didGreet = true
                if let waiter = greetingWaiter {
                    greetingWaiter = nil
                    waiter.resume(returning: payload)
                } else {
                    greetingPayload = payload
                }
            }
            applyPayload(payload)
            untaggedCollector?(payload)
        case .fetch(let fetch):
            if fetchInFlight {
                do {
                    try fetchAssembler.apply(fetch)
                } catch {
                    clearFetchState()
                    poisonConnection(error)
                    return
                }
            }
            switch fetch {
            case .start, .startUID:
                publish(.fetchHint)
            default:
                break
            }
        case .tagged(let tagged):
            if tagged.tag == idleTag, let waiter = idleStartWaiter {
                idleStartWaiter = nil
                do {
                    try throwIfFailed(tagged)
                    waiter.resume()
                } catch {
                    waiter.resume(throwing: error)
                }
            }
            if let waiter = taggedWaiter, waiter.tag == tagged.tag {
                taggedWaiter = nil
                waiter.continuation.resume(returning: tagged)
            }
        case .fatal(let text):
            clearFetchState()
            publish(.bye(text.text))
            failWaiters(IMAPError.transport(text.text))
        case .authenticationChallenge:
            if let pendingAuthPlain {
                Task {
                    try? await self.sendRaw(.continuationResponse(pendingAuthPlain))
                }
            }
        case .idleStarted:
            if let waiter = idleStartWaiter {
                idleStartWaiter = nil
                waiter.resume()
            }
        }
    }
    func clearFetchState() {
        fetchInFlight = false
        fetchAssembler = IMAPFetchAssembler()
    }

    func handleDisconnect() {
        clearFetchState()
        if let error = connection?.lastHandlerError {
            if let error = error as? IMAPError {
                failWaiters(error)
            } else {
                failWaiters(IMAPError.parse(String(describing: error)))
            }
        } else if !closed {
            failWaiters(IMAPError.transport("Connection closed"))
        }
        finishIdle()
        // Parser/channel death must poison the session. Otherwise the next
        // tagged command writes into a dead NIOIMAP decoder and hangs forever.
        closed = true
    }

    func poisonConnection(_ error: Error) {
        clearFetchState()
        guard !closed else { return }
        closed = true
        failWaiters(error)
        finishIdle()
        let connection = self.connection
        Task {
            await connection?.close()
        }
        eventContinuation.finish()
    }
}

extension IMAPSession {
    func applyPayload(_ payload: ResponsePayload) {
        switch payload {
        case .conditionalState(let status):
            applyUntaggedStatus(status)
        case .mailboxData(let data):
            applyMailboxData(data)
        case .messageData(let data):
            applyMessageData(data)
        case .capabilityData(let caps):
            capabilities = imapCapabilities(from: caps)
        default:
            break
        }
    }

    func applyUntaggedStatus(_ status: UntaggedStatus) {
        switch status {
        case .ok(let text), .no(let text), .bad(let text):
            applyCode(text.code)
        case .preauth(let text):
            applyCode(text.code)
            authenticated = connection?.isSecure == true
        case .bye(let text):
            publish(.bye(text.text))
        }
    }

    func applyTaggedState(_ state: TaggedResponse.State) {
        switch state {
        case .ok(let text), .no(let text), .bad(let text):
            applyCode(text.code)
        }
    }

    func applyCode(_ code: ResponseTextCode?) {
        if case .capability(let caps) = code {
            capabilities = imapCapabilities(from: caps)
        }
        guard var selected else { return }
        switch code {
        case .uidValidity(let value):
            selected.uidValidity = UInt32(value)
        case .uidNext(let uid):
            selected.uidNext = uid.rawValue
        case .highestModificationSequence(let value):
            selected.highestModSeq = UInt64(value)
        case .noModificationSequence:
            selected.noModSeq = true
        case .mailboxID(let id):
            selected.mailboxID = mailboxIDString(id)
        case .readOnly:
            selected.isReadWrite = false
        case .readWrite:
            selected.isReadWrite = true
        default:
            break
        }
        self.selected = selected
    }

    func applyMailboxData(_ data: MailboxData) {
        switch data {
        case .exists(let count):
            selected?.exists = count
            publish(.exists(count))
        case .flags(let flags):
            selected?.flags = flags.map { String($0) }
        default:
            break
        }
    }

    func applyMessageData(_ data: MessageData) {
        switch data {
        case .expunge(let sequence):
            if let exists = selected?.exists, exists > 0 {
                selected?.exists = exists - 1
            }
            publish(.expunge(sequence: sequence.rawValue))
        case .vanished(let set):
            let uids = uidValues(set)
            selected?.vanished.append(contentsOf: uids)
            publish(.vanished(uids: uids))
        case .vanishedEarlier(let set):
            let uids = uidValues(set)
            selected?.vanishedEarlier.append(contentsOf: uids)
            publish(.vanishedEarlier(uids: uids))
        default:
            break
        }
    }

    func publish(_ event: IMAPMailboxEvent) {
        eventContinuation.yield(event)
        if idleActive {
            idleEvents?.yield(event)
        }
    }

    func finishIdle() {
        idleActive = false
        idleTag = nil
        idleEvents?.finish()
        idleEvents = nil
        if let waiter = idleStartWaiter {
            idleStartWaiter = nil
            waiter.resume(throwing: IMAPError.transport("IDLE ended"))
        }
    }

    func failTagged(_ error: Error) {
        if let waiter = taggedWaiter {
            taggedWaiter = nil
            waiter.continuation.resume(throwing: error)
        }
    }

    func failGreeting(_ error: Error) {
        if let waiter = greetingWaiter {
            greetingWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    func failIdleStart(_ error: Error) {
        if let waiter = idleStartWaiter {
            idleStartWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    func failWaiters(_ error: Error) {
        failTagged(error)
        if let waiter = greetingWaiter {
            greetingWaiter = nil
            waiter.resume(throwing: error)
        }
        if let waiter = idleStartWaiter {
            idleStartWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    func throwIfFailed(_ tagged: TaggedResponse) throws {
        switch tagged.state {
        case .ok:
            return
        case .no(let text):
            throw IMAPError.taggedNO(tag: tagged.tag, message: text.text, code: responseCodeName(text.code))
        case .bad(let text):
            throw IMAPError.taggedBAD(tag: tagged.tag, message: text.text, code: responseCodeName(text.code))
        }
    }

    func throwIfAuthFailed(_ tagged: TaggedResponse) throws {
        switch tagged.state {
        case .ok:
            return
        case .no(let text), .bad(let text):
            throw IMAPError.auth(text.text)
        }
    }

    func ensureOpen() throws {
        if closed { throw IMAPError.transport("Session is closed") }
    }

    func ensureAuthenticated() throws {
        try ensureOpen()
        guard authenticated else {
            throw IMAPError.auth("Not authenticated")
        }
    }
}

extension IMAPSession {
    /// Creates a mailbox as part of a persisted folder/outbox operation.
    public func createMailbox(_ mailbox: String) async throws {
        try ensureAuthenticated()
        guard !idleActive, taggedWaiter == nil,
              !mailbox.isEmpty, !mailbox.contains("\r"),
              !mailbox.contains("\n"), !mailbox.contains("\0") else {
            throw OutgoingMailError.invalidContent("The destination mailbox is invalid or busy.")
        }
        let reply = try await send(.create(MailboxName(ByteBuffer(string: mailbox)), []))
        try throwIfFailed(reply)
    }

    /// Reconciles a previously accepted Sent copy before attempting APPEND.
    /// The caller selects the destination mailbox first. Missing or malformed
    /// search responses are errors, never permission to append another copy.
    public func containsMessageID(_ messageID: String) async throws -> Bool {
        try ensureAuthenticated()
        guard selected != nil, !idleActive, taggedWaiter == nil else {
            throw IMAPError.transport("Sent-copy search requires an idle selected command channel.")
        }
        guard messageID.hasPrefix("<"), messageID.hasSuffix(">"),
              messageID.utf8.count <= 998,
              !messageID.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else {
            throw OutgoingMailError.invalidContent("The outgoing Message-ID is invalid.")
        }
        var receivedSearch = false
        var found = false
        let reply = try await send(.uidSearch(key: .header("Message-ID", ByteBuffer(string: messageID)))) { payload in
            if case .mailboxData(.search(let matches, _)) = payload {
                receivedSearch = true
                found = found || !matches.isEmpty
            }
        }
        try throwIfFailed(reply)
        guard receivedSearch else { throw IMAPError.parse("The Sent-copy search response was incomplete.") }
        return found
    }

    /// Streams an immutable MIME file into a mailbox and returns only after
    /// tagged OK. Failure may mean the server saved the copy: callers must
    /// reconcile by Message-ID before retrying, and must never repeat SMTP.
    /// Each wire-progress wait is bounded; a progressing large file has no
    /// fixed total-duration limit.
    public func append(fileURL: URL, byteCount: Int64, to mailbox: String, date: Date) async throws {
        try Task.checkCancellation()
        try ensureAuthenticated()
        guard !idleActive, taggedWaiter == nil else {
            throw IMAPError.transport("Sent-copy APPEND requires an idle command channel.")
        }
        guard fileURL.isFileURL, byteCount >= 0, Int(exactly: byteCount) != nil,
              !mailbox.isEmpty, !mailbox.contains("\r"), !mailbox.contains("\n"), !mailbox.contains("\0") else {
            throw OutgoingMailError.invalidContent("The Sent-copy file or mailbox is invalid.")
        }
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw OutgoingMailError.invalidContent("The Sent-copy file is unavailable.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Int64(attributes.st_size) == byteCount else {
            throw OutgoingMailError.invalidContent("The Sent-copy file changed or is not a regular file.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let parts = ServerMessageDate.Components(
            year: components.year ?? 0, month: components.month ?? 0, day: components.day ?? 0,
            hour: components.hour ?? 0, minute: components.minute ?? 0, second: components.second ?? 0,
            timeZoneMinutes: 0
        ) else {
            throw OutgoingMailError.invalidContent("The Sent-copy date is invalid.")
        }
        let tag = nextTag()
        defer { cancelAppendDeadline(tag: tag) }
        let reply = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TaggedResponse, Error>) in
                taggedWaiter = (tag, continuation)
                armAppendDeadline(tag: tag)
                Task { [handle] in
                    // A tagged rejection can resume the caller before this
                    // writer unwinds. Keep the descriptor alive until it stops.
                    defer { try? handle.close() }
                    do {
                        try await self.sendRaw(.append(.start(tag: tag, appendingTo: MailboxName(ByteBuffer(string: mailbox)))))
                        guard self.taggedWaiter?.tag == tag else { return }
                        self.armAppendDeadline(tag: tag)
                        try await self.sendRaw(.append(.beginMessage(message: AppendMessage(
                            options: AppendOptions(flagList: [.seen], internalDate: ServerMessageDate(parts)),
                            data: AppendData(byteCount: Int(byteCount))
                        ))))
                        var remaining = byteCount
                        var buffer = ByteBufferAllocator().buffer(capacity: 64 * 1024)
                        while remaining > 0 {
                            try Task.checkCancellation()
                            guard self.taggedWaiter?.tag == tag else { return }
                            buffer.clear()
                            let requested = Int(min(remaining, 64 * 1024))
                            let count = try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: requested) { bytes in
                                var count: Int
                                repeat {
                                    count = read(descriptor, bytes.baseAddress!, requested)
                                } while count < 0 && errno == EINTR
                                guard count > 0 else {
                                    throw OutgoingMailError.invalidContent("The Sent-copy file changed during APPEND.")
                                }
                                return count
                            }
                            remaining -= Int64(count)
                            self.armAppendDeadline(tag: tag)
                            try await self.sendRaw(.append(.messageBytes(buffer)))
                        }
                        guard self.taggedWaiter?.tag == tag else { return }
                        self.armAppendDeadline(tag: tag)
                        try await self.sendRaw(.append(.endMessage))
                        guard self.taggedWaiter?.tag == tag else { return }
                        try await self.sendRaw(.append(.finish))
                    } catch {
                        self.poisonConnection(error)
                    }
                }
            }
        }, onCancel: {
            Task { await self.close() }
        })
        try throwIfFailed(reply)
    }

    private func armAppendDeadline(tag: String) {
        cancelAppendDeadline(tag: tag)
        guard let connection else { return }
        let timer: Scheduled<Void> = connection.channel.eventLoop.scheduleTask(in: .seconds(30)) { [weak self] in
            Task { await self?.expireAppend(tag: tag) }
        }
        appendDeadline = (tag, timer)
    }

    private func cancelAppendDeadline(tag: String) {
        guard appendDeadline?.tag == tag else { return }
        appendDeadline?.timer.cancel()
        appendDeadline = nil
    }

    private func expireAppend(tag: String) {
        guard taggedWaiter?.tag == tag else { return }
        poisonConnection(IMAPError.transport("The Sent-copy APPEND made no progress before its deadline."))
    }
}
