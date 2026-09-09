import Foundation
import Testing
@testable import MailternalStore

@Test func flagUndoRestoresEachTargetActualOldState() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 1, subject: "unread", isRead: false, isFlagged: true),
            makeMessage(generation: generation, uid: 2, subject: "read", isRead: true, isFlagged: false),
        ])
        let first = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 1)))
        let second = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 2)))

        try await store.enqueueFlag(messages: [first, second], flag: .seen, set: true)
        let states = try await store.messageMutationStates([second, first, second])
        #expect(states.map(\.id) == [second, first])
        #expect(states.map(\.isRead) == [true, true])
        try await store.undo()

        let restored = try await store.messageMutationStates([first, second])
        #expect(restored.map(\.isRead) == [false, true])
        #expect(restored.map(\.isFlagged) == [true, false])
        let inverse = try #require(await store.snapshotFlagQueue().first)
        #expect(inverse.uid == IMAPUID(rawValue: 1))
        #expect(inverse.flag == .seen)
        #expect(inverse.set == false)
    }
}

@Test func undoScopeDenialDoesNotConsumeLatestOperation() async throws {
    try await withStore { store, _ in
        let (account, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([makeMessage(generation: generation, uid: 3, isRead: false)])
        let id = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 3)))
        try await store.enqueueFlag(message: id, flag: .seen, set: true)

        let other = AccountLinkID.random()
        #expect(try await store.canUndo(allowedAccountLinks: [other]) == false)
        do {
            try await store.undo(allowedAccountLinks: [other])
            Issue.record("undo should deny an operation outside the account scope")
        } catch MailUndoError.permissionDenied {
            // Expected: the newest operation is not skipped.
        }
        #expect(try await store.canUndo(allowedAccountLinks: [account.accountLinkID]) == true)
        #expect(try await store.snapshotFlagQueue().count == 1)
        _ = folder
    }
}

@Test func pendingMoveUndoWaitsForExactDestinationIdentity() async throws {
    try await withStore { store, _ in
        let (account, source, generation) = try await seedInbox(store)
        let destination = try await store.upsertFolder(
            account: account.id,
            path: "Archive",
            name: "Archive",
            separator: nil,
            role: .archive,
            objectID: nil
        )
        _ = try await store.upsertMessages([makeMessage(generation: generation, uid: 4)])
        let id = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 4)))
        try await store.enqueueMove(message: id, to: destination)
        let pending = try #require(await store.snapshotMoveQueue().first)
        #expect(try await store.claimMoveOp(pending))

        try await store.undo()
        #expect(try await store.snapshotMoveQueue().first?.id == pending.id)
        #expect(try await store.canUndo() == false)

        try await store.completeMoveOp(
            pending,
            destinations: [MoveDestinationIdentity(
                sourceUID: pending.uid,
                uidValidity: 9,
                uid: IMAPUID(rawValue: 44)
            )]
        )
        let inverse = try #require(await store.snapshotMoveQueue().first)
        #expect(inverse.folder == destination)
        #expect(inverse.uidValidity == 9)
        #expect(inverse.uid == IMAPUID(rawValue: 44))
        #expect(inverse.destinationFolderID == source)
    }
}

@Test func rejectedFlagBatchLeavesNoJournalOrPartialOptimism() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store)
        _ = try await store.upsertMessages([makeMessage(generation: generation, uid: 5, isRead: false)])
        let valid = try #require(await store.messageID(generation: generation, uid: IMAPUID(rawValue: 5)))
        let missing = MessageID(rawValue: 999_999)

        do {
            try await store.enqueueFlag(messages: [valid, missing], flag: .seen, set: true)
            Issue.record("the missing target should reject the complete batch")
        } catch MailStoreError.messageNotFound {
            // Expected atomic rejection.
        }
        let state = try #require(try await store.messageMutationStates([valid]).first)
        #expect(state.isRead == false)
        #expect(try await store.snapshotFlagQueue().isEmpty)
        #expect(try await store.canUndo() == false)
        _ = folder
    }
}
