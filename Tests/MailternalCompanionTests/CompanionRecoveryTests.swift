import Foundation
import Testing
import MailternalCompanion

private let account = "00000000-0000-4000-8000-000000000001"
private let secondAccount = "00000000-0000-4000-8000-000000000002"
private let secondFolder = "mailternal://open/v1/account/\(secondAccount)/folder/path/SU5CT1g"
private let folder = "mailternal://open/v1/account/\(account)/folder/path/SU5CT1g"

@Test func boundedCompanionCachePreservesTransferredOrderAfterRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url, maxMessages: 2)
    let messages = [(1, 3), (2, 1), (3, 2)].map { uid, date in
        CompanionMessageSnapshot(
            canonicalLink: "\(folder)/message/7/\(uid)",
            folderLink: folder,
            accountLinkID: account,
            sender: "Sender",
            subject: "Message \(uid)",
            preview: "Preview",
            receivedAt: Date(timeIntervalSince1970: Double(date)),
            isRead: false,
            isFlagged: false,
            hasAttachments: false
        )
    }
    await store.merge(CompanionSnapshot(
        revision: 1,
        phoneStoreEpoch: "00000000-0000-4000-8000-000000000009",
        folders: [CompanionFolderSnapshot(
            canonicalLink: folder, accountLinkID: account, name: "INBOX", role: "inbox",
            unreadCount: 3, totalCount: 3
        )],
        messages: messages
    ))
    let reopened = CompanionStore(fileURL: url, maxMessages: 2)
    let state = await reopened.currentState()
    #expect(state.messages.map(\.canonicalLink) == messages.prefix(2).map(\.canonicalLink))
}

@Test func interruptedPhoneCommandBecomesReviewableWithoutReplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let phone = CompanionStore(fileURL: url)
    let command = CompanionCommand(
        accountLinkID: account,
        messageLink: "\(folder)/message/7/42",
        mutation: .archive
    )
    let acceptance = try #require(await phone.acceptOnPhone(command))
    #expect(acceptance.shouldExecute)
    #expect(await phone.markExecutionStarted(commandID: command.id))

    let restarted = CompanionStore(fileURL: url)
    let acknowledgements = await restarted.recoverPhoneCommands()
    #expect(acknowledgements.map(\.status) == [.needsReview])
    #expect(await restarted.recoverablePhoneCommands().isEmpty)
    let duplicate = try #require(await restarted.acceptOnPhone(command))
    #expect(!duplicate.shouldExecute)

    let reopened = CompanionStore(fileURL: url)
    let state = await reopened.currentState()
    #expect(state.commands.first?.status == .needsReview)
    #expect(await reopened.recoverablePhoneCommands().isEmpty)
}

