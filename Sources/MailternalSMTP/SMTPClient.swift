import Foundation
import MailternalInterfaces
import MailternalTLS
import NIO
import NIOSSL
import NIOTLS
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class SMTPEventLoopStorage: @unchecked Sendable {
    static let shared = SMTPEventLoopStorage(
        group: MultiThreadedEventLoopGroup(numberOfThreads: 4),
        ownsGroup: false
    )

    let group: EventLoopGroup
    let ownsGroup: Bool

    init(group: EventLoopGroup, ownsGroup: Bool) {
        self.group = group
        self.ownsGroup = ownsGroup
    }
}

private final class SMTPAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: SMTPConnection?
    private var candidateStore: SMTPCandidateStore?
    private var cancelled = false
    private var commitStarted = false

    var hasCommitted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return commitStarted
    }

    func installCandidates(_ store: SMTPCandidateStore) {
        lock.lock()
        candidateStore = store
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { store.abortAll() }
    }

    func install(_ connection: SMTPConnection) {
        lock.lock()
        self.connection = connection
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { connection.abort() }
    }

    func markCommitStarted() {
        lock.lock()
        commitStarted = true
        let shouldCancel = cancelled
        let connection = self.connection
        lock.unlock()
        if shouldCancel { connection?.abort() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let connection = self.connection
        let candidateStore = self.candidateStore
        lock.unlock()
        candidateStore?.abortAll()
        connection?.abort()
    }
}

private struct SMTPTimeout: Error, Sendable {}
private struct SMTPBeforeCommitFailure: Error {
    let underlying: Error
}
private func withSMTPDeadline<T: Sendable>(
    _ duration: Duration,
    onTimeout: @escaping @Sendable () -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw SMTPTimeout()
        }
        do {
            let result = try await group.next()!
            group.cancelAll()
            return result
        } catch {
            if error is SMTPTimeout { onTimeout() }
            group.cancelAll()
            throw error
        }
    }
}

private enum SMTPTLS {
    static func makeContext(hostname: String, additionalTrustRoots: [Data]) throws -> NIOSSLContext {
        _ = try normalizedHostname(hostname)
        do {
            return try MailTLS.clientContext(additionalPEM: additionalTrustRoots)
        } catch {
            throw SMTPSubmissionError(kind: .tls, message: "Unable to configure TLS: \(error.localizedDescription)")
        }
    }

    static func makeHandler(
        context: NIOSSLContext,
        hostname: String
    ) throws -> NIOSSLClientHandler {
        let host = try normalizedHostname(hostname)
        do {
            return try NIOSSLClientHandler(context: context, serverHostname: host)
        } catch {
            throw SMTPSubmissionError(kind: .tls, message: "Unable to configure TLS hostname verification.")
        }
    }

    private static func normalizedHostname(_ raw: String) throws -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0x0D || scalar.value == 0x0A ||
                  scalar.value == 0x20 || scalar.value == 0x09
              }),
              !isIPAddress(host) else {
            throw SMTPSubmissionError(kind: .configuration, message: "SMTP requires a DNS hostname for TLS verification.")
        }
        return host
    }

    private static func isIPAddress(_ raw: String) -> Bool {
        var host = raw
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        return host.withCString { pointer in
            var v4 = in_addr()
            var v6 = in6_addr()
            return inet_pton(AF_INET, pointer, &v4) == 1 || inet_pton(AF_INET6, pointer, &v6) == 1
        }
    }
}

