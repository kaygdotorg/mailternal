import Foundation
import MailternalInterfaces
import MailternalTLS
import NIO
import NIOIMAP
import NIOSSL
import NIOTLS

private enum IMAPLimits {
    /// Individual parser lines/literals remain capped independently of the
    /// aggregate FETCH receive budget.
    static let maxBytes = 1 << 20
    static let maximumPeekLiteralBytes = IMAPFetchAssembler.maximumLiteralBytes
    /// The producer stops socket reads after eight responses and asks for more
    /// once two remain. A single already-issued NIO read may overshoot this
    /// watermark, but the parser's one-megabyte input bound caps that burst.
    static let responseQueueLowWatermark = 2
    static let responseQueueHighWatermark = 8
}

typealias IMAPResponseStream = NIOAsyncSequenceProducer<
    Response,
    NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
    ResponseCollectorDelegate
>

/// Byte-level IMAP connection: a NIO `Channel` with `IMAPClientHandler` plus a
/// bounded, back-pressured response stream. Production uses TCP + NIOSSL; tests
/// inject an `NIOAsyncTestingChannel`.
final class IMAPConnection: @unchecked Sendable {
    let channel: Channel
    let responses: IMAPResponseStream
    private let collector: ResponseCollector
    private let tls: TLSUpgrader
    // Touched from the session actor only after construction.
    private var _isSecure: Bool
    private let errorLock = NSLock()
    private var _lastHandlerError: Error?

    var isSecure: Bool { _isSecure }
    var lastHandlerError: Error? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return _lastHandlerError ?? collector.lastError
    }

    init(channel: Channel, tls: TLSUpgrader, isSecure: Bool, collector: ResponseCollector) {
        self.channel = channel
        self.tls = tls
        self._isSecure = isSecure
        self.collector = collector
        self.responses = collector.stream
        collector.onError = { [weak self] error in
            guard let self else { return }
            self.errorLock.lock()
            self._lastHandlerError = error
            self.errorLock.unlock()
        }
    }

    func send(_ part: CommandStreamPart) async throws {
        guard channel.isActive else {
            throw IMAPError.transport("Connection closed")
        }
        do {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(part))
        } catch {
            throw IMAPError.transport(String(describing: error))
        }
    }

    /// Starts demand-controlled socket reads. The collector normally leaves
    /// `autoRead` enabled; it disables it only while the response queue is
    /// above its high watermark and re-enables it below the low watermark.
    func startReading() async throws {
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
    }

    func beginFetchResponse(maximumBytes: Int) {
        collector.beginFetchResponse(maximumBytes: maximumBytes)
    }

    func endFetchResponse() {
        collector.endFetchResponse()
    }

    func startTLS(hostname: String) async throws {
        // TLS handshake reads must stay enabled. Normal response backpressure
        // resumes after the upgrade has completed.
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
        try await tls.upgrade(channel, hostname)
        try await channel.setOption(ChannelOptions.autoRead, value: true).get()
        _isSecure = true
    }

    func close() async {
        // Finishing first wakes a suspended consumer and drains already-yielded
        // responses in order; the channel close then prevents another read.
        collector.finish()
        if channel.isActive {
            try? await channel.close()
        }
    }
}


struct TLSUpgrader: Sendable {
    var upgrade: @Sendable (Channel, String) async throws -> Void

    /// Production STARTTLS: insert NIOSSL at the head of the pipeline and wait for handshake.
    static let nioSSL = TLSUpgrader { channel, hostname in
        try await IMAPTLS.upgrade(channel: channel, hostname: hostname)
    }

    /// Tests: treat STARTTLS as already complete (bytes stay in the clear on the testing channel).
    static let passthrough = TLSUpgrader { _, _ in }
}

enum IMAPTLS {
    /// Drops contexts whose trust roots no longer match the effective
    /// configuration. Called whenever QA roots are installed or reset.
    static func invalidateContextCache() {
        MailTLS.invalidateContextCache()
    }

