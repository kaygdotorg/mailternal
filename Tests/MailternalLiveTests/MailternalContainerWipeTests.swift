#if os(macOS)
import Foundation
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalLive

private func wipeTestAccount(_ rawID: String) -> AccountConfig {
    AccountConfig(
        id: AccountID(rawValue: rawID),
        accountLinkID: AccountLinkID(uuidString: UUID().uuidString)!,
        displayName: rawID,
        emailAddress: "\(rawID)@mailternal.test",
        username: "\(rawID)@mailternal.test",
        imap: IMAPEndpoint(host: "127.0.0.1", port: 1993, security: .implicitTLS),
        isEnabled: false
    )
}

@Test
@MainActor
func wipeAttachmentFilesEmptiesCache() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "mailternal-wipe-\(UUID().uuidString)",
        isDirectory: true
    )
    let container = MailternalContainer(root: root)
    try container.prepare()
    defer { try? fm.removeItem(at: root) }

    for index in 0..<8 {
        let url = container.attachmentsDirectory.appendingPathComponent("blob-\(index).bin")
        try Data(repeating: UInt8(index), count: 1024).write(to: url)
    }
    let planted = try fm.contentsOfDirectory(
        at: container.attachmentsDirectory,
        includingPropertiesForKeys: nil
    )
    #expect(planted.count == 8)

    await container.wipeAttachmentFiles()

    let leftover = try fm.contentsOfDirectory(
        at: container.attachmentsDirectory,
        includingPropertiesForKeys: nil
    )
    #expect(leftover.isEmpty)
}

@Test
@MainActor
func removeAccountClearsStateThenWipesAttachments() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "mailternal-remove-wipe-\(UUID().uuidString)",
        isDirectory: true
    )
    let container = MailternalContainer(root: root)
    try container.prepare()
    let keychain = KeychainStore(service: "org.kayg.mailternal.qa", storage: .memory)
    let account = wipeTestAccount("remove-\(UUID().uuidString)")
    do {
        let store = try MailStore(
            databaseURL: container.databaseURL,
            cachesDirectory: container.attachmentsDirectory
        )
        try await store.upsertAccount(account)
    }
    let facade = try LiveMailFacade(
        container: container,
        keychain: keychain,
        enableNotifications: false
    )
    await facade.restorePersistedAccounts()
    defer { try? fm.removeItem(at: root) }

    let blob = container.attachmentsDirectory.appendingPathComponent("stale.bin")
    try Data("stale".utf8).write(to: blob)
    #expect(fm.fileExists(atPath: blob.path))

    try await facade.removeAccount()
    #expect(facade.accountState == .none)
    #expect(!fm.fileExists(atPath: blob.path))
}
@Test
@MainActor
func removeAccountPreservesAttachmentsWhileAccountsRemain() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "mailternal-remove-wipe-multi-\(UUID().uuidString)",
        isDirectory: true
    )
    let container = MailternalContainer(root: root)
    try container.prepare()
    let keychain = KeychainStore(service: "org.kayg.mailternal.qa", storage: .memory)
    let accounts = [
        wipeTestAccount("first-\(UUID().uuidString)"),
        wipeTestAccount("second-\(UUID().uuidString)")
    ]
    do {
        let store = try MailStore(
            databaseURL: container.databaseURL,
            cachesDirectory: container.attachmentsDirectory
        )
        for account in accounts {
            try await store.upsertAccount(account)
        }
    }
    let facade = try LiveMailFacade(
        container: container,
        keychain: keychain,
        enableNotifications: false
    )
    await facade.restorePersistedAccounts()
    defer { try? fm.removeItem(at: root) }

    let blob = container.attachmentsDirectory.appendingPathComponent("shared.bin")
    try Data("shared".utf8).write(to: blob)

    try await facade.removeAccount(accounts[0].id)
    #expect(facade.accounts.count == 1)
    #expect(facade.accounts.first?.id == accounts[1].id)
    #expect(fm.fileExists(atPath: blob.path))

    try await facade.removeAccount(accounts[1].id)
    #expect(facade.accounts.isEmpty)
    #expect(!fm.fileExists(atPath: blob.path))
}
#endif