private final class SMTPHandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private var context: ChannelHandlerContext?
    private var finished = false

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if promise == nil { promise = context.eventLoop.makePromise(of: Void.self) }
        if finished {
            promise?.fail(SMTPWireError.cancelled)
            context.pipeline.removeHandler(self, promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent,
           case .handshakeCompleted = tlsEvent {
            finish(error: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(error: SMTPWireError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error: SMTPWireError.tlsFailure)
        context.fireErrorCaught(error)
    }

    func fail(_ error: SMTPWireError) {
        if let context {
            context.eventLoop.execute { [weak self] in self?.finish(error: error) }
        } else {
            finish(error: error)
        }
    }
    func wait() async throws {
        guard let promise else { throw SMTPWireError.tlsFailure }
        do {
            try await promise.futureResult.get()
        } catch let error as SMTPWireError {
            if case .cancelled = error { throw error }
            throw SMTPSubmissionError(kind: .tls, message: "TLS handshake failed.")
        } catch let error as SMTPSubmissionError {
            throw error
        } catch {
            throw SMTPSubmissionError(kind: .tls, message: "TLS handshake failed.")
        }
    }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        if let error { promise?.fail(error) } else { promise?.succeed(()) }
        if let context {
            context.pipeline.removeHandler(self, promise: nil)
        }
    }
}

private final class SMTPConnection: @unchecked Sendable {
    let channel: Channel
    let inbox: SMTPReplyInbox
    private(set) var isSecure: Bool

    init(channel: Channel, inbox: SMTPReplyInbox, isSecure: Bool) {
        self.channel = channel
        self.inbox = inbox
        self.isSecure = isSecure
    }

    func command(_ command: String, timeout: Duration) async throws -> SMTPReply {
        guard !command.contains("\r"), !command.contains("\n"),
              command.utf8.count <= 998 else {
            throw SMTPSubmissionError(kind: .configuration, message: "Invalid or oversized SMTP command.")
        }
        return try await withSMTPDeadline(timeout, onTimeout: { [weak self] in
            self?.abort()
        }) {
            guard self.channel.isActive else { throw SMTPWireError.connectionClosed }
            var buffer = self.channel.allocator.buffer(capacity: command.utf8.count + 2)
            buffer.writeString(command)
            buffer.writeString("\r\n")
            do {
                try await self.channel.writeAndFlush(buffer)
            } catch {
                throw SMTPWireError.writeFailed
            }
            return try await self.inbox.next()
        }
    }

    func write(_ bytes: [UInt8], timeout: Duration) async throws {
        try await withSMTPDeadline(timeout, onTimeout: { [weak self] in
            self?.abort()
        }) {
            guard self.channel.isActive else { throw SMTPWireError.connectionClosed }
            var buffer = self.channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            do {
                try await self.channel.writeAndFlush(buffer)
            } catch {
                throw SMTPWireError.writeFailed
            }
        }
    }
    func startTLS(context: NIOSSLContext, hostname: String, timeout: Duration) async throws {
        let waiter = SMTPHandshakeWaiter()
        do {
            try await withSMTPDeadline(timeout, onTimeout: { [weak self] in
                self?.abort()
            }) {
                try await self.channel.pipeline.addHandler(waiter, position: .first)
                try await self.channel.eventLoop.submit {
                    let ssl = try SMTPTLS.makeHandler(context: context, hostname: hostname)
                    try self.channel.pipeline.syncOperations.addHandler(ssl, position: .first)
                }.get()
                try await waiter.wait()
            }
            isSecure = true
        } catch {
            waiter.fail(.tlsFailure)
            throw error
        }
    }
    func reply(timeout: Duration) async throws -> SMTPReply {
        try await withSMTPDeadline(timeout, onTimeout: { [weak self] in
            self?.abort()
        }) {
            try await self.inbox.next()
        }
    }

    func bestEffortQuit() {
        guard channel.isActive else { return }
        var buffer = channel.allocator.buffer(capacity: 6)
        buffer.writeString("QUIT\r\n")
        channel.writeAndFlush(buffer, promise: nil)
        channel.close(promise: nil)
    }

    func close() async {
        inbox.fail(SMTPWireError.connectionClosed)
        if channel.isActive { try? await channel.close() }
    }

    func abort() {
        inbox.fail(SMTPWireError.cancelled)
        channel.close(promise: nil)
    }
}

private final class SMTPCandidate: @unchecked Sendable {
    let inbox = SMTPReplyInbox()
    let replyHandler: SMTPReplyHandler
    let handshake: SMTPHandshakeWaiter?
    private let lock = NSLock()
    private var channel: Channel?

    init(implicitTLS: Bool) {
        self.handshake = implicitTLS ? SMTPHandshakeWaiter() : nil
        self.replyHandler = SMTPReplyHandler(inbox: inbox)
    }

    func setChannel(_ channel: Channel) {
        lock.lock()
        self.channel = channel
        lock.unlock()
    }

    func abort() {
        lock.lock()
        let channel = self.channel
        lock.unlock()
        inbox.fail(SMTPWireError.cancelled)
        handshake?.fail(.cancelled)
        channel?.close(promise: nil)
    }
}

private final class SMTPCandidateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var candidates: [ObjectIdentifier: SMTPCandidate] = [:]
    private var closed = false

    /// DNS or Happy-Eyeballs completion can arrive after cancellation.
    /// A closed attempt must never admit a later connection candidate.
    func add(_ candidate: SMTPCandidate, channel: Channel) -> Bool {
        candidate.setChannel(channel)
        lock.lock()
        let accepted = !closed
        if accepted { candidates[ObjectIdentifier(channel)] = candidate }
        lock.unlock()
        if !accepted { candidate.abort() }
        return accepted
    }

    func candidate(for channel: Channel) -> SMTPCandidate? {
        lock.lock()
        defer { lock.unlock() }
        return candidates[ObjectIdentifier(channel)]
    }

    func abortAll() {
        lock.lock()
        closed = true
        let values = Array(candidates.values)
        candidates.removeAll()
        lock.unlock()
        values.forEach { $0.abort() }
    }
}

