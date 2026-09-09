#if os(Linux)
import Foundation
import NIO
import NIOSSL
import NIOTLS
#if canImport(Crypto)
import Crypto
#endif

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// The Linux client uses NIO's shared event loops and NIOSSL's handshake callback.
/// The callback rejects every leaf that is not the paired certificate before the
/// TLS handler releases any buffered writes.
internal enum AutomationLinuxTLSVerifier {
    static func matches(certificateDER: [UInt8], pinnedFingerprint: String) -> Bool {
        guard let expected = decodeHex(pinnedFingerprint), expected.count == 32 else { return false }
        let actual = Array(Crypto.SHA256.hash(data: Data(certificateDER)))
        var difference = UInt8(actual.count ^ expected.count)
        for (left, right) in zip(actual, expected) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func decodeHex(_ value: String) -> [UInt8]? {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(32)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[offset]), let low = nibble(bytes[offset + 1]) else {
                return nil
            }
            result.append((high << 4) | low)
        }
        return result
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}

private final class AutomationLinuxTLSRuntime: @unchecked Sendable {
    private static let sharedResult: Result<AutomationLinuxTLSRuntime, Error> = Result(
        catching: { try AutomationLinuxTLSRuntime() }
    )

    let eventLoops: MultiThreadedEventLoopGroup
    let sslContext: NIOSSLContext

    static func shared() throws -> AutomationLinuxTLSRuntime {
        try sharedResult.get()
    }

    private init() throws {
        // Keep one process-wide group. Creating a thread pool for each CLI call
        // leaks threads and defeats NIO's event-loop ownership model.
        eventLoops = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        var configuration = TLSConfiguration.makeClientConfiguration()
        // Pairing supplies the trust root. The callback below performs the
        // complete leaf-pin decision, so no system CA is accepted accidentally.
        configuration.certificateVerification = .optionalVerification
        sslContext = try NIOSSLContext(configuration: configuration)
    }
}

private final class AutomationLinuxChannelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var cancelled = false

    func install(_ channel: Channel) {
        let key = ObjectIdentifier(channel)
        let closeNow = lock.withLock {
            if cancelled { return true }
            channels[key] = channel
            return false
        }
        if closeNow {
            channel.close(promise: nil)
        } else {
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.channels.removeValue(forKey: key) }
            }
        }
    }

    func cancel() {
        let channels = lock.withLock {
            cancelled = true
            let active = Array(self.channels.values)
            self.channels.removeAll()
            return active
        }
        for channel in channels { channel.close(promise: nil) }
    }
}

private final class AutomationLinuxTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: Scheduled<Void>?
    private var expired = false
    private var cancelled = false

    var didExpire: Bool { lock.withLock { expired } }

    func arm(on eventLoop: EventLoop, channel: Channel, duration: TimeAmount = .seconds(30)) {
        let scheduled = eventLoop.scheduleTask(in: duration) { [weak self, channel] in
            guard let self else {
                channel.close(promise: nil)
                return
            }
            self.lock.withLock { self.expired = true }
            channel.close(promise: nil)
        }
        lock.lock()
        self.scheduled = scheduled
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { scheduled.cancel() }
    }

    func cancel() {
        let scheduled = lock.withLock {
            cancelled = true
            return self.scheduled
        }
        scheduled?.cancel()
    }
}

/// The handshake event is deliberately kept separate from channelActive:
/// NIOSSL fires channelActive before its handshake has completed.
private final class AutomationLinuxTLSHandshakeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    let handshakePromise: EventLoopPromise<Void>
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        handshakePromise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent,
           case .handshakeCompleted = tlsEvent,
           !completed {
            completed = true
            handshakePromise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failIfNeeded(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failIfNeeded(AutomationSecurityError.socketUnavailable)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Failed/cancelled connect candidates were never active, so NIO need
        // not emit channelInactive before removing their pipeline.
        failIfNeeded(AutomationSecurityError.socketUnavailable)
    }

    private func failIfNeeded(_ error: Error) {
        guard !completed else { return }
        completed = true
        handshakePromise.fail(error)
    }

}

/// Adapts the existing AutomationFrameBuffer to NIO's bounded async channel.
/// The wire grammar remains the shared newline-delimited AutomationLineCodec.
internal final class AutomationLinuxNDJSONDecoder: ByteToMessageDecoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = Data

    private let frameBuffer = AutomationFrameBuffer()

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if buffer.readableBytes > 0 {
            frameBuffer.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
        }
        var emitted = false
        while let frame = try frameBuffer.nextFrame() {
            emitted = true
            context.fireChannelRead(Self.wrapInboundOut(frame))
        }
        return emitted ? .continue : .needMoreData
    }

    func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }
}

