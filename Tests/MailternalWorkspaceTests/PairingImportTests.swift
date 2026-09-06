import Foundation
import Testing
import MailternalInterfaces
import MailternalWorkspace

@MainActor
@Test func accountIdentityMigrationCanReplayAfterRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.json")
    let source = AccountLinkID.random()
    let destination = AccountLinkID.random()
    let sourceScope = MailListScope.folder(account: source, path: "INBOX")
    let destinationScope = MailListScope.folder(account: destination, path: "INBOX")
    let link = MailternalDeepLink.message(
        accountLinkID: source,
        folderLocator: FolderLocator(kind: .path, value: "INBOX"),
        uidValidity: 7,
        uid: IMAPUID(rawValue: 42)
    )
    let controller = WorkspaceSyncController(storageURL: url, containerIdentifier: "iCloud.org.kayg.mailternal")
    try await MailListLayoutStore(controller: controller).setPresentation(.columns, for: sourceScope)
    try await controller.importLocalValues([
        WorkspaceSyncImportValue(key: "reading.link", value: .string(try #require(link.formattedString)), category: .workspace)
    ])
    try await controller.remapAccountLinkID(from: source, to: destination)

    // Simulate interruption after workspace commit but before the account
    // identity command was marked complete. Its old-key tombstone must not
    // erase the migrated setting when startup replays the command.
    let reopened = WorkspaceSyncController(storageURL: url, containerIdentifier: "iCloud.org.kayg.mailternal")
    try await reopened.remapAccountLinkID(from: source, to: destination)
    #expect(MailListLayoutStore(controller: reopened).configuration(for: destinationScope).presentation == .columns)
    #expect(reopened.values["reading.link"] == .string(try #require(link.replacingAccountLinkID(with: destination).formattedString)))
}

@MainActor
@Test func invalidPairingBatchCannotPartiallyReplaceSettings() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.json")
    let controller = WorkspaceSyncController(storageURL: url, containerIdentifier: "iCloud.org.kayg.mailternal")
    try await controller.importLocalValues([
        WorkspaceSyncImportValue(key: "theme", value: .string("original"), category: .appearance)
    ])
    await #expect(throws: WorkspaceSyncError.self) {
        try await controller.importLocalValues([
            WorkspaceSyncImportValue(key: "theme", value: .string("replacement"), category: .appearance),
            WorkspaceSyncImportValue(key: "", value: .bool(true), category: .workspace)
        ])
    }
    #expect(controller.values["theme"] == .string("original"))
    let reopened = WorkspaceSyncController(storageURL: url, containerIdentifier: "iCloud.org.kayg.mailternal")
    #expect(reopened.values["theme"] == .string("original"))
}
