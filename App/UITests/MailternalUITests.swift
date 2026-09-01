import XCTest

final class MailternalUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-mock"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    func testLaunchShowsMainWindow() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8), "main window should appear on launch")
    }

    func testSidebarFolderSelectionChangesList() {
        signInToMock()
        let table = messageTable()
        XCTAssertTrue(table.tableRows.firstMatch.waitForExistence(timeout: 10))
        let inboxSummary = firstRowSummary()
        let archive = element(UIIdentifier.sidebarFolder("Archive"))
        XCTAssertTrue(archive.waitForExistence(timeout: 8), "Archive sidebar row")
        archive.click()
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.firstRowSummary() != inboxSummary && !self.firstRowSummary().isEmpty },
            "Archive list should replace Inbox rows"
        )
    }

    func testSelectingRowPopulatesViewerAndClearsUnread() {
        signInToMock()
        let table = messageTable()
        let unread = table.descendants(matching: .any)[UIIdentifier.unreadDot]
        XCTAssertTrue(unread.waitForExistence(timeout: 10), "Inbox should contain an unread marker")
        unread.click()
        XCTAssertTrue(element(UIIdentifier.messageViewer).waitForExistence(timeout: 8))
        let from = app.staticTexts["From"]
        let quarantine = element(UIIdentifier.quarantineBanner)
        XCTAssertTrue(
            from.waitForExistence(timeout: 8) || quarantine.waitForExistence(timeout: 8),
            "viewer should show envelope or quarantine content"
        )
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.selectedRowHasNoUnread(in: table) },
            "selected row should drop its unread marker"
        )
    }

    func testCommandKOpensSearchTypingFiltersAndEscapeCloses() {
        signInToMock()
        activateMainWindow()
        app.typeKey("k", modifierFlags: .command)
        let field = element(UIIdentifier.searchField)
        XCTAssertTrue(field.waitForExistence(timeout: 8), "cmd-K should open search")
        field.click()
        field.typeText("Lunch")
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                self.app.staticTexts["Search every message"].exists == false
                    && (self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Lunch")).firstMatch.exists
                        || self.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "No results")).firstMatch.exists)
            },
            "typing should filter search results"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !self.element(UIIdentifier.searchPanel).exists },
            "Escape should close search"
        )
    }

    func testCommandCommaOpensSettings() {
        signInToMock()
        closeSettingsIfOpen()
        activateMainWindow()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 8), "cmd-, should open settings")
        XCTAssertTrue(settingsWindow.textFields[UIIdentifier.setupHost].waitForExistence(timeout: 5))
    }

    func testWindowedModeBannerVisibleWhenMockReportsWindowed() {
        signInToMock()
        XCTAssertTrue(
            element(UIIdentifier.windowedBanner).waitForExistence(timeout: 10),
            "windowed-mode banner should appear after mock account seed"
        )
    }

    func testQuarantinedMessageShowsBanner() {
        signInToMock()
        let table = messageTable()
        XCTAssertTrue(table.tableRows.firstMatch.waitForExistence(timeout: 10))
        table.tableRows.firstMatch.click()
        XCTAssertTrue(
            element(UIIdentifier.quarantineBanner).waitForExistence(timeout: 10),
            "first Inbox message is quarantined in the mock seed"
        )
    }

    private var mainWindow: XCUIElement {
        app.windows[UIIdentifier.mainWindow]
    }

    private var settingsWindow: XCUIElement {
        app.windows[UIIdentifier.settingsWindow]
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func messageTable() -> XCUIElement {
        let table = app.tables[UIIdentifier.messageTable]
        XCTAssertTrue(table.waitForExistence(timeout: 10), "message table")
        return table
    }

    private func activateMainWindow() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8))
        if mainWindow.isHittable {
            mainWindow.click()
        }
        app.activate()
    }

    private func signInToMock() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8))
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 8), "setup window should appear for a mock account")
        if settingsWindow.staticTexts["Account is active."].exists {
            closeSettingsIfOpen()
            XCTAssertTrue(element(UIIdentifier.sidebarFolder("INBOX")).waitForExistence(timeout: 10))
            return
        }
        let host = settingsWindow.textFields[UIIdentifier.setupHost]
        let username = settingsWindow.textFields[UIIdentifier.setupUsername]
        let password = settingsWindow.secureTextFields[UIIdentifier.setupPassword]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.click()
        host.typeText("mock.local")
        username.click()
        username.typeText("qa")
        password.click()
        password.typeText("password")
        settingsWindow.buttons["Sign In"].click()
        XCTAssertTrue(settingsWindow.staticTexts["Account is active."].waitForExistence(timeout: 12))
        closeSettingsIfOpen()
        XCTAssertTrue(element(UIIdentifier.sidebarFolder("INBOX")).waitForExistence(timeout: 12))
    }

    private func closeSettingsIfOpen() {
        guard settingsWindow.exists else { return }
        let close = settingsWindow.buttons[XCUIIdentifierCloseWindow]
        if close.exists {
            close.click()
        } else {
            settingsWindow.typeKey("w", modifierFlags: .command)
        }
        _ = waitUntil(timeout: 3) { !self.settingsWindow.exists }
    }

    private func firstRowSummary() -> String {
        let row = app.tables[UIIdentifier.messageTable].tableRows.firstMatch
        guard row.exists else { return "" }
        return row.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: "|")
    }

    private func selectedRowHasNoUnread(in table: XCUIElement) -> Bool {
        let selected = table.tableRows.matching(NSPredicate(format: "selected == true")).firstMatch
        if selected.exists {
            return !selected.descendants(matching: .any)[UIIdentifier.unreadDot].exists
        }
        return !table.descendants(matching: .any)[UIIdentifier.unreadDot].isHittable
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate()
    }
}
