import Foundation
import Testing
@testable import MailternalAutomation

struct TransportFramingTests {
    @Test func coalescedObserverResponsesRemainOrdered() throws {
        let firstID = UUID()
        let secondID = UUID()
        var coalesced = try AutomationLineCodec.encode(AutomationResponse(requestID: firstID, ok: true))
        coalesced.append(contentsOf: try AutomationLineCodec.encode(AutomationResponse(requestID: secondID, ok: true)))

        let frames = AutomationFrameBuffer()
        frames.append(coalesced)

        let first = try AutomationLineCodec.decode(AutomationResponse.self, from: try #require(try frames.nextFrame()))
        let second = try AutomationLineCodec.decode(AutomationResponse.self, from: try #require(try frames.nextFrame()))
        #expect(first.requestID == firstID)
        #expect(second.requestID == secondID)
        #expect(try frames.nextFrame() == nil)
    }

    @Test func splitFrameWaitsForItsTerminatingNewline() throws {
        let responseID = UUID()
        let encoded = try AutomationLineCodec.encode(AutomationResponse(requestID: responseID, ok: true))
        let frames = AutomationFrameBuffer()
        frames.append(encoded.dropLast())
        #expect(try frames.nextFrame() == nil)

        frames.append(encoded.suffix(1))
        let response = try AutomationLineCodec.decode(AutomationResponse.self, from: try #require(try frames.nextFrame()))
        #expect(response.requestID == responseID)
    }

    @Test func oversizedIndividualFrameIsRejectedAfterEarlierFrame() throws {
        let frames = AutomationFrameBuffer()
        frames.append(Data("complete\n".utf8))
        frames.append(Data(repeating: 0x78, count: AutomationLineCodec.maximumFrameBytes + 1))
        frames.append(Data([0x0A]))

        #expect(try frames.nextFrame() == Data("complete".utf8))
        #expect(throws: AutomationSecurityError.requestTooLarge) {
            _ = try frames.nextFrame()
        }
    }
}
