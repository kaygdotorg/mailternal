import Foundation
import Testing
@testable import MailternalStore

func withStore(
    cacheCap: Int64 = MailStore.defaultAttachmentCacheCapBytes,
    observationDebounce: Duration = MailStore.defaultObservationDebounce,
    _ body: (MailStore, URL) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailternal-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try MailStore(
        databaseURL: dir.appendingPathComponent("mail.sqlite"),
        cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true),
        attachmentCacheCapBytes: cacheCap,
        observationDebounce: observationDebounce
    )
    try await body(store, dir)
}

func sampleAccount(_ id: String = "acc-1") -> AccountConfig {
    AccountConfig(
        id: AccountID(rawValue: id),
        accountLinkID: AccountLinkID(
            uuidString: "00000000-0000-4000-8000-000000000010"
        )!,
        displayName: "Test",
        emailAddress: "test@example.com",
        username: "test@example.com",
        imap: IMAPEndpoint(host: "imap.example.com", port: 993, security: .implicitTLS)
    )
}

func seedInbox(_ store: MailStore, uidValidity: UInt32 = 1) async throws -> (AccountConfig, FolderID, MailboxGeneration) {
    let account = sampleAccount()
    try await store.upsertAccount(account)
    let folder = try await store.upsertFolder(
        account: account.id,
        path: "INBOX",
        name: "INBOX",
        separator: nil,
        role: .inbox,
        objectID: nil
    )
    let generation = try await store.openLiveGeneration(
        folder: folder,
        uidValidity: uidValidity,
        baselineUID: IMAPUID(rawValue: 1000)
    )
    return (account, folder, generation)
}

func makeMessage(
    generation: MailboxGeneration,
    uid: UInt32,
    subject: String = "Hello",
    fromName: String = "Alice",
    fromAddress: String = "alice@example.com",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    body: String? = "Body text",
    decodedBytes: Int = 0,
    isRead: Bool = false,
    isQuarantined: Bool = false,
    parseDefect: String? = nil
) -> IncomingMessage {
    IncomingMessage(
        generation: generation,
        uid: IMAPUID(rawValue: uid),
        envelope: Envelope(
            subject: subject,
            from: [MailAddress(displayName: fromName, address: fromAddress)],
            to: [MailAddress(displayName: nil, address: "test@example.com")],
            cc: [],
            replyTo: [],
            internalDate: date,
            headerDate: date,
            rfcMessageID: "<\(uid)@example.com>",
            inReplyTo: nil,
            references: uid == 1 ? [] : ["<1@example.com>"]
        ),
        flags: MessageFlags(isRead: isRead),
        bodyText: body,
        sanitizedHTML: nil,
        attachments: [],
        isTruncated: false,
        isQuarantined: isQuarantined,
        parseDefect: parseDefect,
        decodedBytes: decodedBytes
    )
}