private enum SMTPNetwork {
    static func connect(
        configuration: SMTPConfiguration,
        group: EventLoopGroup,
        additionalTrustRoots: [Data],
        candidates: SMTPCandidateStore
    ) async throws -> SMTPConnection {
        let implicitTLS = configuration.security == .implicitTLS
        let initialContext: NIOSSLContext?
        do {
            initialContext = implicitTLS
                ? try SMTPTLS.makeContext(
                    hostname: configuration.host,
                    additionalTrustRoots: additionalTrustRoots
                )
                : nil
        } catch {
            candidates.abortAll()
            throw error
        }
        try Task.checkCancellation()
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(
                ChannelOptions.recvAllocator,
                value: AdaptiveRecvByteBufferAllocator(minimum: 1, initial: 16 * 1024, maximum: 64 * 1024)
            )
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .connectTimeout(.seconds(30))
            .channelInitializer { channel in
                let candidate = SMTPCandidate(implicitTLS: implicitTLS)
                guard candidates.add(candidate, channel: channel) else {
                    return channel.eventLoop.makeFailedFuture(CancellationError())
                }
                return channel.eventLoop.makeCompletedFuture {
                    do {
                        if let initialContext {
                            let ssl = try SMTPTLS.makeHandler(
                                context: initialContext,
                                hostname: configuration.host
                            )
                            try channel.pipeline.syncOperations.addHandler(ssl)
                            if let handshake = candidate.handshake {
                                try channel.pipeline.syncOperations.addHandler(handshake)
                            }
                        }
                        try channel.pipeline.syncOperations.addHandler(candidate.replyHandler)
                    } catch {
                        candidate.abort()
                        throw error
                    }
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(
                host: configuration.host,
                port: configuration.port
            ).get()
        } catch {
            candidates.abortAll()
            if Task.isCancelled { throw CancellationError() }
            throw SMTPSubmissionError(kind: .connection, message: "Unable to connect to the SMTP server.")
        }
        guard let candidate = candidates.candidate(for: channel) else {
            candidates.abortAll()
            try? await channel.close()
            throw SMTPSubmissionError(kind: .connection, message: "Unable to establish the SMTP connection.")
        }
        let connection = SMTPConnection(
            channel: channel,
            inbox: candidate.inbox,
            isSecure: implicitTLS
        )
        if let handshake = candidate.handshake {
            do {
                try await handshake.wait()
            } catch let error as SMTPWireError {
                await connection.close()
                if case .cancelled = error { throw error }
                throw SMTPSubmissionError(kind: .tls, message: "TLS handshake failed.")
            } catch let error as SMTPSubmissionError {
                await connection.close()
                throw error
            } catch {
                await connection.close()
                throw SMTPSubmissionError(kind: .tls, message: "TLS handshake failed.")
        }
        }
        return connection
    }
}

private struct SMTPCapabilities: Sendable {
    var startTLS = false
    var smtpUTF8 = false
    var sizeAdvertised = false
    var sizeLimit: Int64?
    var authMechanisms: Set<String> = []

