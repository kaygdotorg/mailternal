import Foundation
import Testing
@testable import MailternalStore

@Suite struct UndoIdentityContinuityTests {
    @Test func offlineMoveUndoRestoresCachedMessageWithoutServerWork() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let archive = try await archiveFolder(store, account: account.id)
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 11, body: "Cached letter available offline")
            ])
            let id = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 11)))
            try await store.enqueueMove(message: id, to: archive)
            #expect(try await store.messageIDs(in: source, sort: .newest).isEmpty)

            try await store.undo()

            #expect(try await store.messageIDs(in: source, sort: .newest) == [id])
            #expect(try await store.detail(id).bodyText == "Cached letter available offline")
            #expect(try await store.snapshotMoveQueue().isEmpty)
        }
    }

    @Test func olderFlagUndoFollowsMoveAndInverseServerUIDs() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let archive = try await archiveFolder(store, account: account.id)
            let archiveGeneration = try await store.openLiveGeneration(
                folder: archive, uidValidity: 9, baselineUID: IMAPUID(rawValue: 1000)
            )
            _ = try await store.upsertMessages([makeMessage(generation: generation, uid: 12, isRead: false)])
            let id = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 12)))
            try await store.enqueueFlag(message: id, flag: .seen, set: true)
            for op in try await store.snapshotFlagQueue() { try await store.dequeueFlag(op) }
            try await store.enqueueMove(message: id, to: archive)
            let move = try #require(await store.snapshotMoveQueue().first)
            try await store.completeMoveOp(
                move,
                destinations: [MoveDestinationIdentity(sourceUID: IMAPUID(rawValue: 12), uidValidity: 9, uid: IMAPUID(rawValue: 112))]
            )
            // A real destination FETCH arrives under the server's new UID.
            _ = try await store.upsertMessages([
                makeMessage(generation: archiveGeneration, uid: 112, isRead: true)
            ])

            try await store.undo()
            let inverse = try #require(await store.snapshotMoveQueue().first)
            #expect(inverse.folder == archive)
            #expect(inverse.uid == IMAPUID(rawValue: 112))
            #expect(inverse.destinationFolderID == source)
            try await store.completeMoveOp(
                inverse,
                destinations: [MoveDestinationIdentity(sourceUID: IMAPUID(rawValue: 112), uidValidity: 1, uid: IMAPUID(rawValue: 212))]
            )
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 212, isRead: true)
            ])

            try await store.undo()

            let restoredID = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 212)))
            let restored = try #require(await store.messageMutationStates([restoredID]).first)
            #expect(restored.isRead == false)
            let pending = try #require(await store.snapshotFlagQueue().first)
            #expect(pending.folder == source)
            #expect(pending.uid == IMAPUID(rawValue: 212))
            #expect(pending.set == false)
        }
    }

    @Test func partialMoveRejectionKeepsSuccessfulMessagesUndoable() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let archive = try await archiveFolder(store, account: account.id)
            _ = try await store.openLiveGeneration(folder: archive, uidValidity: 9, baselineUID: IMAPUID(rawValue: 1000))
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 21),
                makeMessage(generation: generation, uid: 22)
            ])
            let first = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 21)))
            let second = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 22)))
            try await store.enqueueMove(messages: [first, second], to: archive)
            let moves = try await store.snapshotMoveQueue()
            let succeeded = try #require(moves.first { $0.uid == IMAPUID(rawValue: 21) })
            let rejected = try #require(moves.first { $0.uid == IMAPUID(rawValue: 22) })
            try await store.completeMoveOp(
                succeeded,
                destinations: [MoveDestinationIdentity(sourceUID: IMAPUID(rawValue: 21), uidValidity: 9, uid: IMAPUID(rawValue: 121))]
            )
            try await store.rejectMoveOp(rejected, reason: "Server refused this message")

            #expect(try await store.canUndo())
            try await store.undo()

            let inverse = try await store.snapshotMoveQueue()
            #expect(inverse.count == 1)
            #expect(inverse.first?.folder == archive)
            #expect(inverse.first?.uid == IMAPUID(rawValue: 121))
            #expect(inverse.first?.destinationFolderID == source)
        }
    }

    @Test func undoReversesCompletedMovesWhileCancellingUnclaimedSiblings() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let archive = try await archiveFolder(store, account: account.id)
            _ = try await store.openLiveGeneration(
                folder: archive, uidValidity: 9, baselineUID: IMAPUID(rawValue: 1000)
            )
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 31),
                makeMessage(generation: generation, uid: 32)
            ])
            let first = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 31)))
            let second = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 32)))
            try await store.enqueueMove(messages: [first, second], to: archive)
            let completed = try #require(await store.snapshotMoveQueue().first { $0.uid == IMAPUID(rawValue: 31) })
            try await store.completeMoveOp(
                completed,
                destinations: [MoveDestinationIdentity(sourceUID: IMAPUID(rawValue: 31), uidValidity: 9, uid: IMAPUID(rawValue: 131))]
            )

            try await store.undo()

            let pending = try await store.snapshotMoveQueue()
            #expect(pending.count == 1)
            #expect(pending.first?.folder == archive)
            #expect(pending.first?.uid == IMAPUID(rawValue: 131))
            #expect(pending.first?.destinationFolderID == source)
            #expect(try await store.messageIDs(in: source, sort: .newest) == [second])
        }
    }

    @Test func partialFlagRejectionKeepsAcknowledgedMessagesUndoable() async throws {
        try await withStore { store, _ in
            let (_, source, generation) = try await seedInbox(store)
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 41, isRead: false),
                makeMessage(generation: generation, uid: 42, isRead: false)
            ])
            let first = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 41)))
            let second = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 42)))
            try await store.enqueueFlag(messages: [first, second], flag: .seen, set: true)
            let operations = try await store.snapshotFlagQueue()
            let acknowledged = try #require(operations.first { $0.uid == IMAPUID(rawValue: 41) })
            let rejected = try #require(operations.first { $0.uid == IMAPUID(rawValue: 42) })
            try await store.dequeueFlag(acknowledged)
            try await store.dropFlag(rejected, reason: "Server refused this message")

            #expect(try await store.canUndo())
            try await store.undo()

            let pending = try await store.snapshotFlagQueue()
            #expect(pending.count == 1)
            #expect(pending.first?.folder == source)
            #expect(pending.first?.uid == IMAPUID(rawValue: 41))
            #expect(pending.first?.set == false)
            let states = try await store.messageMutationStates([first, second])
            #expect(states.allSatisfy { !$0.isRead })
        }
    }

    private func archiveFolder(_ store: MailStore, account: AccountID) async throws -> FolderID {
        try await store.upsertFolder(
            account: account, path: "Archive", name: "Archive",
            separator: nil, role: .archive, objectID: nil
        )
    }
}
