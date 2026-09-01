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
        clientFactory: AuthRejectingFactory()
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

final class AuthRejectingFactory: IMAPClientFactory, @unchecked Sendable {
    func makeClient(endpoint: IMAPEndpoint, username: String, password: String) -> any IMAPClient {
        AuthRejectingClient()
    }
}

final class AuthRejectingClient: IMAPClient, @unchecked Sendable {
    private let stream: AsyncStream<IMAPMailboxEvent>

    init() {
        stream = AsyncStream { $0.finish() }
    }

    nonisolated var events: AsyncStream<IMAPMailboxEvent> { stream }

    func capabilities() async -> IMAPCapabilities { .none }
    func selectedMailbox() async -> IMAPSelectedMailbox? { nil }
    func connect() async throws { throw IMAPError.auth("Invalid credentials") }
    func close() async {}
    func listFolders() async throws -> IMAPFolderDiscovery {
        throw IMAPError.auth("Invalid credentials")
    }
    func select(_ mailbox: String, qresync: IMAPQResyncSelect?) async throws -> IMAPSelectedMailbox {
        throw IMAPError.auth("Invalid credentials")
    }
    func enableQResync() async throws { throw IMAPError.auth("Invalid credentials") }
    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        throw IMAPError.auth("Invalid credentials")
    }
    func storeSeen(uids: IMAPUIDSet) async throws { throw IMAPError.auth("Invalid credentials") }
    func beginIdle() async throws -> IMAPIdle { throw IMAPError.auth("Invalid credentials") }
    func endIdle() async throws { throw IMAPError.auth("Invalid credentials") }
    func renewIdle() async throws -> IMAPIdle { throw IMAPError.auth("Invalid credentials") }
}
#endif