    init(reply: SMTPReply) {
        for rawLine in reply.lines {
            let pieces = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = pieces.first else { continue }
            let keyword = first.uppercased()
            switch keyword {
            case "STARTTLS":
                startTLS = true
            case "SMTPUTF8":
                smtpUTF8 = true
            case "SIZE":
                sizeAdvertised = true
                if pieces.count > 1, let limit = Int64(pieces[1]), limit >= 0 {
                    sizeLimit = limit
                }
            case "AUTH":
                for mechanism in pieces.dropFirst() {
                    authMechanisms.insert(mechanism.uppercased())
                }
            default:
                if keyword.hasPrefix("AUTH=") {
                    authMechanisms.insert(String(keyword.dropFirst(5)))
                    for mechanism in pieces.dropFirst() {
                        authMechanisms.insert(mechanism.uppercased())
                    }
                }
            }
        }
    }
}

/// A bounded SMTP submission transport. Every connection is TLS-protected:
/// implicit TLS starts before the greeting, while STARTTLS is mandatory and
/// followed by a fresh EHLO before AUTH.
public struct SMTPClient: SMTPSubmitting, Sendable {
    private let eventLoops: SMTPEventLoopStorage
    private let timeout: Duration
    private let additionalTrustRoots: [Data]

    /// - Parameters:
    ///   - eventLoopGroup: Shared NIO group. `nil` uses a process-wide,
    ///     bounded four-thread group and does not shut it down per client.
    ///   - timeout: Per-operation wall-clock deadline, including connect,
    ///     handshake, commands, and DATA backpressure.
    ///   - additionalTrustRoots: Explicit QA PEM anchors, using the shared IMAP
    ///     trust policy. macOS/Linux retain system roots; iOS QA uses the explicit
    ///     set. Certificate and hostname verification always remain enabled.
    public init(
        eventLoopGroup: EventLoopGroup? = nil,
        timeout: Duration = .seconds(30),
        additionalTrustRoots: [Data] = []
    ) {
        self.eventLoops = eventLoopGroup.map { SMTPEventLoopStorage(group: $0, ownsGroup: false) }
            ?? SMTPEventLoopStorage.shared
        self.timeout = timeout
        self.additionalTrustRoots = additionalTrustRoots
    }

    public func validate(configuration: SMTPConfiguration, password: String) async throws {
        try validateConfiguration(configuration, password: password)
        let state = SMTPAttemptState()
        let candidates = SMTPCandidateStore()
        state.installCandidates(candidates)
        do {
            try await withTaskCancellationHandler(operation: {
                let connection = try await withSMTPDeadline(
                    self.timeout,
                    onTimeout: { state.cancel() }
                ) {
                    try await SMTPNetwork.connect(
                        configuration: configuration,
                        group: self.eventLoops.group,
                        additionalTrustRoots: self.additionalTrustRoots,
                        candidates: candidates
                    )
                }
                state.install(connection)
                defer { Task { await connection.close() } }
                _ = try await self.authenticate(connection, configuration: configuration, password: password)
            }, onCancel: {
                state.cancel()
            })
        } catch {
            throw map(error: error, committed: false)
        }
    }