    /// Creates (or reuses) a context for the complete trust configuration.
    /// This method intentionally runs before a channel initializer: loading
    /// system anchors is blocking disk/platform work and must not run on NIO.
    static func makeClientContext(hostname: String) throws -> NIOSSLContext {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw IMAPError.tls("Missing hostname for TLS verification")
        }
        // Take one root snapshot and use it for both IP-literal permission and
        // context construction. A concurrent QA-root reset can therefore
        // never turn an opted-in IP endpoint into a nil-SNI system-only TLS
        // context.
        let additionalPEM = IMAPTrust.additionalPEM()
        try IMAPTrust.requireHostnameVerification(for: host, additionalPEM: additionalPEM)
        do {
            return try MailTLS.clientContext(additionalPEM: additionalPEM)
        } catch {
            throw IMAPError.tls(error.localizedDescription)
        }
    }

    static func makeClientHandler(hostname: String) throws -> NIOSSLClientHandler {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalPEM = IMAPTrust.additionalPEM()
        let context = try makeClientContext(hostname: host)
        return try NIOSSLClientHandler(
            context: context,
            serverHostname: IMAPTrust.sniHostname(for: host, additionalPEM: additionalPEM)
        )
    }

    static func upgrade(channel: Channel, hostname: String) async throws {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalPEM = IMAPTrust.additionalPEM()
        let context = try makeClientContext(hostname: host)
        let serverHostname = IMAPTrust.sniHostname(for: host, additionalPEM: additionalPEM)
        let handshake = HandshakeWaiter()
        try await channel.pipeline.addHandler(handshake, position: .first)
        try await channel.eventLoop.submit {
            let ssl = try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
            try channel.pipeline.syncOperations.addHandler(ssl, position: .first)
        }.get()
        try await handshake.wait()
    }
}

final class HandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private var finished = false

    func handlerAdded(context: ChannelHandlerContext) {
        if promise == nil {
            promise = context.eventLoop.makePromise(of: Void.self)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent {
            switch tls {
            case .handshakeCompleted:
                finish(context: context, error: nil)
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(context: context, error: IMAPError.tls(String(describing: error)))
        context.fireErrorCaught(error)
    }

    func wait() async throws {
        guard let promise else {
            throw IMAPError.tls("TLS handshake waiter missing event loop")
        }
        do {
            try await promise.futureResult.get()
        } catch let error as IMAPError {
            throw error
        } catch {
            throw IMAPError.tls(String(describing: error))
        }
    }

    private func finish(context: ChannelHandlerContext, error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            promise?.fail(error)
        } else {
            promise?.succeed()
        }
        context.pipeline.removeHandler(self, promise: nil)
    }
}

final class ResponseCollectorDelegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
    weak var collector: ResponseCollector?

    func produceMore() {
        collector?.resumeReading()
    }

    func didTerminate() {
        collector?.consumerTerminated()
    }
}

