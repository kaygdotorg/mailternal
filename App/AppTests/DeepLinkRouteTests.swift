import XCTest
import MailternalInterfaces

@MainActor
final class DeepLinkRouteTests: XCTestCase {
    private let account = AccountLinkID(
        uuidString: "123e4567-e89b-42d3-a456-426614174000"
    )!

    func testParserRejectsMalformedDeepLinkWithoutFallback() {
        let valid = "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/SU5CT1g/message/1/2"
        XCTAssertNotNil(MailternalDeepLink(string: valid))
        XCTAssertNil(MailternalDeepLink(string: valid + "?account=local"))
        XCTAssertNil(MailternalDeepLink(string: valid.replacingOccurrences(of: "/1/2", with: "/01/2")))
        XCTAssertNil(MailternalDeepLink(string: valid.replacingOccurrences(of: "123e", with: "123E")))
    }

    func testRouteQueueWaitsForColdAccountAndFolders() async {
        let link = folderLink(path: "INBOX")
        var ready = false
        var routed: [MailternalDeepLink] = []
        let reachedRoute = expectation(description: "route runs after readiness")
        let queue = DeepLinkRouteQueue()
        queue.enqueue(
            link,
            isReady: { ready },
            route: { link in
                routed.append(link)
                reachedRoute.fulfill()
            }
        )

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(routed.isEmpty)
        ready = true
        await fulfillment(of: [reachedRoute], timeout: 1)
        XCTAssertEqual(routed, [link])
    }

    func testRouteQueueLastPendingLinkWins() async {
        let first = folderLink(path: "First")
        let second = folderLink(path: "Second")
        var ready = false
        var routed: [MailternalDeepLink] = []
        let reachedRoute = expectation(description: "only newest route runs")
        let queue = DeepLinkRouteQueue()
        queue.enqueue(
            first,
            isReady: { ready },
            route: { link in
                routed.append(link)
                reachedRoute.fulfill()
            }
        )
        queue.enqueue(
            second,
            isReady: { ready },
            route: { link in
                routed.append(link)
                reachedRoute.fulfill()
            }
        )

        ready = true
        await fulfillment(of: [reachedRoute], timeout: 1)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(routed, [second])
    }

    func testRouteQueueDoesNotSelectStaleTargetWhenSuperseded() async {
        let first = folderLink(path: "Stale")
        let second = folderLink(path: "Current")
        var ready = false
        var selected: MailternalDeepLink?
        let reachedRoute = expectation(description: "current target selected")
        let queue = DeepLinkRouteQueue()
        queue.enqueue(
            first,
            isReady: { ready },
            route: { link in selected = link }
        )
        queue.enqueue(
            second,
            isReady: { ready },
            route: { link in
                selected = link
                reachedRoute.fulfill()
            }
        )
        ready = true
        await fulfillment(of: [reachedRoute], timeout: 1)
        XCTAssertEqual(selected, second)
    }

    private func folderLink(path: String) -> MailternalDeepLink {
        .folder(
            accountLinkID: account,
            folderLocator: FolderLocator(kind: .path, value: path)
        )
    }
}
