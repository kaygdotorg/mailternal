import Foundation
import Testing
@testable import MailternalIMAP
@testable import MailternalSync

/// Regression tests for the shared-channel mailbox lease: a UID command bound
/// to one mailbox must never run against another task's stolen selection.
/// Root cause of the QA "Archive 19108/20000" loss: backfill FETCHes raced
/// seen-drain / delta SELECTs on the shared sync connection.
private func twoBoxWorld() -> ScriptedWorld {
    var archive = ScriptedMailbox(path: "Archive")
    archive.uidValidity = 7
    archive.uidNext = 4
    archive.messages[1] = makePlainMessage(uid: 1, subject: "a1", body: "alpha")
    archive.messages[2] = makePlainMessage(uid: 2, subject: "a2", body: "beta")
    archive.messages[3] = makePlainMessage(uid: 3, subject: "a3", body: "gamma")
    var inbox = ScriptedMailbox(path: "INBOX")
    inbox.uidValidity = 1
    inbox.uidNext = 1
    return ScriptedWorld(
        capabilities: basicCaps(),
        folders: [inboxMailbox()],
        mailboxes: ["INBOX": inbox, "Archive": archive]
    )
}

@Test
func channelFetchReselectsAfterStolenSelection() async throws {
    let client = ScriptedIMAPClient(world: twoBoxWorld())
    let channel = SyncChannel(client: client)
    try await channel.connect()
    _ = try await channel.select("Archive")
    // Another task steals the selection (seen drain / delta on INBOX).
    _ = try await channel.select("INBOX")
    // A mailbox-bound fetch must re-select Archive, not read INBOX.
    let fetched = try await channel.fetch(
        in: "Archive",
        expectedUIDValidity: 7,
        .flags(uids: IMAPUIDSet(1...10))
    )
    #expect(fetched.compactMap(\.uid).sorted() == [1, 2, 3])
}

@Test
func channelFetchThrowsStaleMailboxOnUIDValidityMismatch() async throws {
    let client = ScriptedIMAPClient(world: twoBoxWorld())
    let channel = SyncChannel(client: client)
    try await channel.connect()
    await #expect(throws: SyncChannelError.staleMailbox) {
        _ = try await channel.fetch(
            in: "Archive",
            expectedUIDValidity: 99,
            .flags(uids: IMAPUIDSet(1...10))
        )
    }
}

@Test
func channelStoreSeenVerifiesSelectedUIDValidity() async throws {
    let client = ScriptedIMAPClient(world: twoBoxWorld())
    let channel = SyncChannel(client: client)
    try await channel.connect()
    // Wrong pinned generation: no STORE may run.
    await #expect(throws: SyncChannelError.staleMailbox) {
        try await channel.storeSeen(
            in: "Archive",
            expectedUIDValidity: 99,
            uids: IMAPUIDSet(uid: 1)
        )
    }
    // Correct generation succeeds after a steal.
    _ = try await channel.select("INBOX")
    try await channel.storeSeen(
        in: "Archive",
        expectedUIDValidity: 7,
        uids: IMAPUIDSet(uid: 1)
    )
}