    public func submit(
        _ submission: SMTPSubmission,
        configuration: SMTPConfiguration,
        password: String,
        beforeCommit: @escaping @Sendable () async throws -> Void
    ) async throws -> SMTPSubmissionReceipt {
        try validateConfiguration(configuration, password: password)
        try validateEnvelope(submission.envelope)
        try validateSubmissionFile(submission)
        let state = SMTPAttemptState()
        let candidates = SMTPCandidateStore()
        state.installCandidates(candidates)
        do {
            return try await withTaskCancellationHandler(operation: {
                try await self.submitAttempt(
                    submission,
                    configuration: configuration,
                    password: password,
                    beforeCommit: beforeCommit,
                    state: state,
                    candidates: candidates
                )
            }, onCancel: {
                state.cancel()
            })
        } catch let error as SMTPSubmissionError {
            throw error
        } catch let error as SMTPBeforeCommitFailure {
            throw error.underlying
        } catch {
            throw map(error: error, committed: state.hasCommitted)
        }
    }

    private func submitAttempt(
        _ submission: SMTPSubmission,
        configuration: SMTPConfiguration,
        password: String,
        beforeCommit: @escaping @Sendable () async throws -> Void,
        state: SMTPAttemptState,
        candidates: SMTPCandidateStore
    ) async throws -> SMTPSubmissionReceipt {
        let connection = try await withSMTPDeadline(
            timeout,
            onTimeout: { state.cancel() }
        ) {
            try await SMTPNetwork.connect(
                configuration: configuration,
                group: self.eventLoops.group,
                additionalTrustRoots: self.additionalTrustRoots,
                candidates: candidates
            )
        }
        state.install(connection)
        defer { Task { await connection.close() } }

        let capabilities = try await authenticate(
            connection,
            configuration: configuration,
            password: password
        )
        try validateServerCapabilities(capabilities, submission: submission)
        var mailCommand = "MAIL FROM:<\(submission.envelope.sender)>"
        if submission.envelope.requiresSMTPUTF8 { mailCommand += " SMTPUTF8" }
        if capabilities.sizeAdvertised { mailCommand += " SIZE=\(submission.byteCount)" }
        let mailReply = try await connection.command(mailCommand, timeout: timeout)
        try requireReply(mailReply, accepted: { $0 == 250 }, kind: .message, operation: "MAIL FROM")

        for recipient in submission.envelope.recipients {
            let reply = try await connection.command("RCPT TO:<\(recipient)>", timeout: timeout)
            guard reply.code == 250 || reply.code == 251 || reply.code == 252 else {
                throw smtpFailure(reply, kindForFailure: .recipient, operation: "RCPT TO")
            }
        }

        let dataReply = try await connection.command("DATA", timeout: timeout)
        try requireReply(dataReply, accepted: { $0 == 354 }, kind: .message, operation: "DATA")
        try await streamData(submission, over: connection)

        do {
            try await beforeCommit()
        } catch {
            await connection.close()
            throw SMTPBeforeCommitFailure(underlying: error)
        }
        state.markCommitStarted()
        try Task.checkCancellation()
        try await connection.write([0x2E, 0x0D, 0x0A], timeout: timeout)

        let finalReply: SMTPReply
        do {
            finalReply = try await withSMTPDeadline(
                timeout,
                onTimeout: { state.cancel() }
            ) {
                try await connection.inbox.next()
            }
        } catch {
            throw SMTPWireError.connectionClosed
        }
        if (200...299).contains(finalReply.code) {
            // Acceptance is already durable. Do not wait for QUIT: a stalled
            // close cannot turn a positive DATA reply into deliveryUnknown.
            connection.bestEffortQuit()
            return SMTPSubmissionReceipt(acceptedAt: Date(), replyCode: finalReply.code)
        }
        if (400...499).contains(finalReply.code) {
            throw smtpFailure(finalReply, kindForFailure: .temporary, operation: "DATA")
        }
        if (500...599).contains(finalReply.code) {
            throw smtpFailure(finalReply, kindForFailure: .message, operation: "DATA")
        }
        throw SMTPSubmissionError(kind: .deliveryUnknown, message: "Delivery status is unknown.")
    }

