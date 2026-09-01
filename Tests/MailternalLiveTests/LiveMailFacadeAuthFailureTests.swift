#if os(macOS)
import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import MailternalSync
import Testing
@testable import MailternalLive

@Test
@MainActor
func restorePersistedAccountMapsTerminalAuthToAuthFailed() async throws {
    // Live test: needs the QA Dovecot on 127.0.0.1:1993 and its trust roots
    // (installed by QAIMAPTrust when MAILTERNAL_QA=1). Without them the IP-literal
    // fail-closed TLS rule correctly refuses the connection.
    guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" else { return }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "mailternal-live-auth-\(UUID().uuidString)",
        isDirectory: true
    )
    let container = MailternalContainer(root: root)
    try container.prepare()
    let account = AccountID(rawValue: "auth-\(UUID().uuidString)")
    let keychain = KeychainStore(service: "org.kayg.mailternal.qa", storage: .memory)
    let config = AccountConfig(
        id: account,
        accountLinkID: AccountLinkID(
            uuidString: "00000000-0000-4000-8000-000000000011"
        )!,
        displayName: "QA",
        emailAddress: "qa@mailternal.test",
        username: "qa@mailternal.test",
        imap: IMAPEndpoint(host: "127.0.0.1", port: 1993, security: .implicitTLS)
    )
    let store = try MailStore(
        databaseURL: container.databaseURL,
        cachesDirectory: container.attachmentsDirectory
    )
    try await store.upsertAccount(config)
    try keychain.savePassword("wrong-password", for: account)

    let facade = try LiveMailFacade(
        container: container,
        keychain: keychain,
        enableNotifications: false,
    )
    defer {
        try? keychain.deletePassword(for: account)
        try? fm.removeItem(at: root)
    }

    await facade.restorePersistedAccount()
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if case .authFailed = facade.accountState { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    guard case .authFailed(let message) = facade.accountState else {
        throw LiveMailError("expected authFailed, got \(facade.accountState)")
    }
    #expect(message == "The username or password was rejected.")
    await facade.shutdown()
}

#endif
