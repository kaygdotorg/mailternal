import Foundation
import XCTest
import MailternalSanitizer

@MainActor
final class MessageWebTests: XCTestCase {
    func testRemotePartProviderWaitsForConsent() async throws {
        let handler = PartSchemeHandler()
        let counter = CallCounter()
        let remote = URL(string: "https://images.example.test/logo.png")!
        let provider: PartProvider = { _ in
            await counter.increment()
            return (Data([0x89, 0x50, 0x4E, 0x47]), "image/png")
        }
        let token = PartURL.url(for: .remote(remote))

        let blocked = try await handler.resolve(token, provider: provider, remoteAllowed: false)
        let blockedCalls = await counter.value
        XCTAssertEqual(blockedCalls, 0)
        XCTAssertEqual(blocked.1, "image/png")

        let allowed = try await handler.resolve(token, provider: provider, remoteAllowed: true)
        let allowedCalls = await counter.value
        XCTAssertEqual(allowedCalls, 1)
        XCTAssertEqual(allowed.0, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testCIDPartLoadsWithoutRemoteConsent() async throws {
        let handler = PartSchemeHandler()
        let counter = CallCounter()
        let provider: PartProvider = { reference in
            await counter.increment()
            XCTAssertEqual(reference, "cid:logo.0@mailternal.test")
            return (Data([1, 2, 3]), "image/png")
        }
        let token = PartURL.url(for: .cid("logo.0@mailternal.test"))

        let result = try await handler.resolve(token, provider: provider, remoteAllowed: false)
        let cidCalls = await counter.value
        XCTAssertEqual(cidCalls, 1)
        XCTAssertEqual(result.0, Data([1, 2, 3]))
        XCTAssertEqual(result.1, "image/png")
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
