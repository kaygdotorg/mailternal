import XCTest

final class MessageTableSelectionPolicyTests: XCTestCase {
    func testSelectionEventClassification() {
        let userEvents: [MessageTableSelectionEvent] = [
            .init(kind: .mouseDown),
            .init(kind: .mouseUp),
            .init(kind: .keyDown(.up)),
            .init(kind: .keyUp(.up)),
            .init(kind: .keyDown(.down)),
            .init(kind: .keyUp(.down)),
            .init(kind: .keyDown(.left)),
            .init(kind: .keyUp(.right)),
            .init(kind: .keyDown(.home)),
            .init(kind: .keyUp(.end)),
            .init(kind: .keyDown(.pageUp)),
            .init(kind: .keyUp(.pageDown))
        ]
        for event in userEvents {
            XCTAssertEqual(
                MessageTableSelectionPolicy.classification(for: event),
                .user,
                "Expected \(event) to be user input"
            )
        }
    }

    func testSelectionEventClassificationIgnoresProgrammaticAndOtherInput() {
        let ignoredEvents: [MessageTableSelectionEvent?] = [
            nil,
            .init(kind: .other),
            .init(kind: .other, command: true),
            .init(kind: .other, shift: true)
        ]
        for event in ignoredEvents {
            XCTAssertEqual(
                MessageTableSelectionPolicy.classification(for: event),
                .programmatic,
                "Expected \(String(describing: event)) to be programmatic"
            )
        }
    }

    func testModifierFlagsDoNotChangeInputClassification() {
        let event = MessageTableSelectionEvent(kind: .keyDown(.down), command: true, shift: true)
        XCTAssertEqual(MessageTableSelectionPolicy.classification(for: event), .user)
        XCTAssertFalse(MessageTableSelectionPolicy.isMouseSelection(event))
    }

    func testOnlyMouseAndKeyDownEventsOpenReader() {
        XCTAssertTrue(MessageTableSelectionPolicy.opensReader(for: .init(kind: .mouseDown)))
        XCTAssertTrue(MessageTableSelectionPolicy.opensReader(for: .init(kind: .mouseUp)))
        XCTAssertTrue(MessageTableSelectionPolicy.opensReader(for: .init(kind: .keyDown(.down))))
        XCTAssertFalse(MessageTableSelectionPolicy.opensReader(for: .init(kind: .keyUp(.down))))
        XCTAssertFalse(MessageTableSelectionPolicy.opensReader(for: nil))
    }
}