@Test func unreadableCompanionJournalIsPreservedAndBlocksMutations() async throws {
    let fixtures = [
        Data("{not-json".utf8),
        Data(#"{"schema":"mailternal.companion.future","version":99}"#.utf8)
    ]
    let command = CompanionCommand(
        accountLinkID: account,
        messageLink: "\(folder)/message/7/43",
        mutation: .archive
    )

    for fixture in fixtures {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("companion.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.write(to: url)

        let store = CompanionStore(fileURL: url)
        let initial = await store.currentState()
        #expect(initial.lastError != nil)
        #expect(await store.enqueue(command) == nil)
        #expect(await store.acceptOnPhone(command) == nil)
        #expect(await store.recoverablePhoneCommands().isEmpty)
        #expect(try Data(contentsOf: url) == fixture)
        #expect((await store.currentState()).lastError == initial.lastError)
    }
}

@Test func outgoingCommandsRequireMatchingLinksAndUseNilMessageLinksWhenAppropriate() async throws {
    let otherAccount = "00000000-0000-4000-8000-000000000002"
    let command = CompanionCommand(
        accountLinkID: otherAccount,
        messageLink: "\(folder)/message/7/44",
        mutation: .send(CompanionSendContent(kind: .reply, body: "Thanks"))
    )
    #expect(!command.isSyntacticallyValid)

    let valid = CompanionCommand(
        accountLinkID: account,
        mutation: .send(CompanionSendContent(kind: .newMessage, to: "recipient@example.test"))
    )
    #expect(valid.isSyntacticallyValid)
    #expect(valid.messageLink == nil)
    #expect(valid.mutation.isOutgoing)
}

@Test func outgoingQueueDoesNotApplyMailFlagOptimism() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    await store.merge(CompanionSnapshot(
        revision: 1,
        phoneStoreEpoch: "00000000-0000-4000-8000-000000000009",
        folders: [CompanionFolderSnapshot(
            canonicalLink: folder, accountLinkID: account, name: "INBOX", role: "inbox",
            unreadCount: 1, totalCount: 1
        )],
        messages: [CompanionMessageSnapshot(
            canonicalLink: "\(folder)/message/7/45",
            folderLink: folder,
            accountLinkID: account,
            sender: "Sender",
            subject: "Original",
            preview: "Preview",
            receivedAt: Date(timeIntervalSince1970: 1),
            isRead: false,
            isFlagged: false,
            hasAttachments: false
        )],
        accounts: [CompanionAccountSnapshot(
            id: account, name: "Primary", email: "primary@example.test", canSend: true
        )]
    ))
    let command = CompanionCommand(
        accountLinkID: account,
        mutation: .send(CompanionSendContent(kind: .newMessage, to: "recipient@example.test"))
    )
    #expect(await store.enqueue(command) != nil)
    let cached = try #require((await store.currentState()).messages.first)
    #expect(!cached.isRead)
    #expect(!cached.isFlagged)
    #expect(!cached.isPendingRemoval)
}

@Test func oversizedEncodedCommandIsRejectedBeforeJournalMutation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    let before = try Data(contentsOf: url)
    let command = CompanionCommand(
        accountLinkID: account,
        mutation: .send(CompanionSendContent(
            kind: .newMessage,
            to: "recipient@example.test",
            body: String(repeating: "\u{0}", count: 16_384)
        ))
    )
    #expect(command.isSyntacticallyValid)
    #expect(await store.enqueue(command) == nil)
    #expect(try Data(contentsOf: url) == before)
    #expect((await store.currentState()).commands.isEmpty)
}

@Test func folderlessAccountSnapshotStillInvalidatesRemovedAccountCommands() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    let epoch = "00000000-0000-4000-8000-000000000009"
    await store.merge(CompanionSnapshot(
        revision: 1,
        phoneStoreEpoch: epoch,
        folders: [],
        messages: [],
        accounts: [CompanionAccountSnapshot(
            id: account, name: "Primary", email: "primary@example.test", canSend: true
        )]
    ))
    let command = CompanionCommand(
        accountLinkID: account,
        mutation: .send(CompanionSendContent(kind: .newMessage, to: "recipient@example.test"))
    )
    #expect(await store.enqueue(command) != nil)
    await store.merge(CompanionSnapshot(
        revision: 2,
        phoneStoreEpoch: epoch,
        folders: [],
        messages: [],
        accounts: [],
        accountsComplete: false
    ))
    let state = await store.currentState()
    #expect(state.commands.first?.status == .pendingOnWatch)
    await store.merge(CompanionSnapshot(
        revision: 3, phoneStoreEpoch: epoch, folders: [], messages: []
    ))
    #expect((await store.currentState()).commands.first?.status == .failed)
}

@Test func outgoingProjectionIsAuthoritativeAcrossInstallationRebase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    let firstEpoch = "00000000-0000-4000-8000-000000000009"
    let secondEpoch = "00000000-0000-4000-8000-000000000010"
    let submission = "00000000-0000-4000-8000-000000000011"
    await store.merge(CompanionSnapshot(
        revision: 1,
        phoneStoreEpoch: firstEpoch,
        folders: [],
        messages: [],
        accounts: [CompanionAccountSnapshot(
            id: account, name: "Primary", email: "primary@example.test", canSend: true
        )],
        outgoing: [CompanionOutgoingSnapshot(
            id: submission, accountLinkID: account, subject: "Queued",
            state: .queued
        )]
    ))
    #expect((await store.currentState()).outgoing.map(\.id) == [submission])
    await store.reconcilePhoneStoreEpoch(secondEpoch)
    let rebased = await store.currentState()
    #expect(rebased.outgoing.isEmpty)
    #expect(rebased.accounts.isEmpty)
}