private struct AutomationLinuxConnectedChannel: Sendable {
    let asyncChannel: NIOAsyncChannel<Data, ByteBuffer>
    let handshake: EventLoopFuture<Void>
}

public final class AutomationTLSSocketClient: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let bearerToken: String
    public let clientID: UUID?
    public let pinnedFingerprint: String

    public init(host: String, port: UInt16, bearerToken: String, clientID: UUID? = nil,
                pinnedFingerprint: String) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = pinnedFingerprint.lowercased()
        guard !normalizedHost.isEmpty, port != 0,
              normalizedFingerprint.count == 64,
              normalizedFingerprint.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw AutomationSecurityError.invalidConfiguration
        }
        self.host = normalizedHost
        self.port = port
        self.bearerToken = bearerToken
        self.clientID = clientID
        self.pinnedFingerprint = normalizedFingerprint
    }

    public func claim(code: String, clientName: String? = nil) async throws -> AutomationPairedEndpoint {
        let claimRequest = AutomationRequest(
            token: "",
            origin: .pairedRemote,
            control: .pairingClaim,
            pairingCode: code,
            pairingClientName: clientName
        )
        let response = try await request(claimRequest)
        guard response.ok, let data = response.result else {
            throw AutomationSecurityError.notPaired
        }
        return try AutomationLineCodec.decode(AutomationPairingClaimResult.self, from: data).endpoint
    }

    public func request(_ request: AutomationRequest) async throws -> AutomationResponse {
        let slot = AutomationLinuxChannelSlot()
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                let connection = try await connect(using: slot)
                defer { connection.asyncChannel.channel.close(promise: nil) }
                try await waitForHandshake(connection, slot: slot)
                let authenticatedRequest = replacingToken(in: request)
                let encoded = try AutomationLineCodec.encode(authenticatedRequest)
                return try await connection.asyncChannel.executeThenClose { inbound, outbound in
                    try await Self.sendFrame(
                        encoded,
                        through: outbound,
                        channel: connection.asyncChannel.channel
                    )
                    var iterator = inbound.makeAsyncIterator()
                    let frame = try await Self.receiveFrame(
                        from: &iterator,
                        channel: connection.asyncChannel.channel
                    )
                    return try AutomationLineCodec.decode(AutomationResponse.self, from: frame)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }, onCancel: {
            slot.cancel()
        })
    }

    public func observe(
        _ request: AutomationRequest,
        onResponse: @escaping @Sendable (AutomationResponse) async -> Void
    ) async throws {
        let slot = AutomationLinuxChannelSlot()
        try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                let connection = try await connect(using: slot)
                defer { connection.asyncChannel.channel.close(promise: nil) }
                try await waitForHandshake(connection, slot: slot)
                let observerRequest = replacingToken(in: request, observesState: true)
                let encoded = try AutomationLineCodec.encode(observerRequest)
                try await connection.asyncChannel.executeThenClose { inbound, outbound in
                    try await Self.sendFrame(
                        encoded,
                        through: outbound,
                        channel: connection.asyncChannel.channel
                    )
                    var iterator = inbound.makeAsyncIterator()
                    while true {
                        let frame = try await Self.receiveFrame(
                            from: &iterator,
                            channel: connection.asyncChannel.channel,
                            deadline: nil
                        )
                        let response = try AutomationLineCodec.decode(AutomationResponse.self, from: frame)
                        await onResponse(response)
                    }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        }, onCancel: {
            slot.cancel()
        })
    }

    private func replacingToken(
        in request: AutomationRequest,
        observesState: Bool? = nil
    ) -> AutomationRequest {
        AutomationRequest(
            requestID: request.requestID,
            token: bearerToken,
            origin: request.origin,
            clientID: clientID?.uuidString,
            command: request.command,
            control: request.control,
            wantsState: request.wantsState,
            wantsGUIState: request.wantsGUIState,
            observesState: observesState ?? request.observesState,
            afterRevision: request.afterRevision,
            secret: request.secret,
            pairingCode: request.pairingCode,
            pairingClientName: request.pairingClientName,
            pairingGrant: request.pairingGrant,
            transferID: request.transferID,
            transferOffset: request.transferOffset,
            transferLength: request.transferLength,
            transferSequence: request.transferSequence,
            transferTotalBytes: request.transferTotalBytes,
            transferData: request.transferData,
            transferFinal: request.transferFinal,
            transferFilename: request.transferFilename,
            transferContentType: request.transferContentType
        )
    }

    private func connect(using slot: AutomationLinuxChannelSlot) async throws -> AutomationLinuxConnectedChannel {
        let runtime = try AutomationLinuxTLSRuntime.shared()
        let pin = pinnedFingerprint
        // Certificate pinning supplies identity; SNI is sent only for DNS names.
        let serverName = (try? SocketAddress(ipAddress: host, port: Int(port))) == nil ? host : nil
        // NIOAsyncChannel bounds reads through the pipeline. Disabling autoRead
        // prevents split NDJSON frames from completing and yielding an element.
        let bootstrap = ClientBootstrap(group: runtime.eventLoops)
            .channelOption(
                ChannelOptions.recvAllocator,
                value: AdaptiveRecvByteBufferAllocator(minimum: 1, initial: 16 * 1024, maximum: 16 * 1024)
            )
            .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .connectTimeout(.seconds(30))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    slot.install(channel)
                    let tls = try NIOSSLClientHandler(
                        context: runtime.sslContext,
                        serverHostname: serverName,
                        customVerificationCallback: { certificates, promise in
                            guard let leaf = certificates.first,
                                  let der = try? leaf.toDERBytes(),
                                  AutomationLinuxTLSVerifier.matches(
                                      certificateDER: der,
                                      pinnedFingerprint: pin
                                  ) else {
                                promise.succeed(.failed)
                                return
                            }
                            promise.succeed(.certificateVerified)
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(tls, position: .first)
                    let handshake = AutomationLinuxTLSHandshakeHandler(
                        promise: channel.eventLoop.makePromise(of: Void.self)
                    )
                    try channel.pipeline.syncOperations.addHandler(handshake)
                    try channel.pipeline.syncOperations.addHandler(BackPressureHandler())
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(AutomationLinuxNDJSONDecoder())
                    )
                }
            }

        let future = bootstrap.connect(host: host, port: Int(port))
        let connectionFuture = future.flatMapThrowing { channel in
            let handshake = try channel.pipeline.syncOperations.handler(
                type: AutomationLinuxTLSHandshakeHandler.self
            )
            let configuration = NIOAsyncChannel<Data, ByteBuffer>.Configuration(
                backPressureStrategy: .init(lowWatermark: 1, highWatermark: 4),
                isOutboundHalfClosureEnabled: false
            )
            return AutomationLinuxConnectedChannel(
                asyncChannel: try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: configuration
                ),
                handshake: handshake.handshakePromise.futureResult
            )
        }
        do {
            return try await connectionFuture.get()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func waitForHandshake(
        _ connection: AutomationLinuxConnectedChannel,
        slot: AutomationLinuxChannelSlot
    ) async throws {
        let timeout = AutomationLinuxTimeout()
        timeout.arm(on: connection.asyncChannel.channel.eventLoop, channel: connection.asyncChannel.channel)
        defer { timeout.cancel() }
        do {
            try await connection.handshake.get()
        } catch {
            slot.cancel()
            if Task.isCancelled { throw CancellationError() }
            if timeout.didExpire { throw AutomationSecurityError.socketUnavailable }
            throw error
        }
    }

    private static func sendFrame(
        _ data: Data,
        through writer: NIOAsyncChannelOutboundWriter<ByteBuffer>,
        channel: Channel
    ) async throws {
        let timeout = AutomationLinuxTimeout()
        timeout.arm(on: channel.eventLoop, channel: channel)
        defer { timeout.cancel() }
        do {
            try await writer.write(makeBuffer(data, allocator: channel.allocator))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if timeout.didExpire { throw AutomationSecurityError.socketUnavailable }
            throw error
        }
    }

    private static func makeBuffer(_ data: Data, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    private static func receiveFrame(
        from iterator: inout NIOAsyncChannelInboundStream<Data>.AsyncIterator,
        channel: Channel,
        deadline: TimeAmount? = .seconds(30)
    ) async throws -> Data {
        // Observers are allowed to be silent indefinitely. Request and handshake
        // deadlines remain bounded; cancellation still closes the owned channels.
        let timeout = deadline.map { duration in
            let timeout = AutomationLinuxTimeout()
            timeout.arm(on: channel.eventLoop, channel: channel, duration: duration)
            return timeout
        }
        defer { timeout?.cancel() }
        do {
            guard let frame = try await iterator.next() else {
                throw AutomationSecurityError.socketUnavailable
            }
            if timeout?.didExpire == true { throw AutomationSecurityError.socketUnavailable }
            return frame
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if timeout?.didExpire == true { throw AutomationSecurityError.socketUnavailable }
            throw error
        }
    }
}
#endif
