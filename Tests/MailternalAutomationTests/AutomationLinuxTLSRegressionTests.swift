#if os(Linux)
import Foundation
import NIO
import NIOEmbedded
import Testing
@testable import MailternalAutomation

struct AutomationLinuxTLSRegressionTests {
    @Test func leafPinMatchesOnlyTheExactCertificateDigest() throws {
        let certificateDER = Data("fixture-certificate-der".utf8)
        let fingerprint = AutomationTLSIdentityStore.fingerprint(certificateDER: certificateDER)

        #expect(
            AutomationLinuxTLSVerifier.matches(
                certificateDER: Array(certificateDER),
                pinnedFingerprint: fingerprint.uppercased()
            )
        )
        let mismatched = String(repeating: "0", count: 64)
        #expect(
            !AutomationLinuxTLSVerifier.matches(
                certificateDER: Array(certificateDER),
                pinnedFingerprint: mismatched
            )
        )
        #expect(
            !AutomationLinuxTLSVerifier.matches(
                certificateDER: Array(certificateDER),
                pinnedFingerprint: String(repeating: "g", count: 64)
            )
        )
    }

    @Test func decoderPreservesSplitAndCoalescedObserverFrames() throws {
        let firstID = UUID()
        let secondID = UUID()
        var encoded = try AutomationLineCodec.encode(AutomationResponse(requestID: firstID, ok: true))
        encoded.append(contentsOf: try AutomationLineCodec.encode(AutomationResponse(requestID: secondID, ok: true)))

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(AutomationLinuxNDJSONDecoder())
        )

        let firstLineEnd = try #require(encoded.firstIndex(of: 0x0A))
        let splitPoint = max(1, firstLineEnd / 2)
        var firstPart = channel.allocator.buffer(capacity: splitPoint)
        firstPart.writeBytes(encoded.prefix(splitPoint))
        try channel.writeInbound(firstPart)
        #expect(try channel.readInbound(as: Data.self) == nil)

        var secondPart = channel.allocator.buffer(capacity: encoded.count - splitPoint)
        secondPart.writeBytes(encoded.suffix(from: splitPoint))
        try channel.writeInbound(secondPart)
        let first = try #require(try channel.readInbound(as: Data.self))
        let second = try #require(try channel.readInbound(as: Data.self))
        #expect(try AutomationLineCodec.decode(AutomationResponse.self, from: first).requestID == firstID)
        #expect(try AutomationLineCodec.decode(AutomationResponse.self, from: second).requestID == secondID)
        #expect(try channel.readInbound(as: Data.self) == nil)
    }

    @Test func preCancelledRequestReturnsCancellation() async throws {
        let client = try AutomationTLSSocketClient(
            host: "127.0.0.1",
            port: 1,
            bearerToken: "bearer-that-must-not-be-written",
            pinnedFingerprint: String(repeating: "0", count: 64)
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.request(AutomationRequest(token: "ignored", origin: .pairedRemote, wantsState: true))
        }
        do {
            _ = try await task.value
            Issue.record("cancelled request unexpectedly completed")
        } catch is CancellationError {
            // Expected: Task.checkCancellation() runs before DNS/connect or wire writes.
        }
    }
}
#endif
