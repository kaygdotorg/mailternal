import Foundation
import Testing
@testable import MailternalStore

private let deepLinkAccount = AccountLinkID(
    uuidString: "123e4567-e89b-42d3-a456-426614174000"
)!

private func deepLinkAccountConfig(_ id: String, linkID: AccountLinkID = deepLinkAccount) -> AccountConfig {
    AccountConfig(
        id: AccountID(rawValue: id),
        accountLinkID: linkID,
        displayName: "Test",
        emailAddress: "test@example.com",
        username: "test@example.com",
        imap: IMAPEndpoint(host: "imap.example.com", port: 993, security: .implicitTLS)
    )
}

@Test func deepLinkRoundTripsUnicodeAndSlashLocator() {
    let link = MailternalDeepLink.message(
        accountLinkID: deepLinkAccount,
        folderLocator: FolderLocator(kind: .path, value: "旅行/受信箱"),
        uidValidity: 4_294_967_295,
        uid: IMAPUID(rawValue: 42)
    )
    let encoded = Data("旅行/受信箱".utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let expected = "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/\(encoded)/message/4294967295/42"
    #expect(link.formattedString == expected)
    #expect(MailternalDeepLink(string: expected) == link)
    #expect(MailternalDeepLink(url: link.formattedURL!) == link)
}

@Test func deepLinkRejectsMalformedGrammarAndNonCanonicalValues() {
    let valid = "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/object/bWFpbGJveA/message/1/2"
    let malformed = [
        "MAILTERNAL://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA",
        "mailternal://open/v2/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA",
        "mailternal://open/v1/account/123E4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA",
        "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA/message/01/2",
        "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGveA/message/1/2",
        "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA/message/1/4294967296",
        "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA?x=1",
        "mailternal://user:pass@open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/bWFpbGJveA",
        valid + "/",
    ]
    #expect(MailternalDeepLink(string: valid) != nil)
    for raw in malformed {
        #expect(MailternalDeepLink(string: raw) == nil, "accepted malformed link: \(raw)")
    }
}

@Test func deepLinkRejectsInvalidLocatorsAndLength() {
    let control: MailternalDeepLink = .folder(
        accountLinkID: deepLinkAccount,
        folderLocator: FolderLocator(kind: .path, value: "mail\u{0000}box")
    )
    #expect(control.formattedString == nil)

    let tooLarge: MailternalDeepLink = .folder(
        accountLinkID: deepLinkAccount,
        folderLocator: FolderLocator(kind: .path, value: String(repeating: "x", count: 1_025))
    )
    #expect(tooLarge.formattedString == nil)

    let zeroes = "mailternal://open/v1/account/123e4567-e89b-42d3-a456-426614174000/folder/path/eA/message/0/1"
    #expect(MailternalDeepLink(string: zeroes) == nil)
}

@Test func accountLinkIDPersistsAcrossMetadataUpdates() async throws {
    try await withStore { store, _ in
        let original = deepLinkAccountConfig("stable")
        try await store.upsertAccount(original)

        var edited = original
        edited.accountLinkID = AccountLinkID(
            uuidString: "123e4567-e89b-42d3-a456-426614174001"
        )!
        edited.displayName = "Edited"
        try await store.upsertAccount(edited)

        let fetched = try await store.fetchAccount(original.id)
        #expect(fetched?.displayName == "Edited")
        #expect(fetched?.accountLinkID == original.accountLinkID)
    }
}

@Test func crossDeviceObjectLocatorResolvesDifferentLocalIDs() async throws {
    try await withStore { first, _ in
        let accountA = deepLinkAccountConfig("device-a")
        try await first.upsertAccount(accountA)
        let folderA = try await first.upsertFolder(
            account: accountA.id, path: "Old Name", name: "Old Name", separator: nil,
            role: .none, objectID: "object-42"
        )
        let generationA = try await first.openLiveGeneration(
            folder: folderA, uidValidity: 8, baselineUID: IMAPUID(rawValue: 10)
        )
        try await first.upsertMessages([makeMessage(generation: generationA, uid: 10, subject: "Shared")])
        let messageIDA = try #require(await first.messageID(
            generation: generationA, uid: IMAPUID(rawValue: 10)
        ))
        let link = try #require(await first.makeDeepLink(account: accountA.id, message: messageIDA))

        try await withStore { second, _ in
            let accountB = deepLinkAccountConfig("device-b")
            try await second.upsertAccount(accountB)
            let folderB = try await second.upsertFolder(
                account: accountB.id, path: "Renamed", name: "Renamed", separator: nil,
                role: .none, objectID: "object-42"
            )
            let generationB = try await second.openLiveGeneration(
                folder: folderB, uidValidity: 8, baselineUID: IMAPUID(rawValue: 10)
            )
            try await second.upsertMessages([
                makeMessage(generation: generationB, uid: 9, subject: "Earlier"),
                makeMessage(generation: generationB, uid: 10, subject: "Shared")
            ])
            let messageIDB = try #require(await second.messageID(
                generation: generationB, uid: IMAPUID(rawValue: 10)
            ))
            let resolution = try await second.resolve(link)
            guard case .message(let resolvedFolder, let resolvedMessage, let row) = resolution else {
                Issue.record("object locator did not resolve a message")
                return
            }
            #expect(resolvedFolder == folderB)
            #expect(resolvedMessage == messageIDB)
            #expect(resolvedMessage != messageIDA)
            #expect(row.subject == "Shared")
        }
    }
}

