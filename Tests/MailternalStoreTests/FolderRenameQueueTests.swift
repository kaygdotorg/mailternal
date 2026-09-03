import Foundation
import Testing
@testable import MailternalStore

@Test func folderRenameQueueCoalescesAndPreservesHierarchySeparator() async throws {
    try await withStore { store, _ in
        let account = sampleAccount()
        try await store.upsertAccount(account)
        let folder = try await store.upsertFolder(
            account: account.id,
            path: "Projects^Old",
            name: "Old",
            separator: "^",
            role: .none,
            objectID: nil
        )

        try await store.enqueueFolderRename(folder: folder, to: "New")
        try await store.enqueueFolderRename(folder: folder, to: "Newest")

        let pending = try #require(await store.snapshotFolderRenameQueue().first)
        #expect(pending.account == account.id)
        #expect(pending.folder == folder)
        #expect(pending.targetName == "Newest")
        #expect(pending.targetPath == "Projects^Newest")
        #expect(try await store.snapshotFolderRenameQueue().count == 1)
        #expect(try await store.fetchFolderSummary(folder)?.path == "Projects^Old")
    }
}

@Test func applyingFolderRenameRewritesNestedChildPaths() async throws {
    try await withStore { store, _ in
        let account = sampleAccount()
        try await store.upsertAccount(account)
        let parent = try await store.upsertFolder(
            account: account.id,
            path: "Projects^Old",
            name: "Old",
            separator: "^",
            role: .none,
            objectID: nil
        )
        let child = try await store.upsertFolder(
            account: account.id,
            path: "Projects^Old^Child",
            name: "Child",
            separator: "^",
            role: .none,
            objectID: nil
        )
        try await store.enqueueFolderRename(folder: parent, to: "New")
        let op = try #require(await store.snapshotFolderRenameQueue().first)
        try await store.applyFolderRename(op)

        #expect(try await store.fetchFolderSummary(parent)?.path == "Projects^New")
        #expect(try await store.fetchFolderSummary(child)?.path == "Projects^New^Child")
        #expect(try await store.snapshotFolderRenameQueue().isEmpty)
    }
}

@Test func retiredFolderRenameRemainsForTerminalDrainLogging() async throws {
    try await withStore { store, _ in
        let account = sampleAccount()
        try await store.upsertAccount(account)
        let folder = try await store.upsertFolder(
            account: account.id,
            path: "Old",
            name: "Old",
            separator: nil,
            role: .none,
            objectID: nil
        )
        try await store.enqueueFolderRename(folder: folder, to: "New")
        _ = try await store.reconcileFolders(account: account.id, seen: [])
        let pending = try #require(await store.snapshotFolderRenameQueue().first)
        try await store.dropFolderRename(pending, reason: "folder missing or retired")
        #expect(try await store.snapshotFolderRenameQueue().isEmpty)
        #expect(try await store.fetchErrorLog().contains { $0.message == "Couldn’t rename folder" })
    }
}
