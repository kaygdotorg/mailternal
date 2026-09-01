import XCTest
import MailternalInterfaces

final class FolderHierarchyTests: XCTestCase {
    func testParentPathRequiresExplicitSeparator() {
        XCTAssertEqual(FolderHierarchy.parentPath(for: "/Archive/2024", name: "2024", separator: "/"), "/Archive")
        XCTAssertEqual(FolderHierarchy.parentPath(for: "Archive.2024", name: "2024", separator: "."), "Archive")
        XCTAssertEqual(FolderHierarchy.parentPath(for: "/child", name: "child", separator: "/"), "/")
        XCTAssertNil(FolderHierarchy.parentPath(for: "Inbox", name: "Inbox", separator: nil))
        XCTAssertNil(FolderHierarchy.parentPath(for: "ArchiveReport", name: "Report", separator: nil))
        XCTAssertNil(FolderHierarchy.parentPath(for: "ArchiveReport", name: "Report", separator: "/"))
    }

    func testBreakageReproKeepsAdjacentNamesAtRoot() {
        let folders = [
            folder(1, name: "Archive", path: "Archive", separator: nil),
            folder(2, name: "Report", path: "Archive/Report", separator: nil),
        ]

        let roots = FolderHierarchy.make(from: folders)

        XCTAssertEqual(roots.map(\.folder.name), ["Archive", "Report"])
        XCTAssertNil(FolderHierarchy.parentPath(for: "ArchiveReport", name: "Report", separator: nil))
    }

    func testBuildsMultipleLevelsAndLeavesMissingParentsAtRoot() {
        let folders = [
            folder(1, name: "Two", path: "/One/Two", separator: "/"),
            folder(2, name: "One", path: "/One", separator: "/"),
            folder(3, name: "Three", path: "/One/Two/Three", separator: "/"),
            folder(4, name: "Leaf", path: "/Missing/Leaf", separator: "/"),
        ]

        let roots = FolderHierarchy.make(from: folders)

        XCTAssertEqual(roots.map(\.folder.name), ["Leaf", "One"])
        XCTAssertEqual(roots[1].children.map(\.folder.name), ["Two"])
        XCTAssertEqual(roots[1].children[0].children.map(\.folder.name), ["Three"])
        XCTAssertTrue(roots[0].children.isEmpty)
    }

    func testLeadingDelimiterRootCanOwnChildren() {
        let folders = [
            folder(1, name: "Child", path: ".Child", separator: "."),
            folder(2, name: "Root", path: ".", separator: "."),
        ]

        let roots = FolderHierarchy.make(from: folders)

        XCTAssertEqual(roots.map(\.folder.name), ["Root"])
        XCTAssertEqual(roots[0].children.map(\.folder.name), ["Child"])
    }

    func testDelimiterLikeCharactersInDisplayNamesRemainIntact() {
        let folders = [
            folder(1, name: "Projects.Report", path: "Projects.Report", separator: "."),
            folder(2, name: "Receipts", path: "Projects.Report.Receipts", separator: "."),
            folder(3, name: "Archive.Report", path: "Archive.Report", separator: "."),
        ]

        let roots = FolderHierarchy.make(from: folders)

        XCTAssertEqual(roots.map(\.folder.name), ["Archive.Report", "Projects.Report"])
        XCTAssertEqual(roots[1].children.map(\.folder.name), ["Receipts"])
        XCTAssertEqual(
            FolderHierarchy.parentPath(
                for: "Projects.Report.Receipts",
                name: "Receipts",
                separator: "."
            ),
            "Projects.Report"
        )
        XCTAssertNil(
            FolderHierarchy.parentPath(
                for: "Archive.Report",
                name: "Archive.Report",
                separator: "."
            )
        )
    }
    func testCustomDelimiterRequiresMatchingStoredCharacter() {
        let folders = [
            folder(1, name: "Root", path: "Root", separator: "~"),
            folder(2, name: "Child", path: "Root~Child", separator: "~"),
            folder(3, name: "DotChild", path: "Root.DotChild", separator: "~"),
        ]

        let roots = FolderHierarchy.make(from: folders)

        XCTAssertEqual(roots.map(\.folder.name), ["DotChild", "Root"])
        XCTAssertEqual(roots[1].children.map(\.folder.name), ["Child"])
        XCTAssertNil(
            FolderHierarchy.parentPath(
                for: "Root.DotChild",
                name: "DotChild",
                separator: "~"
            )
        )
    }

    func testRootOrderingKeepsSpecialRolesAheadOfCustomFolders() {
        let folders = [
            folder(1, name: "Zed", path: "Zed"),
            folder(2, name: "Inbox", path: "Inbox", role: .inbox),
        ]

        XCTAssertEqual(FolderHierarchy.make(from: folders).map(\.folder.name), ["Inbox", "Zed"])
    }

    private func folder(
        _ id: Int64,
        name: String,
        path: String,
        separator: Character? = nil,
        role: FolderRole = .none
    ) -> FolderSummary {
        FolderSummary(
            id: FolderID(rawValue: id),
            name: name,
            path: path,
            separator: separator,
            role: role,
            unreadCount: 0,
            totalCount: 0,
            backfill: .complete
        )
    }
}
