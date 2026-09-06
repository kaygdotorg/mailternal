import Foundation
import Testing
import MailternalCompanion

private let account = "00000000-0000-4000-8000-000000000001"
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