    private func authenticate(
        _ connection: SMTPConnection,
        configuration: SMTPConfiguration,
        password: String
    ) async throws -> SMTPCapabilities {
        let greeting = try await connection.reply(timeout: timeout)
        guard greeting.code == 220 else {
            throw smtpFailure(greeting, kindForFailure: .connection, operation: "greeting")
        }

        var capabilities = try await ehlo(connection)
        if configuration.security == .startTLS {
            guard capabilities.startTLS else {
                throw SMTPSubmissionError(kind: .tls, message: "The SMTP server does not advertise STARTTLS.")
            }
            let startReply = try await connection.command("STARTTLS", timeout: timeout)
            guard startReply.code == 220 else {
                throw smtpFailure(startReply, kindForFailure: .tls, operation: "STARTTLS")
            }
            let context = try SMTPTLS.makeContext(
                hostname: configuration.host,
                additionalTrustRoots: additionalTrustRoots
            )
            try await connection.startTLS(context: context, hostname: configuration.host, timeout: timeout)
            capabilities = try await ehlo(connection)
        }
        guard connection.isSecure else {
            throw SMTPSubmissionError(kind: .tls, message: "SMTP authentication requires a verified TLS connection.")
        }

        let mechanisms = capabilities.authMechanisms
        if mechanisms.contains("PLAIN") {
            try await authenticatePlain(connection, username: configuration.username, password: password)
        } else if mechanisms.contains("LOGIN") {
            try await authenticateLogin(connection, username: configuration.username, password: password)
        } else {
            throw SMTPSubmissionError(kind: .authentication, message: "The SMTP server offers no supported secure authentication method.")
        }
        // RFC 3207 and common server implementations require capability
        // refresh after AUTH; this also supplies post-auth SMTPUTF8/SIZE.
        return try await ehlo(connection)
    }

    private func ehlo(_ connection: SMTPConnection) async throws -> SMTPCapabilities {
        // A fixed, non-secret argument avoids exposing the account identity
        // before STARTTLS and is valid for every SMTP server.
        let reply = try await connection.command("EHLO localhost", timeout: timeout)
        guard reply.code == 250 else {
            throw smtpFailure(reply, kindForFailure: .connection, operation: "EHLO")
        }
        return SMTPCapabilities(reply: reply)
    }


    private func authenticatePlain(_ connection: SMTPConnection, username: String, password: String) async throws {
        let payload = Data([0]) + Data(username.utf8) + Data([0]) + Data(password.utf8)
        let encoded = payload.base64EncodedString()
        let reply = try await connection.command("AUTH PLAIN \(encoded)", timeout: timeout)
        if reply.code == 235 { return }
        if reply.code == 334 {
            let final = try await connection.command(encoded, timeout: timeout)
            guard final.code == 235 else {
                throw smtpFailure(final, kindForFailure: .authentication, operation: "AUTH")
            }
            return
        }
        throw smtpFailure(reply, kindForFailure: .authentication, operation: "AUTH")
    }

    private func authenticateLogin(_ connection: SMTPConnection, username: String, password: String) async throws {
        let start = try await connection.command("AUTH LOGIN", timeout: timeout)
        guard start.code == 334 else {
            throw smtpFailure(start, kindForFailure: .authentication, operation: "AUTH")
        }
        let userReply = try await connection.command(
            Data(username.utf8).base64EncodedString(),
            timeout: timeout
        )
        guard userReply.code == 334 else {
            throw smtpFailure(userReply, kindForFailure: .authentication, operation: "AUTH")
        }
        let passwordReply = try await connection.command(
            Data(password.utf8).base64EncodedString(),
            timeout: timeout
        )
        guard passwordReply.code == 235 else {
            throw smtpFailure(passwordReply, kindForFailure: .authentication, operation: "AUTH")
        }
    }

