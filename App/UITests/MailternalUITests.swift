import XCTest

final class MailternalUITests: XCTestCase {
    private var app: XCUIApplication!
    private var containerURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailternalUITests-\(UUID().uuidString)", isDirectory: true)
        app.launchArguments = ["-mock", "--mailternal-container", containerURL.path]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        if let containerURL { try? FileManager.default.removeItem(at: containerURL) }
        app = nil
        super.tearDown()
    }

    func testLaunchShowsMainWindow() {
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 8), "main window should appear on launch")
    }


    func testDoubleClickingAccountTitleEntersRename() {
        signInToMock()
        let title = element(UIIdentifier.sidebarAccountTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 8), "account title")

        title.doubleClick()

        let field = element(UIIdentifier.sidebarAccountTitleField)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "account title rename field")
        field.click()
        field.typeText("Renamed")
        field.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.element(UIIdentifier.sidebarAccountTitle).label.contains("Renamed") },
            "account title should update after Return"
        )
    }

    func testDoubleClickingCustomFolderEntersAndEscapesRename() {
        signInToMock()
        let folder = element(UIIdentifier.sidebarFolder("Horrors"))
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "Horrors sidebar row")

        folder.doubleClick()

        let field = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-folder-rename-field-")
        ).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "custom folder rename field")
        field.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                !self.app.textFields.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-folder-rename-field-")
                ).firstMatch.exists
            },
            "Escape should cancel folder rename"
        )
        XCTAssertEqual(folder.label, "Horrors")
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

    func testSelectingRowPopulatesViewer() {
        signInToMock()
        let table = messageTable()
        let firstRow = table.tableRows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "Inbox should contain a message")
        firstRow.click()
        XCTAssertTrue(element(UIIdentifier.messageViewer).waitForExistence(timeout: 8))
        let subject = element(UIIdentifier.messageSubject)
        let quarantine = element(UIIdentifier.quarantineBanner)
        XCTAssertTrue(
            subject.waitForExistence(timeout: 8) || quarantine.waitForExistence(timeout: 8),
            "viewer should show envelope or quarantine content"
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

    func testCommandKEnterOpensReaderTabAndDismissesSearch() {
        signInToMock()
        activateMainWindow()
        app.typeKey("k", modifierFlags: .command)
        let field = element(UIIdentifier.searchField)
        XCTAssertTrue(field.waitForExistence(timeout: 8), "cmd-K should open search")
        field.click()
        field.typeText("Lunch")
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                self.app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Lunch")
                ).firstMatch.exists
            },
            "search should produce a Lunch result"
        )
        field.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(
            waitUntil(timeout: 5) { !self.element(UIIdentifier.searchPanel).exists },
            "Enter should dismiss search after opening the result"
        )
        XCTAssertTrue(
            element(UIIdentifier.messageSubject).waitForExistence(timeout: 8),
            "Enter should open the result in the reader without requiring a visible single-tab strip"
        )
    }

    func testCommandCommaOpensSettings() {
        signInToMock()
        closeSettingsIfOpen()
        activateMainWindow()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 8), "cmd-, should open settings")
        XCTAssertTrue(settingsWindow.otherElements[UIIdentifier.accountsList].waitForExistence(timeout: 5))
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

    func testContextMenuDoesNotReplaceCurrentReader() {
        signInToMock()
        let table = messageTable()
        let originalRow = table.tableRows.element(boundBy: 1)
        let otherRow = table.tableRows.element(boundBy: 2)
        XCTAssertTrue(otherRow.waitForExistence(timeout: 10))
        originalRow.click()
        let subject = element(UIIdentifier.messageSubject)
        XCTAssertTrue(subject.waitForExistence(timeout: 8))
        let originalSubject = subject.label

        otherRow.rightClick()
        let openInTab = app.menuItems["Open in New Tab"]
        XCTAssertTrue(openInTab.waitForExistence(timeout: 5))
        XCTAssertEqual(subject.label, originalSubject, "Opening a context menu must not navigate the reader")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(subject.label, originalSubject, "Dismissing the menu must retain the open message")

        otherRow.rightClick()
        XCTAssertTrue(openInTab.waitForExistence(timeout: 5))
        openInTab.click()
        XCTAssertTrue(waitUntil(timeout: 8) {
            subject.exists && subject.label != originalSubject
        }, "Only the explicit Open in New Tab action should navigate to the other message")
    }
    func testListAboveReaderKeepsReaderChromeLocalAndPreservesTabs() {
        signInToMock()
        selectPaneLayout("Side by Side")

        let table = messageTable()
        let originalRow = table.tableRows.element(boundBy: 1)
        let otherRow = table.tableRows.element(boundBy: 2)
        XCTAssertTrue(originalRow.waitForExistence(timeout: 10), "second Inbox row")
        XCTAssertTrue(otherRow.waitForExistence(timeout: 10), "third Inbox row")
        originalRow.click()

        let subject = element(UIIdentifier.messageSubject)
        XCTAssertTrue(subject.waitForExistence(timeout: 8), "reader subject")
        let originalSubject = subject.label

        otherRow.rightClick()
        let openInTab = app.menuItems["Open in New Tab"]
        XCTAssertTrue(openInTab.waitForExistence(timeout: 5), "reader context menu")
        openInTab.click()
        XCTAssertTrue(
            waitUntil(timeout: 8) { subject.exists && subject.label != originalSubject },
            "Open in New Tab should activate the second reader tab"
        )

        let activeSubject = subject.label
        let tabsBefore = readerTabLabels()
        XCTAssertEqual(tabsBefore.count, 2, "both opened messages should remain represented by tabs")

        defer {
            if mainWindow.exists {
                selectPaneLayout("Side by Side")
            }
        }
        selectPaneLayout("List Above Reader")

        let paneToolbar = element("reader-pane-toolbar")
        let localTabBar = paneToolbar.descendants(matching: .any)[UIIdentifier.readerTabBar]
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                paneToolbar.exists
                    && localTabBar.exists
                    && table.exists
                    && subject.exists
                    && self.mainWindow.toolbars.firstMatch.frame.maxY <= paneToolbar.frame.minY + 1
                    && subject.frame.minY >= paneToolbar.frame.maxY - 1
            },
            "List Above Reader should place reader chrome below the list"
        )
        let localSubjectGap = subject.frame.minY - paneToolbar.frame.maxY
        XCTAssertGreaterThanOrEqual(localSubjectGap, -1, "subject should not overlap local reader chrome")
        XCTAssertLessThanOrEqual(
            localSubjectGap,
            paneToolbar.frame.height,
            "subject should keep a compact local gap below reader chrome"
        )
        XCTAssertEqual(subject.label, activeSubject, "changing pane layout must preserve the active subject")
        XCTAssertEqual(readerTabLabels(in: paneToolbar), tabsBefore, "changing pane layout must preserve reader tabs")

        selectPaneLayout("Side by Side")
        let topTabBar = element(UIIdentifier.readerTabBar)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                !paneToolbar.exists
                    && topTabBar.exists
                    && table.exists
                    && subject.exists
                    && topTabBar.frame.maxY <= subject.frame.minY + 1
                    && subject.label == activeSubject
            },
            "switching back should restore the top reader toolbar"
        )
        XCTAssertEqual(readerTabLabels(in: topTabBar), tabsBefore, "restoring the layout must preserve reader tabs")
    }

    func testInactiveTabPreviewAppearsAndDismissesWithoutChangingReader() {
        signInToMock()
        let table = messageTable()
        let first = table.tableRows.element(boundBy: 1)
        let second = table.tableRows.element(boundBy: 2)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        first.click()
        let subject = element(UIIdentifier.messageSubject)
        XCTAssertTrue(subject.waitForExistence(timeout: 8))
        let firstSubject = subject.label
        second.rightClick()
        let openInTab = app.menuItems["Open in New Tab"]
        XCTAssertTrue(openInTab.waitForExistence(timeout: 5))
        openInTab.click()
        XCTAssertTrue(waitUntil(timeout: 8) {
            subject.exists && subject.label != firstSubject
        })
        let secondSubject = subject.label
        let inactiveTab = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "reader-tab-", firstSubject
            )
        ).firstMatch
        let preview = element(UIIdentifier.readerHoverCard)
        defer {
            if mainWindow.exists {
                selectPaneLayout("Side by Side")
            }
        }

        for layout in ["Side by Side", "List Above Reader"] {
            selectPaneLayout(layout)
            XCTAssertTrue(inactiveTab.waitForExistence(timeout: 8))
            inactiveTab.hover()
            XCTAssertTrue(preview.waitForExistence(timeout: 3),
                          "Dwelling on an inactive tab should reveal its preview in \(layout)")
            XCTAssertEqual(subject.label, secondSubject, "Previewing must not navigate the reader")
            subject.hover()
            XCTAssertTrue(waitUntil(timeout: 3) { !preview.exists },
                          "Leaving both tab and preview should dismiss the card")
        }

        inactiveTab.click()
        XCTAssertTrue(waitUntil(timeout: 8) { subject.label == firstSubject })
        XCTAssertFalse(preview.exists, "Activating a tab must not leave its preview open")
    }

    func testResizingWindowBackToStartingWidthRestoresReaderToolbar() {
        signInToMock()
        selectPaneLayout("Side by Side")

        let table = messageTable()
        let originalRow = table.tableRows.element(boundBy: 1)
        let otherRow = table.tableRows.element(boundBy: 2)
        XCTAssertTrue(originalRow.waitForExistence(timeout: 10), "second Inbox row")
        XCTAssertTrue(otherRow.waitForExistence(timeout: 10), "third Inbox row")
        originalRow.click()

        let subject = element(UIIdentifier.messageSubject)
        XCTAssertTrue(subject.waitForExistence(timeout: 8), "reader subject")
        let originalSubject = subject.label
        otherRow.rightClick()
        let openInTab = app.menuItems["Open in New Tab"]
        XCTAssertTrue(openInTab.waitForExistence(timeout: 5), "reader context menu")
        openInTab.click()
        XCTAssertTrue(
            waitUntil(timeout: 8) { subject.exists && subject.label != originalSubject },
            "Open in New Tab should activate the second reader tab"
        )

        let activeSubject = subject.label
        let tabsBefore = readerTabLabels()
        XCTAssertEqual(tabsBefore.count, 2, "both opened messages should remain represented by tabs")
        let archive = nativeReaderAction("Archive")
        let trash = nativeReaderAction("Trash")
        let more = nativeReaderAction("More")
        for action in [archive, trash, more] {
            XCTAssertTrue(action.waitForExistence(timeout: 5), "native reader action should be present before resize")
        }

        let initialWidth = mainWindow.frame.width
        let minimumWidth = MainWindowLayoutPolicy.minimumContentSize.width
        let baselineWidth = minimumWidth + 240
        if initialWidth < baselineWidth {
            resizeMainWindowWidth(to: baselineWidth)
            XCTAssertTrue(
                waitUntil(timeout: 8) { self.mainWindow.exists && self.mainWindow.frame.width >= baselineWidth - 2 },
                "window should reach a stable starting width"
            )
        }
        let startingWidth = mainWindow.frame.width
        let targetWidth = max(minimumWidth, startingWidth * 0.72)
        defer {
            if mainWindow.exists {
                resizeMainWindowWidth(to: initialWidth)
            }
        }

        resizeMainWindowWidth(to: targetWidth)
        XCTAssertTrue(
            waitUntil(timeout: 8) { self.mainWindow.exists && self.mainWindow.frame.width < startingWidth - 2 },
            "native coordinate drag should shrink the window"
        )
        let shrunkWidth = mainWindow.frame.width
        XCTAssertLessThan(shrunkWidth, startingWidth - 1, "resize must produce a smaller native window")

        resizeMainWindowWidth(to: startingWidth)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                guard self.mainWindow.exists else { return false }
                return abs(self.mainWindow.frame.width - startingWidth) <= 1
                    && self.nativeReaderAction("Archive").isHittable
                    && self.nativeReaderAction("Trash").isHittable
                    && self.nativeReaderAction("More").isHittable
            },
            "returning to the starting width should restore native reader actions without expansion"
        )
        XCTAssertEqual(mainWindow.frame.width, startingWidth, accuracy: 1, "window should return to its exact starting width")
        XCTAssertEqual(subject.label, activeSubject, "resizing must preserve the active subject")
        XCTAssertEqual(readerTabLabels(), tabsBefore, "resizing must preserve reader tabs")
    }


    func testReaderBlankSpaceCommandWClosesLastTabBeforeWindow() {
        signInToMock()
        let row = messageTable().tableRows.element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(element(UIIdentifier.messageSubject).waitForExistence(timeout: 8))

        // A pane click must establish reader intent even when AppKit leaves
        // the old table as first responder beneath non-focusable SwiftUI.
        element(UIIdentifier.messageViewer)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85))
            .click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) {
            self.mainWindow.exists && !self.element(UIIdentifier.messageSubject).exists
        }, "Closing the final reader tab must leave an empty, open main window")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.mainWindow.exists },
                      "With no tabs, Command W closes the window")
    }

    func testMessageListCommandWClosesWindowWithReaderOpen() {
        signInToMock()
        let row = messageTable().tableRows.element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(element(UIIdentifier.messageSubject).waitForExistence(timeout: 8))
        row.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5) { !self.mainWindow.exists },
                      "A list-focused close must close the window, not a reader tab")
    }

    private func selectPaneLayout(_ title: String) {
        activateMainWindow()
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5), "View menu")
        viewMenu.click()

        let layoutMenu = app.menuItems["Layout"]
        XCTAssertTrue(layoutMenu.waitForExistence(timeout: 5), "Layout menu")
        layoutMenu.click()

        let paneMenu = app.menuItems["Pane"]
        XCTAssertTrue(paneMenu.waitForExistence(timeout: 5), "Pane layout menu")
        paneMenu.click()

        let choice = app.menuItems[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "pane layout choice")
        choice.click()
    }

    private func readerTabLabels(in root: XCUIElement? = nil) -> [String] {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier != %@",
            "reader-tab-",
            UIIdentifier.readerTabBar
        )
        let query: XCUIElementQuery
        if let root {
            query = root.descendants(matching: .any).matching(predicate)
        } else {
            query = app.descendants(matching: .any).matching(predicate)
        }
        return query.allElementsBoundByIndex.map { $0.label }
    }

    private func nativeReaderAction(_ label: String) -> XCUIElement {
        mainWindow.toolbars.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func resizeMainWindowWidth(to targetWidth: CGFloat) {
        let currentWidth = mainWindow.frame.width
        let delta = targetWidth - currentWidth
        guard abs(delta) > 1 else { return }
        let source = mainWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.998, dy: 0.998)
        )
        let destination = source.withOffset(CGVector(dx: delta, dy: 0))
        source.press(
            forDuration: 0.15,
            thenDragTo: destination,
            withVelocity: .slow,
            thenHoldForDuration: 0.1
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
        guard settingsWindow.waitForExistence(timeout: 8) else {
            XCTAssertTrue(element(UIIdentifier.sidebarFolder("INBOX")).waitForExistence(timeout: 10))
            return
        }
        let emptyAdd = app.descendants(matching: .any)[UIIdentifier.accountsEmptyAdd]
        if emptyAdd.waitForExistence(timeout: 8) {
            emptyAdd.click()
        } else if element(UIIdentifier.sidebarFolder("INBOX")).waitForExistence(timeout: 2) {
            closeSettingsIfOpen()
            XCTAssertTrue(element(UIIdentifier.sidebarFolder("INBOX")).waitForExistence(timeout: 10))
            return
        } else {
            let addAccount = app.buttons[UIIdentifier.accountsAdd]
            XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
            addAccount.click()
        }
        app.activate()
        let table = settingsWindow.tables.firstMatch
        for _ in 0..<4 where table.exists && table.isHittable {
            table.swipeUp()
        }
        let host = settingsWindow.textFields[UIIdentifier.accountEditorHost]
        let username = settingsWindow.textFields[UIIdentifier.accountEditorUsername]
        let password = settingsWindow.secureTextFields[UIIdentifier.accountEditorPassword]
        let accountList = settingsWindow.descendants(matching: .any)[UIIdentifier.accountsList]
        if host.exists && !host.isHittable, accountList.exists {
            accountList.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(
            waitUntil(timeout: 8) { host.exists && host.isHittable },
            "account editor should expand before interaction"
        )
        host.click()
        username.click()
        username.typeText("qa")
        password.click()
        password.typeText("password")
        let editor = settingsWindow.descendants(matching: .any)[UIIdentifier.accountEditorSheet]
        let save = editor.buttons["Add Account"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        save.click()
        XCTAssertTrue(
            waitUntil(timeout: 12) { !self.settingsWindow.exists || self.element(UIIdentifier.sidebarFolder("INBOX")).exists },
            "account editor should save"
        )
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
