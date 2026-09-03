import XCTest
import MailternalInterfaces

final class ReaderTabsPolicyTests: XCTestCase {
    private func message(_ value: Int64) -> MessageID { MessageID(rawValue: value) }

    func testInsertionRightOfActive() {
        let first = ReaderTab(message: message(1), isTransient: false)
        let second = ReaderTab(message: message(2), isTransient: false)
        let tabs = ReaderTabs(tabs: [first, second], activeID: first.id, mruIDs: [first.id, second.id])
        tabs.open(message(3), permanent: true)
        XCTAssertEqual(tabs.tabs.map(\.message.rawValue), [1, 3, 2])
    }

    func testMRUNextActiveOnClose() {
        let first = ReaderTab(message: message(1), isTransient: false)
        let second = ReaderTab(message: message(2), isTransient: false)
        let third = ReaderTab(message: message(3), isTransient: false)
        let tabs = ReaderTabs(tabs: [first, second, third], activeID: second.id, mruIDs: [second.id, first.id, third.id])
        tabs.close(second.id)
        XCTAssertEqual(tabs.activeID, first.id)
    }

    func testPromoteInPlace() {
        let transient = ReaderTab(message: message(1), isTransient: true)
        let permanent = ReaderTab(message: message(2), isTransient: false)
        let tabs = ReaderTabs(tabs: [transient, permanent], activeID: permanent.id)
        tabs.open(message(1), permanent: true)
        XCTAssertEqual(tabs.tabs.map(\.id), [transient.id, permanent.id])
        XCTAssertFalse(tabs.tabs[0].isTransient)
    }

    func testDedupeActivatesExistingMessage() {
        let first = ReaderTab(message: message(1), isTransient: false)
        let tabs = ReaderTabs(tabs: [first], activeID: first.id)
        tabs.open(message(1), permanent: false)
        XCTAssertEqual(tabs.tabs.count, 1)
        XCTAssertEqual(tabs.activeID, first.id)
    }

    func testCloseOthersAndCloseToRight() {
        let tabs = ReaderTabs(tabs: (1...4).map { ReaderTab(message: message(Int64($0)), isTransient: false) })
        let second = tabs.tabs[1]
        tabs.closeOthers(second.id)
        XCTAssertEqual(tabs.tabs.map(\.message.rawValue), [2])

        let tabs2 = ReaderTabs(tabs: (1...4).map { ReaderTab(message: message(Int64($0)), isTransient: false) })
        tabs2.closeToRight(tabs2.tabs[1].id)
        XCTAssertEqual(tabs2.tabs.map(\.message.rawValue), [1, 2])
    }

    func testMove() {
        let tabs = ReaderTabs(tabs: (1...3).map { ReaderTab(message: message(Int64($0)), isTransient: false) })
        let first = tabs.tabs[0]
        tabs.move(first.id, to: 2)
        XCTAssertEqual(tabs.tabs.map(\.message.rawValue), [2, 3, 1])
    }

    func testNextPreviousWrap() {
        let tabs = ReaderTabs(tabs: (1...3).map { ReaderTab(message: message(Int64($0)), isTransient: false) })
        tabs.activate(tabs.tabs[2].id)
        tabs.activateNext()
        XCTAssertEqual(tabs.active?.message, message(1))
        tabs.activatePrevious()
        XCTAssertEqual(tabs.active?.message, message(3))
    }

    func testSnapshotRoundTripDropsMissingLinkAndFallsBackToMRU() throws {
        let first = ReaderTab(message: message(1), isTransient: false)
        let missing = UUID()
        let snapshot = ReaderTabsSnapshot(
            tabs: [
                .init(id: first.id, link: "mailternal://open/v1/one", isTransient: false, scrollOffset: 42),
                .init(id: missing, link: "mailternal://open/v1/missing", isTransient: true, scrollOffset: 9)
            ],
            activeID: missing,
            mruIDs: [missing, first.id]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ReaderTabsSnapshot.self, from: data)
        let restored = ReaderTabs()
        restored.restore(decoded, messagesByTabID: [first.id: message(1)])
        XCTAssertEqual(restored.tabs.map(\.id), [first.id])
        XCTAssertEqual(restored.activeID, first.id)
        XCTAssertEqual(restored.scrollOffset(for: first.id), 42)
    }
    func testRemovingMessageKeepsReaderAnchorWhenItsTabIsOpen() {
        let messageID = message(42)
        let tab = ReaderTab(message: messageID, isTransient: false)
        XCTAssertEqual(
            ReaderSelectionPolicy.anchorAfterRemoving(
                selectedMessageID: messageID,
                remainingSelection: [],
                removedIDs: [messageID],
                openTabMessages: [messageID]
            ),
            messageID
        )
        XCTAssertNil(
            ReaderSelectionPolicy.anchorAfterRemoving(
                selectedMessageID: messageID,
                remainingSelection: [],
                removedIDs: [messageID],
                openTabMessages: []
            )
        )
        XCTAssertEqual(tab.message, messageID)
    }

    func testClosingLastReaderTabRequestsWindowClose() {
        XCTAssertTrue(
            ReaderTabsPolicy.shouldCloseWindow(afterClosingTabsRemaining: 0)
        )
        XCTAssertFalse(
            ReaderTabsPolicy.shouldCloseWindow(afterClosingTabsRemaining: 1)
        )
    }

    func testDropDestinationAdjustsForSourceBeforeTarget() {
        XCTAssertEqual(
            ReaderTabsPolicy.dropDestination(
                sourceIndex: 0,
                targetIndex: 2,
                afterTarget: false,
                count: 4
            ),
            1
        )
        XCTAssertEqual(
            ReaderTabsPolicy.dropDestination(
                sourceIndex: 0,
                targetIndex: 2,
                afterTarget: true,
                count: 4
            ),
            2
        )
        XCTAssertEqual(
            ReaderTabsPolicy.dropDestination(
                sourceIndex: 3,
                targetIndex: 1,
                afterTarget: false,
                count: 4
            ),
            1
        )
        XCTAssertEqual(
            ReaderTabsPolicy.dropDestination(
                sourceIndex: 3,
                targetIndex: 1,
                afterTarget: true,
                count: 4
            ),
            2
        )
    }
    func testRemovingMessageClosesItsReaderTab() {
        let removedID = message(7)
        let removed = ReaderTab(message: removedID, isTransient: false)
        let retained = ReaderTab(message: message(8), isTransient: false)
        let tabs = ReaderTabs(
            tabs: [
                removed,
                retained
            ],
            activeID: removed.id
        )

        XCTAssertTrue(tabs.messageRemoved(removedID))
        let remainingMessages: [MessageID] = tabs.tabs.map { $0.message }
        XCTAssertEqual(remainingMessages, [retained.message])
        XCTAssertFalse(tabs.messageRemoved(removedID))
    }
}
