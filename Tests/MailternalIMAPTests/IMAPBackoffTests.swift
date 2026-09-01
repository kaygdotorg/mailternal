import Foundation
import Testing
@testable import MailternalIMAP

@Test func reconnectBackoffGrowsAndHonorsCap() {
    let backoff = IMAPReconnectBackoff(base: 1, cap: 8, jitterFraction: 0)
    #expect(backoff.delay(forAttempt: 1, unitRandom: 0.5) == 1)
    #expect(backoff.delay(forAttempt: 2, unitRandom: 0.5) == 2)
    #expect(backoff.delay(forAttempt: 3, unitRandom: 0.5) == 4)
    #expect(backoff.delay(forAttempt: 4, unitRandom: 0.5) == 8)
    #expect(backoff.delay(forAttempt: 10, unitRandom: 0.5) == 8)
}

@Test func reconnectBackoffJitterIsDeterministicWithUnitRandom() {
    let low = IMAPReconnectBackoff.delay(attempt: 1, base: 1, cap: 10, jitterFraction: 0.2, unitRandom: 0)
    let high = IMAPReconnectBackoff.delay(attempt: 1, base: 1, cap: 10, jitterFraction: 0.2, unitRandom: 1)
    #expect(abs(low - 0.8) < 1e-9)
    #expect(abs(high - 1.2) < 1e-9)
    #expect(low < high)
}

@Test func recommendedDeltaPathFollowsCapabilities() {
    #expect(IMAPCapabilities(tokens: ["QRESYNC", "CONDSTORE"]).recommendedDeltaPath == .qresync)
    #expect(IMAPCapabilities(tokens: ["CONDSTORE"]).recommendedDeltaPath == .condstore)
    #expect(IMAPCapabilities(tokens: ["IMAP4rev1"]).recommendedDeltaPath == .basic)
}

@Test func peekSectionHasNoNonPeekAPI() {
    let complete = IMAPPeekSection.complete
    #expect(complete.binary == false)
    #expect(IMAPPeekSection.binaryPart("1").binary == true)
    let request = IMAPFetchRequest.peek(uids: IMAPUIDSet(uid: 1), section: .text)
    #expect(request.peek.count == 1)
    #expect(request.peek[0].specifier == "TEXT")
}