@Test func objectLocatorSurvivesRenameAndPathLocatorBecomesStale() async throws {
    try await withStore { store, _ in
        let account = deepLinkAccountConfig("rename")
        try await store.upsertAccount(account)
        let objectFolder = try await store.upsertFolder(
            account: account.id, path: "Before", name: "Before", separator: nil,
            role: .none, objectID: "rename-object"
        )
        let objectLink = try await store.makeDeepLink(account: account.id, folder: objectFolder)!
        let renamed = try await store.upsertFolder(
            account: account.id, path: "After", name: "After", separator: nil,
            role: .none, objectID: "rename-object"
        )
        #expect(renamed == objectFolder)
        #expect(try await store.resolve(objectLink) == .folder(objectFolder))

        let pathFolder = try await store.upsertFolder(
            account: account.id, path: "Path Before", name: "Path Before", separator: nil,
            role: .none, objectID: nil
        )
        let pathLink = try await store.makeDeepLink(account: account.id, folder: pathFolder)!
        _ = try await store.reconcileFolders(account: account.id, seen: [FolderKey(path: "Path After")])
        _ = try await store.upsertFolder(
            account: account.id, path: "Path After", name: "Path After", separator: nil,
            role: .none, objectID: nil
        )
        #expect(try await store.resolve(pathLink) == nil)
    }
}

@Test func messageLinkRejectsOldGenerationAndExpungedUID() async throws {
    try await withStore { store, _ in
        let account = deepLinkAccountConfig("generation")
        try await store.upsertAccount(account)
        let folder = try await store.upsertFolder(
            account: account.id, path: "INBOX", name: "INBOX", separator: nil,
            role: .inbox, objectID: "inbox-object"
        )
        let first = try await store.openLiveGeneration(
            folder: folder, uidValidity: 1, baselineUID: IMAPUID(rawValue: 2)
        )
        try await store.upsertMessages([makeMessage(generation: first, uid: 2)])
        let messageID = try #require(await store.messageID(
            generation: first, uid: IMAPUID(rawValue: 2)
        ))
        let link = try #require(await store.makeDeepLink(account: account.id, message: messageID))
        try await store.deleteUIDs(generation: first, uids: [IMAPUID(rawValue: 2)])
        #expect(try await store.resolve(link) == nil)

        try await store.upsertMessages([makeMessage(generation: first, uid: 2)])
        let replacement = try await store.createReplacementGeneration(
            folder: folder, uidValidity: 2, baselineUID: IMAPUID(rawValue: 2)
        )
        try await store.upsertMessages([makeMessage(generation: replacement, uid: 2)])
        try await store.activateReplacementGeneration(folder: folder)
        #expect(try await store.resolve(link) == nil)
    }
}
