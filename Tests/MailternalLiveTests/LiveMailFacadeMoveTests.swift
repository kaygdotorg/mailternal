#if os(macOS)
import Foundation
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalLive

@Test
@MainActor
func liveMoveResolvesDestinationFromStoreWithoutObservedFolders() async throws {
    let fixture = try await MoveFixture()
    defer { fixture.remove() }

    let facade = try LiveMailFacade(
        container: fixture.container,
        keychain: KeychainStore(service: "org.kayg.mailternal.move-tests", storage: .memory),
        enableNotifications: false
    )
    let outcome = try await facade.move([fixture.messageID], to: fixture.destination)

    #expect(outcome.movedCount == 1)
    #expect(outcome.skippedCrossAccountCount == 0)
    #expect(outcome.acceptedIDs == [fixture.messageID])
    #expect(try await fixture.store.accountID(for: fixture.destination) == fixture.account.id)
    #expect(try await fixture.store.messageIDs(in: fixture.source, sort: .newest).isEmpty)
    let queued = try await fixture.store.snapshotMoveQueue()
    #expect(queued.count == 1)
    #expect(queued[0].destinationFolderID == fixture.destination)
}

@Test
@MainActor
func liveMoveSkipsCrossAccountMessagesAndLogsReason() async throws {
    let fixture = try await MoveFixture(includeForeignMessage: true)
    defer { fixture.remove() }

    let facade = try LiveMailFacade(
        container: fixture.container,
        keychain: KeychainStore(service: "org.kayg.mailternal.move-tests", storage: .memory),
        enableNotifications: false
    )
    let outcome = try await facade.move([fixture.foreignMessageID], to: fixture.destination)

    #expect(outcome.movedCount == 0)
    #expect(outcome.skippedCrossAccountCount == 1)
    #expect(outcome.acceptedIDs.isEmpty)
    #expect(try await fixture.store.messageRef(fixture.foreignMessageID) != nil)
    #expect(try await fixture.store.snapshotMoveQueue().isEmpty)
    let errors = try await fixture.store.fetchErrorLog()
    #expect(errors.contains { $0.message == "Messages can only be moved within the same account" })
}

@MainActor
private final class MoveFixture {
    let root: URL
    let container: MailternalContainer
    let store: MailStore
    let account: AccountConfig
    let foreignAccount: AccountConfig
    let source: FolderID
    let destination: FolderID
    let messageID: MessageID
    let foreignMessageID: MessageID

    init(includeForeignMessage: Bool = false) async throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "mailternal-live-move-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        container = MailternalContainer(root: root)
        store = try MailStore(
            databaseURL: container.databaseURL,
            cachesDirectory: container.attachmentsDirectory
        )
        account = Self.account("move-owner")
        foreignAccount = Self.account("move-foreign")
        try await store.upsertAccount(account)
        source = try await store.upsertFolder(
            account: account.id,
            path: "INBOX",
            name: "INBOX",
            separator: nil,
            role: .inbox,
            objectID: nil
        )
        destination = try await store.upsertFolder(
            account: account.id,
            path: "Horrors2",
            name: "Horrors2",
            separator: nil,
            role: .none,
            objectID: nil
        )
        let generation = try await store.openLiveGeneration(
            folder: source,
            uidValidity: 1,
            baselineUID: IMAPUID(rawValue: 1)
        )
        try await store.upsertMessages([
            Self.message(generation: generation, uid: 7)
        ])
        messageID = try #require(await store.messageID(
            generation: generation,
            uid: IMAPUID(rawValue: 7)
        ))

        if includeForeignMessage {
            try await store.upsertAccount(foreignAccount)
            let foreignSource = try await store.upsertFolder(
                account: foreignAccount.id,
                path: "INBOX",
                name: "INBOX",
                separator: nil,
                role: .inbox,
                objectID: nil
            )
            let foreignGeneration = try await store.openLiveGeneration(
                folder: foreignSource,
                uidValidity: 1,
                baselineUID: IMAPUID(rawValue: 1)
            )
            try await store.upsertMessages([
                Self.message(generation: foreignGeneration, uid: 8)
            ])
            foreignMessageID = try #require(await store.messageID(
                generation: foreignGeneration,
                uid: IMAPUID(rawValue: 8)
            ))
        } else {
            foreignMessageID = MessageID(rawValue: -1)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func account(_ id: String) -> AccountConfig {
        AccountConfig(
            id: AccountID(rawValue: id),
            accountLinkID: AccountLinkID(uuidString: UUID().uuidString)!,
            displayName: id,
            emailAddress: "\(id)@example.com",
            username: "\(id)@example.com",
            imap: IMAPEndpoint(host: "imap.example.com", port: 993, security: .implicitTLS)
        )
    }

    private static func message(
        generation: MailboxGeneration,
        uid: UInt32
    ) -> IncomingMessage {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(uid))
        return IncomingMessage(
            generation: generation,
            uid: IMAPUID(rawValue: uid),
            envelope: Envelope(
                subject: "Move test \(uid)",
                from: [MailAddress(displayName: "Sender", address: "sender@example.com")],
                to: [MailAddress(displayName: nil, address: "recipient@example.com")],
                cc: [],
                replyTo: [],
                internalDate: date,
                headerDate: date,
                rfcMessageID: "<move-\(uid)@example.com>",
                inReplyTo: nil,
                references: []
            ),
            bodyText: "Move test body"
        )
    }
}
#endif
