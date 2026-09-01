import Foundation
import MailternalInterfaces
import NIO
import NIOIMAP
import NIOSSL
import NIOTLS

/// Byte-level IMAP connection: a NIO `Channel` with `IMAPClientHandler` plus a
/// response stream. Production uses TCP + NIOSSL; tests inject an
/// `NIOAsyncTestingChannel`.
final class IMAPConnection: @unchecked Sendable {
    let channel: Channel
    let responses: AsyncStream<Response>
    private let responseContinuation: AsyncStream<Response>.Continuation
    private let tls: TLSUpgrader
    // Touched from the session actor only after construction.
    private var _isSecure: Bool
    private(set) var lastHandlerError: Error?

    var isSecure: Bool { _isSecure }

    init(channel: Channel, tls: TLSUpgrader, isSecure: Bool, collector: ResponseCollector) {
        self.channel = channel
        self.tls = tls
        self._isSecure = isSecure
        self.responses = collector.stream
        self.responseContinuation = collector.continuation
        collector.onError = { [weak self] error in
            self?.lastHandlerError = error
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

    func startTLS(hostname: String) async throws {
        try await tls.upgrade(channel, hostname)
        _isSecure = true
    }

    func close() async {
        responseContinuation.finish()
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
    static func makeClientHandler(hostname: String) throws -> NIOSSLClientHandler {
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw IMAPError.tls("Missing hostname for TLS verification")
        }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        // System trust roots (the default). Never `.none` / empty pins.
        let context = try NIOSSLContext(configuration: configuration)
        return try NIOSSLClientHandler(context: context, serverHostname: host)
    }

    static func upgrade(channel: Channel, hostname: String) async throws {
        let ssl = try makeClientHandler(hostname: hostname)
        let handshake = HandshakeWaiter()
        try await channel.pipeline.addHandler(handshake, position: .first)
        try await channel.pipeline.addHandler(ssl, position: .first)
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

final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    let stream: AsyncStream<Response>
    let continuation: AsyncStream<Response>.Continuation
    var onError: (@Sendable (Error) -> Void)?

    init() {
        var captured: AsyncStream<Response>.Continuation!
        self.stream = AsyncStream { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError?(error)
        continuation.finish()
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
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

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.submit {
                    if implicit {
                        let ssl = try IMAPTLS.makeClientHandler(hostname: endpoint.host)
                        try channel.pipeline.syncOperations.addHandler(ssl)
                        if let handshake {
                            try channel.pipeline.syncOperations.addHandler(handshake)
                        }
                    }
                    try channel.pipeline.syncOperations.addHandler(IMAPClientHandler())
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
