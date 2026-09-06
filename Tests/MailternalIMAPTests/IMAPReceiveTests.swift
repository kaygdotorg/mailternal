import Foundation
import NIO
import NIOIMAP
import NIOEmbedded
import Testing
@testable import MailternalIMAP

@Test func fetchAssemblerRejectsAggregateLiteralBudgetBeforeAccumulation() throws {
    var assembler = IMAPFetchAssembler(maximumLiteralBytes: 4)
    let kind = StreamingKind.body(section: .text, offset: nil)

    for value in 1...4 {
        try assembler.apply(.start(SequenceNumber(rawValue: UInt32(value))))
        try assembler.apply(.streamingBegin(kind: kind, byteCount: 1))
        let body = ByteBuffer(string: "x")
        try assembler.apply(.streamingBytes(body))
        try assembler.apply(.streamingEnd)
        try assembler.apply(.finish)
    }

    #expect(throws: IMAPError.responseTooLarge(limit: 4)) {
        try assembler.apply(.streamingBegin(kind: kind, byteCount: 1))
    }
}

@Test func responseCollectorDrainsEveryYieldAcrossReadWatermarks() async throws {
    let channel = NIOAsyncTestingChannel()
    let collector = ResponseCollector()
    try await channel.pipeline.addHandler(collector)
    _ = try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 993))

    let consumer = Task { () -> [UInt32] in
        var iterator = collector.stream.makeAsyncIterator()
        var values: [UInt32] = []
        while let response = await iterator.next() {
            if case .fetch(.start(let sequence)) = response {
                values.append(sequence.rawValue)
            }
            await Task.yield()
        }
        return values
    }

    for value in 1...64 {
        _ = try await channel.writeInbound(
            Response.fetch(.start(SequenceNumber(rawValue: UInt32(value))))
        )
        _ = try await channel.writeInbound(Response.fetch(.finish))
    }
    collector.finish()

    let values = await consumer.value
    #expect(values == Array(UInt32(1)...UInt32(64)))
    _ = try? await channel.finish()
}
