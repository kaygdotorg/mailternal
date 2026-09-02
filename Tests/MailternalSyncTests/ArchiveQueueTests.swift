import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

private func archiveMailbox() -> IMAPMailbox {
    IMAPMailbox(
        path: "Archive",
        name: "Archive",
        separator: "/",
        role: .archive,
        mailboxID: nil,
        attributes: ["\\Archive"]
    )
}

private func archiveWorld(capabilities: IMAPCapabilities, includeArchive: Bool = true) -> ScriptedWorld {
    var inbox = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
    inbox.messages[1] = makePlainMessage(uid: 1, subject: "archive me")
    var folders: [IMAPMailbox] = [inboxMailbox()]
    var mailboxes: [String: ScriptedMailbox] = ["INBOX": inbox]
    if includeArchive {
        folders.append(archiveMailbox())
        mailboxes["Archive"] = ScriptedMailbox(path: "Archive", uidValidity: 1)
    }
    return ScriptedWorld(capabilities: capabilities, folders: folders, mailboxes: mailboxes)
}

private func waitForArchiveInbox(_ store: MailStore) async throws -> (FolderID, MessageID) {
    try await waitUntil(timeout: .seconds(5)) {
        guard let inbox = try await inboxFolder(store), inbox.totalCount == 1 else { return false }
        return inbox.backfill == .complete
    }
    let inbox = try #require(await inboxFolder(store))
    let page = try await store.page(in: inbox.id, after: nil, limit: 10)
    let message = try #require(page.rows.first)
    return (inbox.id, message.id)
}

@Test func engineArchivesWithMoveAndDequeuesOperation() async throws {
    try await withSyncStore { store, dir in
        let world = archiveWorld(capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]))
        let engine = makeEngine(store: store, world: world, dir: dir).0
        await engine.start()
        let (folder, message) = try await waitForArchiveInbox(store)

        try await store.enqueueMove(message: message, to: .archive)

        try await waitUntil(timeout: .seconds(3)) {
            guard try await store.snapshotMoveQueue().isEmpty else { return false }
            return world.archiveCommandSnapshot() == ["MOVE INBOX Archive 1"]
        }
        #expect(world.mailbox("INBOX").messages[1] == nil)
        #expect(world.mailbox("Archive").messages[1] != nil)
        #expect(try await store.page(in: folder, after: nil, limit: 10).rows.isEmpty)
        await engine.stop()
    }
}

@Test func engineArchivesWithCopyStoreExpungeFallback() async throws {
    try await withSyncStore { store, dir in
        let world = archiveWorld(capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE"]))
        let engine = makeEngine(store: store, world: world, dir: dir).0
        await engine.start()
        _ = try await waitForArchiveInbox(store)
        let inbox = try #require(await inboxFolder(store))
        let message = try #require(await store.page(in: inbox.id, after: nil, limit: 10).rows.first?.id)

        try await store.enqueueMove(message: message, to: .archive)

        try await waitUntil(timeout: .seconds(3)) {
            guard try await store.snapshotMoveQueue().isEmpty else { return false }
            return world.archiveCommandSnapshot() == [
                "COPY INBOX Archive 1",
                "STORE INBOX 1",
                "EXPUNGE INBOX 1",
            ]
        }
        #expect(world.mailbox("INBOX").messages[1] == nil)
        #expect(world.mailbox("Archive").messages[1] != nil)
        await engine.stop()
    }
}

@Test func engineRetriesFallbackAfterCopiedWithoutRepeatingCopy() async throws {
    try await withSyncStore { store, dir in
        let world = archiveWorld(capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE"]))
        world.storeDeletedError = IMAPError.taggedNO(
            tag: "t",
            message: "STORE failed",
            code: nil
        )
        let engine = makeEngine(store: store, world: world, dir: dir).0
        await engine.start()
        _ = try await waitForArchiveInbox(store)
        let inbox = try #require(await inboxFolder(store))
        let message = try #require(await store.page(
            in: inbox.id,
            after: nil,
            limit: 10
        ).rows.first?.id)
        try await store.enqueueMove(message: message, to: .archive)

        try await waitUntil(timeout: .seconds(3)) {
            let pending = try await store.snapshotMoveQueue()
            guard pending.first?.copied == true else { return false }
            let errors = try await store.fetchErrorLog()
            return errors.contains {
                $0.kind == .archive && $0.message.contains("phase STORE")
            }
        }
        world.storeDeletedError = nil
        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotMoveQueue().isEmpty
                && world.archiveCommandSnapshot() == [
                    "COPY INBOX Archive 1",
                    "STORE INBOX 1",
                    "EXPUNGE INBOX 1",
                ]
        }
        await engine.stop()
    }
}

@Test func stopWaitsForInFlightArchiveFallback() async throws {
    try await withSyncStore { store, dir in
        let world = archiveWorld(capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE"]))
        world.pauseArchiveStore = true
        let (engine, factory) = makeEngine(store: store, world: world, dir: dir)
        await engine.start()
        _ = try await waitForArchiveInbox(store)
        let inbox = try #require(await inboxFolder(store))
        let message = try #require(await store.page(
            in: inbox.id,
            after: nil,
            limit: 10
        ).rows.first?.id)
        try await store.enqueueMove(message: message, to: .archive)
        try await waitUntil(timeout: .seconds(3)) {
            world.archiveStoreDidEnter()
        }

        let stopping = Task { await engine.stop() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await factory.closedClientCount() == 0)

        world.releaseArchiveStore()
        await stopping.value
        #expect(world.archiveCommandSnapshot() == [
            "COPY INBOX Archive 1",
            "STORE INBOX 1",
            "EXPUNGE INBOX 1",
        ])
        #expect(try await store.snapshotMoveQueue().isEmpty)
    }
}

@Test func engineDropsArchiveOperationAfterUIDValidityReplacement() async throws {
    try await withSyncStore { store, dir in
        let world = archiveWorld(capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]))
        let engine = makeEngine(store: store, world: world, dir: dir).0
        await engine.start()
        let (folder, _) = try await waitForArchiveInbox(store)

        world.updateMailbox("INBOX") { live in
            live.uidValidity = 2
        }
        try await store.enqueueMove(account: sampleConfig().id,
        folder: folder,
        uidValidity: 1,
        uid: IMAPUID(rawValue: 1), to: .archive)

        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotMoveQueue().isEmpty
        }
        #expect(world.archiveCommandSnapshot().isEmpty)
        await engine.stop()
    }
}

@Test func engineDropsArchiveWhenArchiveFolderIsMissingAndRecordsError() async throws {
    try await withSyncStore { store, dir in
        let world = archiveWorld(
            capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]),
            includeArchive: false
        )
        let engine = makeEngine(store: store, world: world, dir: dir).0
        await engine.start()
        let (_, message) = try await waitForArchiveInbox(store)

        try await store.enqueueMove(message: message, to: .archive)

        try await waitUntil(timeout: .seconds(3)) {
            try await store.snapshotMoveQueue().isEmpty
        }
        let errors = try await store.fetchErrorLog()
        #expect(errors.contains { $0.kind == .archive && $0.message == "no Archive folder" })
        #expect(world.archiveCommandSnapshot().isEmpty)
        await engine.stop()
    }
}
