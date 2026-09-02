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
        let subject = element(UIIdentifier.messageSubject)
        let quarantine = element(UIIdentifier.quarantineBanner)
        XCTAssertTrue(
            subject.waitForExistence(timeout: 8) || quarantine.waitForExistence(timeout: 8),
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

    func testMessageListHasNoSearchChromeWhileSearchStaysReachable() {
        signInToMock()
        let table = messageTable()
        let firstRow = table.tableRows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        let title = element(UIIdentifier.messageListTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 8), "message list title")

        // The middle pane's windowed-mode banner is gone: nothing over the list
        // discloses search coverage while the panel is closed, and nothing
        // reserves height above the measured title.
        XCTAssertFalse(
            element(UIIdentifier.searchCoverage).exists,
            "no search chrome should stand over the message list"
        )
        XCTAssertEqual(
            app.staticTexts
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Search covers mail since"))
                .count,
            0,
            "coverage disclosure must not be list chrome"
        )

        // The title is measured in the same window coordinate space as the
        // table. Wait for the measured title-driven inset to settle before
        // asserting the first row's resting position.
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                firstRow.frame.minY >= title.frame.maxY - 1
            },
            "first row should rest below the title's bottom edge"
        )
        let titleBottomDepth = title.frame.maxY - mainWindow.frame.minY
        let depth = firstRow.frame.minY - mainWindow.frame.minY
        XCTAssertGreaterThanOrEqual(
            depth,
            titleBottomDepth - 1,
            "first row should rest below the title's bottom edge"
        )
        XCTAssertLessThan(
            depth,
            titleBottomDepth + MailWindowDissolvePolicy.messageList.topReach + 1,
            "no banner or spacer should reserve height above the first row"
        )

        // The feature stays reachable through its own command, and windowed
        // mode is disclosed there instead.
        activateMainWindow()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(
            element(UIIdentifier.searchField).waitForExistence(timeout: 8),
            "cmd-K should still open search"
        )
        XCTAssertTrue(
            element(UIIdentifier.searchCoverage).waitForExistence(timeout: 5),
            "windowed-mode coverage should be disclosed in the search panel"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !self.element(UIIdentifier.searchPanel).exists },
            "Escape should close search again"
        )
    }

    func testSidebarSlashHierarchyCollapsesAndExpands() {
        signInToMock()
        let parent = element(UIIdentifier.sidebarFolder("Engineering"))
        let child = element(UIIdentifier.sidebarFolder("Engineering/Reports"))
        let leaf = element(UIIdentifier.sidebarFolder("Engineering/Reports/Weekly"))

        XCTAssertTrue(parent.waitForExistence(timeout: 10), "slash hierarchy parent")
        XCTAssertTrue(child.waitForExistence(timeout: 10), "slash hierarchy child")
        XCTAssertTrue(leaf.waitForExistence(timeout: 10), "slash hierarchy leaf")
        XCTAssertTrue(parent.label.localizedCaseInsensitiveContains("syncing"), "syncing state is spoken")

        let disclosure = parent.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "parent has a native disclosure affordance")
        XCTAssertEqual(leaf.disclosureTriangles.count, 0, "leaf must not expose a disclosure affordance")
        XCTAssertTrue(leaf.label.localizedCaseInsensitiveContains("sync halted"), "halted state is spoken")

        disclosure.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) { !child.exists && !leaf.exists },
            "collapsing the parent hides its descendants"
        )

        parent.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(child.waitForExistence(timeout: 5), "expanding restores the child")
        XCTAssertTrue(leaf.waitForExistence(timeout: 5), "expanding restores the grandchild")
    }

    func testSidebarDotHierarchyAndAdjacentRoot() {
        signInToMock()
        let parent = element(UIIdentifier.sidebarFolder("Research"))
        let child = element(UIIdentifier.sidebarFolder("Research.Notes"))
        let adjacent = element(UIIdentifier.sidebarFolder("Adjacent"))
        let adjacentLeaf = element(UIIdentifier.sidebarFolder("AdjacentLeaf"))

        XCTAssertTrue(parent.waitForExistence(timeout: 10), "dot hierarchy parent")
        XCTAssertTrue(child.waitForExistence(timeout: 10), "dot hierarchy child")
        XCTAssertTrue(adjacent.waitForExistence(timeout: 10), "adjacent-name root")
        XCTAssertTrue(adjacentLeaf.waitForExistence(timeout: 10), "adjacent-name folder")

        let disclosure = parent.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "dot parent has a native disclosure affordance")
        XCTAssertEqual(child.disclosureTriangles.count, 0, "dot leaf must not expose a disclosure affordance")
        XCTAssertEqual(adjacent.disclosureTriangles.count, 0, "false-parent candidate must remain a root")

        disclosure.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) { !child.exists },
            "dot hierarchy collapses like slash hierarchy"
        )
        parent.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(child.waitForExistence(timeout: 5), "dot hierarchy expands again")
        XCTAssertTrue(adjacentLeaf.exists, "false-parent folder stays visible independently")
    }

    func testNestedFolderGetInfoShowsNameAndPath() {
        signInToMock()
        let folder = element(UIIdentifier.sidebarFolder("Engineering/Reports/Weekly"))
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "nested folder for Get Info")

        folder.rightClick()
        let getInfo = app.menuItems["Get Info…"]
        XCTAssertTrue(getInfo.waitForExistence(timeout: 5), "nested-folder context menu")
        getInfo.click()

        XCTAssertTrue(app.staticTexts["Weekly"].waitForExistence(timeout: 5), "Get Info exposes folder name")
        XCTAssertTrue(
            app.staticTexts["Engineering/Reports/Weekly"].waitForExistence(timeout: 5),
            "Get Info exposes full folder path"
        )
        let halted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Halted")).firstMatch
        XCTAssertTrue(halted.waitForExistence(timeout: 5), "Get Info exposes halted sync metadata")
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

    func testReaderSubjectClearsTheFadeAndDetailsDisclosureExpands() {
        signInToMock()
        let table = messageTable()
        XCTAssertTrue(table.tableRows.firstMatch.waitForExistence(timeout: 10))
        // Row 0 of the mock Inbox is the quarantined seed; row 1 is a normal
        // message with a full envelope.
        let row = table.tableRows.element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "second Inbox row")
        row.click()

        let subject = element(UIIdentifier.messageSubject)
        XCTAssertTrue(subject.waitForExistence(timeout: 8), "reader should show a subject region")

        // Measured against the window, so this is a depth below the physical
        // window top: the subject rests past the viewer's dissolve, never in
        // its ramp.
        let topInset = MessageViewerLayoutPolicy.readerTopInset(safeAreaTop: 0)
        let depth = subject.frame.minY - mainWindow.frame.minY
        XCTAssertGreaterThanOrEqual(
            depth,
            topInset - 1,
            "subject must start below the top dissolve, not inside it"
        )

        // Details is a real disclosure and starts collapsed: stored technical
        // headers never compete with reading.
        XCTAssertTrue(
            element(UIIdentifier.messageDetails).waitForExistence(timeout: 5),
            "envelope should expose a details disclosure"
        )
        XCTAssertFalse(headerRow("Message-ID").exists, "collapsed details hide stored headers")

        let disclosure = element(UIIdentifier.messageViewer).disclosureTriangles.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "details must be a disclosure control")
        disclosure.click()
        XCTAssertTrue(
            headerRow("Message-ID").waitForExistence(timeout: 5),
            "expanding details reveals the headers the store actually parsed"
        )
        XCTAssertFalse(
            headerRow("Bcc").exists,
            "no Bcc is parsed, so no row may claim one"
        )

        disclosure.click()
        XCTAssertTrue(
            waitUntil(timeout: 5) { !self.headerRow("Message-ID").exists },
            "collapsing details hides them again"
        )
    }

    /// Detail rows are label/value pairs, so a header is addressed by the cell
    /// whose label starts with its name — and only inside the reader.
    private func headerRow(_ label: String) -> XCUIElement {
        element(UIIdentifier.messageViewer)
            .descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", label))
            .firstMatch
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