final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    let stream: IMAPResponseStream
    private let source: IMAPResponseStream.Source
    private let delegate: ResponseCollectorDelegate
    private let stateLock = NSLock()
    private var channel: Channel?
    private var fetchLiteralBytes = 0
    private var fetchLiteralLimit = IMAPLimits.maximumPeekLiteralBytes
    private var fetching = false
    private var finished = false
    private var terminalError: Error?
    var onError: (@Sendable (Error) -> Void)?
    var lastError: Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return terminalError
    }

    init() {
        let delegate = ResponseCollectorDelegate()
        let sequence = IMAPResponseStream.makeSequence(
            backPressureStrategy: .init(
                lowWatermark: IMAPLimits.responseQueueLowWatermark,
                highWatermark: IMAPLimits.responseQueueHighWatermark
            ),
            finishOnDeinit: false,
            delegate: delegate
        )
        self.delegate = delegate
        self.source = sequence.source
        self.stream = sequence.sequence
        delegate.collector = self
    }

    /// Starts accounting for one serialized UID FETCH response set. The
    /// declared literal sizes are counted before they are yielded, so queued
    /// chunks and assembler-owned chunks share the caller's aggregate budget.
    func beginFetchResponse(maximumBytes: Int = IMAPLimits.maximumPeekLiteralBytes) {
        stateLock.lock()
        fetching = true
        fetchLiteralBytes = 0
        fetchLiteralLimit = min(
            IMAPLimits.maximumPeekLiteralBytes,
            max(0, maximumBytes)
        )
        stateLock.unlock()
    }

    func endFetchResponse() {
        stateLock.lock()
        fetching = false
        fetchLiteralBytes = 0
        fetchLiteralLimit = IMAPLimits.maximumPeekLiteralBytes
        stateLock.unlock()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        stateLock.lock()
        self.channel = context.channel
        stateLock.unlock()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        stateLock.lock()
        channel = nil
        stateLock.unlock()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        if case .fetch(.streamingBegin(_, let byteCount)) = response,
           !reserveFetchLiteralBytes(byteCount) {
            fail(IMAPError.responseTooLarge(limit: currentFetchLimit()), channel: context.channel)
            return
        }

        switch source.yield(response) {
        case .produceMore:
            break
        case .stopProducing:
            // NIO may have already delivered one read. The producer's own
            // element buffer drains below the low watermark before this is
            // re-enabled by `produceMore()`.
            pauseReading(context: context)
        case .dropped:
            // A dropped value means the sole consumer terminated. Close the
            // channel rather than silently losing a server response.
            fail(IMAPError.transport("Response consumer terminated"), channel: context.channel)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, channel: context.channel)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishSource()
        context.fireChannelInactive()
    }

    func finish() {
        finishSource()
    }

    private func reserveFetchLiteralBytes(_ byteCount: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard fetching, byteCount >= 0 else { return true }
        guard byteCount <= fetchLiteralLimit - fetchLiteralBytes else {
            return false
        }
        fetchLiteralBytes += byteCount
        return true
    }

    private func currentFetchLimit() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return fetchLiteralLimit
    }

    private func fail(_ error: Error, channel: Channel) {
        stateLock.lock()
        let shouldNotify = !finished
        if shouldNotify {
            terminalError = error
        }
        finished = true
        stateLock.unlock()
        guard shouldNotify else { return }
        onError?(error)
        source.finish()
        channel.close(promise: nil)
    }

    private func finishSource() {
        stateLock.lock()
        let shouldFinish = !finished
        finished = true
        stateLock.unlock()
        if shouldFinish {
            source.finish()
        }
    }

    private func pauseReading(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { [weak self] error in
            self?.fail(error, channel: channel)
        }
    }

    func resumeReading() {
        stateLock.lock()
        let channel = self.channel
        stateLock.unlock()
        guard let channel else { return }
        channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { [weak self] error in
            self?.fail(error, channel: channel)
        }
    }

    func consumerTerminated() {
        stateLock.lock()
        let channel = self.channel
        stateLock.unlock()
        channel?.close(promise: nil)
    }
}

enum IMAPNetwork {
    static func connect(
        endpoint: IMAPEndpoint,
        group: EventLoopGroup
    ) async throws -> IMAPConnection {
        let implicit = endpoint.security == .implicitTLS
        let collector = ResponseCollector()
        let handshake = implicit ? HandshakeWaiter() : nil
        // Context construction may read the system trust store. Do it before
        // entering the channel initializer, which always runs on a NIO loop.
        let additionalPEM = IMAPTrust.additionalPEM()
        let implicitTLSContext = implicit
            ? try IMAPTLS.makeClientContext(hostname: endpoint.host)
            : nil

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.submit {
                    if implicit, let implicitTLSContext {
                        let ssl = try NIOSSLClientHandler(
                            context: implicitTLSContext,
                            serverHostname: IMAPTrust.sniHostname(
                                for: endpoint.host,
                                additionalPEM: additionalPEM
                            )
                        )
                        try channel.pipeline.syncOperations.addHandler(ssl)
                        if let handshake {
                            try channel.pipeline.syncOperations.addHandler(handshake)
                        }
                    }
                    try channel.pipeline.syncOperations.addHandler(
                        IMAPClientHandler(
                            parserOptions: ResponseParser.Options(
                                bufferLimit: IMAPLimits.maxBytes,
                                literalSizeLimit: IMAPLimits.maxBytes
                            ),
                            maximumBufferSize: IMAPLimits.maxBytes
                        )
                    )
                    try channel.pipeline.syncOperations.addHandler(collector)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            throw IMAPError.transport(String(describing: error))
        }

        if let handshake {
            do {
                try await handshake.wait()
            } catch let error as IMAPError {
                try? await channel.close()
                throw error
            } catch {
                try? await channel.close()
                throw IMAPError.tls(String(describing: error))
            }
        }

        return IMAPConnection(
            channel: channel,
            tls: .nioSSL,
            isSecure: implicit,
            collector: collector
        )
    }
}
