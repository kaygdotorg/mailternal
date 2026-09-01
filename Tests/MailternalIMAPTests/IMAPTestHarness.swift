import Foundation
import MailternalInterfaces
import NIO
import NIOEmbedded
import NIOIMAP
import Testing
@testable import MailternalIMAP

/// In-memory IMAP client+server pair over `NIOAsyncTestingChannel`.
final class ScriptedIMAP: @unchecked Sendable {
    let channel: NIOAsyncTestingChannel
    let session: IMAPSession
    let group: EventLoopGroup
    private var outboundRemainder = ""
    let recordedClientLines: Box<[String]>

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    static func make(
        host: String = "imap.example.com",
        security: IMAPEndpoint.Security = .startTLS
    ) async throws -> ScriptedIMAP {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = NIOAsyncTestingChannel()
        let collector = ResponseCollector()
        try await channel.pipeline.addHandler(IMAPClientHandler())
        try await channel.pipeline.addHandler(collector)
        _ = try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993))
        let connection = IMAPConnection(
            channel: channel,
            tls: .passthrough,
            isSecure: security == .implicitTLS,
            collector: collector
        )
        let port = security == .implicitTLS ? 993 : 143
        let session = IMAPSession(
            endpoint: IMAPEndpoint(host: host, port: port, security: security),
            username: "alice",
            password: "secret",
            connection: connection,
            eventLoopGroup: group
        )
        return ScriptedIMAP(channel: channel, session: session, group: group)
    }

    init(channel: NIOAsyncTestingChannel, session: IMAPSession, group: EventLoopGroup) {
        self.channel = channel
        self.session = session
        self.group = group
        self.recordedClientLines = Box([])
    }

    func shutdown() async {
        await session.close()
        _ = try? await channel.finish()
        try? await group.shutdownGracefully()
    }

    func writeServer(_ line: String) async throws {
        var text = line
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        try await channel.writeInbound(ByteBuffer(string: text))
    }

    func readClientLine() async throws -> String {
        if let line = popLine() { return line }
        while true {
            let buffer: ByteBuffer
            do {
                buffer = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
            } catch {
                throw IMAPError.transport("Client outbound: \(error)")
            }
            outboundRemainder += String(decoding: buffer.readableBytesView, as: UTF8.self)
            if let line = popLine() { return line }
        }
    }

    @discardableResult
    func expectCommand(containing needle: String? = nil) async throws -> (tag: String, line: String) {
        let line = try await readClientLine()
        recordedClientLines.value.append(line)
        let tag = String(line.split(separator: " ", maxSplits: 1).first ?? "")
        if let needle {
            #expect(
                line.uppercased().contains(needle.uppercased()),
                "expected \(needle) in \(line)"
            )
        }
        return (tag, line)
    }

    func ok(_ tag: String, _ text: String = "completed") async throws {
        try await writeServer("\(tag) OK \(text)")
    }

    func no(_ tag: String, _ text: String = "failed") async throws {
        try await writeServer("\(tag) NO \(text)")
    }

    func capability(_ tag: String, _ tokens: String) async throws {
        try await writeServer("* CAPABILITY \(tokens)")
        try await ok(tag, "CAPABILITY completed")
    }

    static let fullCaps =
        "IMAP4rev1 STARTTLS AUTH=PLAIN SASL-IR IDLE ENABLE QRESYNC CONDSTORE SPECIAL-USE LIST-STATUS OBJECTID"
    static let postTLSCaps =
        "IMAP4rev1 AUTH=PLAIN SASL-IR IDLE ENABLE QRESYNC CONDSTORE SPECIAL-USE LIST-STATUS OBJECTID"

    /// Greeting through AUTH for a mandatory-STARTTLS session (passthrough upgrade).
    func connectStartTLS(
        preTLS: String = ScriptedIMAP.fullCaps,
        postTLS: String = ScriptedIMAP.postTLSCaps,
        postAuth: String = ScriptedIMAP.postTLSCaps
    ) async throws {
        let connecting = Task { try await session.connect() }
        try await writeServer("* OK IMAP4rev1 ready")
        var (tag, _) = try await expectCommand(containing: "CAPABILITY")
        try await capability(tag, preTLS)
        (tag, _) = try await expectCommand(containing: "STARTTLS")
        try await ok(tag, "Begin TLS")
        (tag, _) = try await expectCommand(containing: "CAPABILITY")
        try await capability(tag, postTLS)
        (tag, _) = try await expectCommand(containing: "AUTHENTICATE")
        try await ok(tag, "Logged in")
        (tag, _) = try await expectCommand(containing: "CAPABILITY")
        try await capability(tag, postAuth)
        try await connecting.value
    }

    /// Greeting through AUTH when the testing channel is already "implicit TLS".
    func connectImplicit(caps: String = ScriptedIMAP.postTLSCaps) async throws {
        let connecting = Task { try await session.connect() }
        try await writeServer("* OK IMAP4rev1 ready")
        var (tag, _) = try await expectCommand(containing: "CAPABILITY")
        try await capability(tag, caps)
        (tag, _) = try await expectCommand(containing: "AUTHENTICATE")
        try await ok(tag, "Logged in")
        (tag, _) = try await expectCommand(containing: "CAPABILITY")
        try await capability(tag, caps)
        try await connecting.value
    }

    static func run(
        host: String = "imap.example.com",
        security: IMAPEndpoint.Security = .startTLS,
        _ body: (ScriptedIMAP) async throws -> Void
    ) async throws {
        let imap = try await make(host: host, security: security)
        do {
            try await body(imap)
        } catch {
            await imap.shutdown()
            throw error
        }
        await imap.shutdown()
    }

    private func popLine() -> String? {
        guard let range = outboundRemainder.range(of: "\r\n") else { return nil }
        let line = String(outboundRemainder[..<range.lowerBound])
        outboundRemainder.removeSubrange(..<range.upperBound)
        return line
    }
}