@Test func partialAccountDisplaySnapshotPreservesCachedComposeAccounts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    let epoch = "00000000-0000-4000-8000-000000000009"
    await store.merge(CompanionSnapshot(
        revision: 1,
        phoneStoreEpoch: epoch,
        folders: [
            CompanionFolderSnapshot(
                canonicalLink: folder, accountLinkID: account, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            ),
            CompanionFolderSnapshot(
                canonicalLink: secondFolder, accountLinkID: secondAccount, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            )
        ],
        messages: [],
        accounts: [
            CompanionAccountSnapshot(
                id: account, name: "Primary", email: "primary@example.test", canSend: true
            ),
            CompanionAccountSnapshot(
                id: secondAccount, name: "Secondary", email: "secondary@example.test", canSend: true
            )
        ]
    ))
    await store.merge(CompanionSnapshot(
        revision: 2,
        phoneStoreEpoch: epoch,
        folders: [
            CompanionFolderSnapshot(
                canonicalLink: folder, accountLinkID: account, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            ),
            CompanionFolderSnapshot(
                canonicalLink: secondFolder, accountLinkID: secondAccount, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            )
        ],
        messages: [],
        accounts: [
            CompanionAccountSnapshot(
                id: account, name: "Primary (updated)", email: "primary@example.test", canSend: true
            )
        ],
        accountsComplete: true,
        accountDisplayEntriesComplete: false
    ))

    let accounts = (await store.currentState()).accounts
    #expect(accounts.map(\.id) == [account, secondAccount])
    #expect(accounts.first?.name == "Primary (updated)")
    #expect(accounts.last?.email == "secondary@example.test")
}

@Test func authoritativeAccountRemovalInvalidatesRemovedAccountMutation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    let epoch = "00000000-0000-4000-8000-000000000009"
    await store.merge(CompanionSnapshot(
        revision: 1,
        phoneStoreEpoch: epoch,
        folders: [
            CompanionFolderSnapshot(
                canonicalLink: folder, accountLinkID: account, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            ),
            CompanionFolderSnapshot(
                canonicalLink: secondFolder, accountLinkID: secondAccount, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            )
        ],
        messages: [],
        accounts: [
            CompanionAccountSnapshot(
                id: account, name: "Primary", email: "primary@example.test", canSend: true
            ),
            CompanionAccountSnapshot(
                id: secondAccount, name: "Secondary", email: "secondary@example.test", canSend: true
            )
        ]
    ))
    let command = CompanionCommand(
        accountLinkID: secondAccount,
        mutation: .send(CompanionSendContent(kind: .newMessage, to: "recipient@example.test"))
    )
    #expect(await store.enqueue(command) != nil)

    await store.merge(CompanionSnapshot(
        revision: 2,
        phoneStoreEpoch: epoch,
        folders: [
            CompanionFolderSnapshot(
                canonicalLink: folder, accountLinkID: account, name: "INBOX", role: "inbox",
                unreadCount: 0, totalCount: 0
            )
        ],
        messages: [],
        accounts: [
            CompanionAccountSnapshot(
                id: account, name: "Primary", email: "primary@example.test", canSend: true
            )
        ],
        accountsComplete: true,
        accountDisplayEntriesComplete: false
    ))

    let state = await store.currentState()
    #expect(state.accounts.map(\.id) == [account])
    #expect(state.commands.first?.status == .failed)
    #expect(state.commands.first?.failureReason == "The account was removed from iPhone.")
}

@Test func postEffectNeedsReviewAcknowledgementPreventsWatchReplay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("companion.json")
    let store = CompanionStore(fileURL: url)
    let command = CompanionCommand(
        accountLinkID: account,
        mutation: .send(CompanionSendContent(kind: .newMessage, to: "recipient@example.test"))
    )

    let accepted = try #require(await store.acceptOnPhone(command))
    #expect(accepted.shouldExecute)
    #expect(await store.markExecutionStarted(commandID: command.id))
    let ack = try #require(await store.markExecutionNeedsReview(
        commandID: command.id,
        reason: "The send effect was accepted, but completion could not be recorded."
    ))
    #expect(ack.status == .needsReview)
    #expect((await store.currentState()).commands.first?.status == .needsReview)
    #expect(await store.recoverablePhoneCommands().isEmpty)

    let duplicate = try #require(await store.acceptOnPhone(command))
    #expect(!duplicate.shouldExecute)
    #expect(duplicate.record.status == .needsReview)
}