    private func streamData(
        _ submission: SMTPSubmission,
        over connection: SMTPConnection
    ) async throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: submission.fileURL)
        } catch {
            throw SMTPSubmissionError(kind: .message, message: "The MIME file could not be opened.")
        }
        defer { try? handle.close() }

        var encoder = SMTPDataEncoder()
        var remaining = submission.byteCount
        while remaining > 0 {
            let requested = Int(min(Int64(64 * 1024), remaining))
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: requested)
            } catch {
                throw SMTPSubmissionError(kind: .message, message: "The MIME file could not be read.")
            }
            guard let chunk, !chunk.isEmpty else {
                throw SMTPSubmissionError(kind: .message, message: "The MIME file changed while it was being sent.")
            }
            remaining -= Int64(chunk.count)
            let encoded = try encoder.encode(chunk)
            if !encoded.isEmpty { try await connection.write(encoded, timeout: timeout) }
        }
        do {
            let extra = try handle.read(upToCount: 1)
            guard extra?.isEmpty != false else {
                throw SMTPSubmissionError(kind: .message, message: "The MIME file changed while it was being sent.")
            }
        } catch let error as SMTPSubmissionError {
            throw error
        } catch {
            throw SMTPSubmissionError(kind: .message, message: "The MIME file could not be read.")
        }
        try encoder.finish()
    }

    private func validateServerCapabilities(
        _ capabilities: SMTPCapabilities,
        submission: SMTPSubmission
    ) throws {
        if submission.envelope.requiresSMTPUTF8 && !capabilities.smtpUTF8 {
            throw SMTPSubmissionError(kind: .message, message: "The SMTP server does not support SMTPUTF8.")
        }
        if let sizeLimit = capabilities.sizeLimit, submission.byteCount > sizeLimit {
            throw SMTPSubmissionError(kind: .message, replyCode: 552, message: "The message exceeds the SMTP server size limit.")
        }
    }

    private func validateConfiguration(_ configuration: SMTPConfiguration, password: String) throws {
        guard configuration.port > 0, configuration.port <= 65_535 else {
            throw SMTPSubmissionError(kind: .configuration, message: "The SMTP port is invalid.")
        }
        guard !configuration.username.isEmpty,
              configuration.username.utf8.count <= 350,
              !configuration.username.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SMTPSubmissionError(kind: .configuration, message: "The SMTP username is invalid.")
        }
        guard password.utf8.count <= 350,
              !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SMTPSubmissionError(kind: .configuration, message: "The SMTP password is invalid.")
        }
        _ = try SMTPTLS.normalizedHostnameForValidation(configuration.host)
    }

    private func validateEnvelope(_ envelope: SMTPEnvelope) throws {
        guard !envelope.recipients.isEmpty, envelope.recipients.count <= 1_000 else {
            throw SMTPSubmissionError(kind: .message, message: "The message must have at least one recipient.")
        }
        try validateAddress(envelope.sender, allowEmpty: true)
        for recipient in envelope.recipients { try validateAddress(recipient, allowEmpty: false) }
        let addresses = [envelope.sender] + envelope.recipients
        if !envelope.requiresSMTPUTF8,
           addresses.contains(where: { $0.unicodeScalars.contains(where: { $0.value > 0x7F }) }) {
            throw SMTPSubmissionError(kind: .message, message: "Internationalized addresses require SMTPUTF8.")
        }
    }

    private func validateAddress(_ address: String, allowEmpty: Bool) throws {
        if address.isEmpty && allowEmpty { return }
        guard !address.isEmpty,
              address.utf8.count <= 800,
              !address.unicodeScalars.contains(where: { scalar in
                  scalar.value == 0x0D || scalar.value == 0x0A ||
                  scalar.value < 0x20 || scalar.value == 0x7F
              }),
              !address.contains("<"), !address.contains(">"),
              !address.contains(" "), !address.contains("\t") else {
            throw SMTPSubmissionError(kind: .message, message: "The SMTP envelope contains an invalid address.")
        }
    }

    private func validateSubmissionFile(_ submission: SMTPSubmission) throws {
        guard submission.fileURL.isFileURL, submission.byteCount >= 0 else {
            throw SMTPSubmissionError(kind: .message, message: "The MIME file is invalid.")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: submission.fileURL.path)
            guard let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == submission.byteCount else {
                throw SMTPSubmissionError(kind: .message, message: "The MIME file size does not match the submission.")
            }
        } catch let error as SMTPSubmissionError {
            throw error
        } catch {
            throw SMTPSubmissionError(kind: .message, message: "The MIME file is unavailable.")
        }
    }

    private func requireReply(
        _ reply: SMTPReply,
        accepted: (Int) -> Bool,
        kind: SMTPSubmissionError.Kind,
        operation: String
    ) throws {
        guard accepted(reply.code) else {
            throw smtpFailure(reply, kindForFailure: kind, operation: operation)
        }
    }

    private func smtpFailure(
        _ reply: SMTPReply,
        kindForFailure: SMTPSubmissionError.Kind,
        operation: String
    ) -> SMTPSubmissionError {
        let kind: SMTPSubmissionError.Kind
        if (400...499).contains(reply.code) {
            switch kindForFailure {
            case .message, .recipient:
                kind = .temporary
            default:
                kind = kindForFailure
            }
        } else {
            kind = kindForFailure
        }
        return SMTPSubmissionError(kind: kind, replyCode: reply.code, message: "SMTP \(operation) was rejected (\(reply.code)).")
    }

    private func map(error: Error, committed: Bool) -> SMTPSubmissionError {
        if let error = error as? SMTPSubmissionError {
            if committed {
                switch error.kind {
                case .message, .temporary:
                    return error
                default:
                    return SMTPSubmissionError(kind: .deliveryUnknown, message: "Delivery status is unknown.")
                }
            }
            return error
        }
        if error is CancellationError {
            return SMTPSubmissionError(
                kind: committed ? .deliveryUnknown : .cancelled,
                message: committed ? "Delivery status is unknown." : "SMTP submission was cancelled."
            )
        }
        if let wireError = error as? SMTPWireError, case .cancelled = wireError {
            return SMTPSubmissionError(
                kind: committed ? .deliveryUnknown : .cancelled,
                message: committed ? "Delivery status is unknown." : "SMTP submission was cancelled."
            )
        }
        if error is SMTPTimeout {
            return SMTPSubmissionError(
                kind: committed ? .deliveryUnknown : .connection,
                message: committed ? "Delivery status is unknown." : "The SMTP operation timed out."
            )
        }
        if let wireError = error as? SMTPWireError {
            switch wireError {
            case .tlsFailure:
                return SMTPSubmissionError(kind: .tls, message: "TLS handshake failed.")
            case .cancelled:
                return SMTPSubmissionError(kind: committed ? .deliveryUnknown : .cancelled, message: committed ? "Delivery status is unknown." : "SMTP submission was cancelled.")
            case .timeout:
                return SMTPSubmissionError(kind: committed ? .deliveryUnknown : .connection, message: committed ? "Delivery status is unknown." : "The SMTP operation timed out.")
            default:
                return SMTPSubmissionError(kind: committed ? .deliveryUnknown : .connection, message: committed ? "Delivery status is unknown." : "The SMTP connection failed.")
            }
        }
        return SMTPSubmissionError(kind: committed ? .deliveryUnknown : .connection, message: committed ? "Delivery status is unknown." : "The SMTP connection failed.")
    }

}

private extension SMTPTLS {
    static func normalizedHostnameForValidation(_ raw: String) throws -> String {
        try normalizedHostname(raw)
    }
}
