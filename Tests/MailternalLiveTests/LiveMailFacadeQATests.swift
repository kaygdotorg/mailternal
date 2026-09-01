#if os(macOS)
import Foundation
import MailternalIMAP
import MailternalInterfaces
import Testing
@testable import MailternalLive

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1")
)
@MainActor
func liveMailFacadeAddsQAAccountAndPagesInbox() async throws {
    try QAIMAPTrust.install()

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("mailternal-live-qa-\(UUID().uuidString)", isDirectory: true)
    let container = MailternalContainer(root: root)
    let account = AccountID(rawValue: "qa-\(UUID().uuidString)")
    let keychain = KeychainStore(service: "org.kayg.mailternal.qa", storage: .memory)
    let facade = try LiveMailFacade(
        container: container,
        keychain: keychain,
        enableNotifications: false
    )
    defer {
        try? keychain.deletePassword(for: account)
        try? fm.removeItem(at: root)
        IMAPSession.resetAdditionalTrustRoots()
    }

    let config = AccountConfig(
        id: account,
        displayName: "QA",
        emailAddress: "qa@mailternal.test",
        username: "qa@mailternal.test",
        imap: IMAPEndpoint(host: "127.0.0.1", port: 1993, security: .implicitTLS)
    )

    do {
        try await facade.addAccount(config, password: "qa-password")
        #expect(facade.accountState == .active)
        try await waitForInboxPage(facade)
        await stopSoon(facade)
        try await facade.removeAccount()
    } catch {
        let logs = (try? await facade.snapshotErrorLog()) ?? []
        let folders = (try? await facade.snapshotFolders()) ?? []
        print("LIVE_QA_FAIL state=\(facade.accountState) folders=\(folderDump(folders)) logs=\(logs)")
        await stopSoon(facade)
        throw error
    }
}

@MainActor
private func waitForInboxPage(_ facade: LiveMailFacade) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    var lastFolders: [FolderSummary] = []
    while ContinuousClock.now < deadline {
        lastFolders = try await facade.snapshotFolders()
        let inbox = lastFolders.first(where: { $0.role == .inbox })
            ?? lastFolders.first(where: { $0.path.compare("INBOX", options: [.caseInsensitive]) == .orderedSame })
        if let inbox {
            let page = try await facade.page(in: inbox.id, after: nil, limit: 25)
            if !page.rows.isEmpty { return }
        }
        try await Task.sleep(for: .milliseconds(400))
    }
    let logs = (try? await facade.snapshotErrorLog()) ?? []
    throw LiveMailError(
        "Timed out waiting for INBOX rows. folders=[\(folderDump(lastFolders))] logs=[\(logs.joined(separator: " | "))]"
    )
}

@MainActor
private func stopSoon(_ facade: LiveMailFacade) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await facade.shutdown()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(8))
        }
        await group.next()
        group.cancelAll()
    }
}

private func folderDump(_ folders: [FolderSummary]) -> String {
    folders.map { folder in
        "\(folder.path) role=\(folder.role) total=\(folder.totalCount) backfill=\(folder.backfill)"
    }.joined(separator: "; ")
}
#endif
