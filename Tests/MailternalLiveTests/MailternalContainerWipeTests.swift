#if os(macOS)
import Foundation
import Testing
@testable import MailternalLive

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
    let keychain = KeychainStore(service: "org.kayg.mailternal.qa", storage: .memory)
    let facade = try LiveMailFacade(
        container: container,
        keychain: keychain,
        enableNotifications: false
    )
    defer { try? fm.removeItem(at: root) }

    let blob = container.attachmentsDirectory.appendingPathComponent("stale.bin")
    try Data("stale".utf8).write(to: blob)
    #expect(fm.fileExists(atPath: blob.path))

    try await facade.removeAccount()
    #expect(facade.accountState == .none)
    #expect(!fm.fileExists(atPath: blob.path))
}
#endif
