import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

@Test
func enqueuedMoveDrainsOnRefreshWithoutPeriodicTick() async throws {
    try await withSyncStore { store, dir in
        var inboxBox = ScriptedMailbox(path: "INBOX", uidValidity: 1, uidNext: 2, highestModSeq: 1)
        inboxBox.messages[1] = makePlainMessage(uid: 1, subject: "wake move", body: "wake body")
        let destinationPath = "Horrors2"
        let destinationMailbox = IMAPMailbox(
            path: destinationPath,
            name: destinationPath,
            separator: "/",
            role: .none,
            mailboxID: nil,
            attributes: []
        )
        let world = ScriptedWorld(
            capabilities: IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE", "MOVE"]),
            folders: [inboxMailbox(), destinationMailbox],
            mailboxes: [
                "INBOX": inboxBox,
                destinationPath: ScriptedMailbox(path: destinationPath, uidValidity: 1)
            ]
        )
        let engine = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: world),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: testSettings(
                dir: dir,
                seenPoll: .seconds(30),
                periodicTick: .seconds(30)
            )
        )
        await engine.start()
        defer { Task { await engine.stop() } }

        try await waitUntil(timeout: .seconds(5)) {
            guard let inbox = try await inboxFolder(store) else { return false }
            return inbox.totalCount == 1 && inbox.backfill == .complete
        }
        let inboxFolderSummary = try #require(await inboxFolder(store))
        let message = try #require(
            try await store.page(in: inboxFolderSummary.id, after: nil, limit: 10).rows.first
        )
        let destination = try #require(
            try await store.fetchFolders(account: sampleConfig().id)
                .first(where: { $0.path == destinationPath })
        )
        try await store.enqueueMove(messages: [message.id], to: destination.id)

        let refresh = Task { await engine.refreshNow() }
        try await waitUntil(timeout: .seconds(3), poll: .milliseconds(20)) {
            let queued = try await store.snapshotMoveQueue()
            return world.archiveCommandSnapshot() == ["MOVE INBOX \(destinationPath) 1"]
                && queued.isEmpty
        }
        await refresh.value
        #expect(world.mailbox("INBOX").messages[1] == nil)
        #expect(world.mailbox(destinationPath).messages[1] != nil)
    }
}
