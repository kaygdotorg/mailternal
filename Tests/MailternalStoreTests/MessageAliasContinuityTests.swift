import Foundation
import Testing
@testable import MailternalStore

@Suite struct MessageAliasContinuityTests {
    @Test func mappedMoveRetainsCachedBodyAndStableLocalID() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let destination = try await archiveFolder(store, account: account.id, path: "Archive")
            let destinationGeneration = try await store.openLiveGeneration(
                folder: destination,
                uidValidity: 9,
                baselineUID: IMAPUID(rawValue: 1000)
            )
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 11, body: "Cached move body")
            ])
            let id = try #require(await store.messageID(
                generation: generation,
                uid: IMAPUID(rawValue: 11)
            ))
            try await store.enqueueMove(message: id, to: destination)
            let operation = try #require(await store.snapshotMoveQueue().first)

            try await store.completeMoveOp(
                operation,
                destinations: [MoveDestinationIdentity(
                    sourceUID: operation.uid,
                    uidValidity: destinationGeneration.uidValidity,
                    uid: IMAPUID(rawValue: 111)
                )]
            )

            #expect(try await store.messageID(
                generation: destinationGeneration,
                uid: IMAPUID(rawValue: 111)
            ) == id)
            #expect(try await store.detail(id).bodyText == "Cached move body")
            #expect(try await store.messageRef(id)?.folder == destination)
            let state = try #require(await store.messageMutationStates([id]).first)
            #expect(state.canonicalID == id)
            #expect(state.link?.messageLocator?.uidValidity == destinationGeneration.uidValidity)
            #expect(state.link?.messageLocator?.uid == IMAPUID(rawValue: 111))
            #expect(try await store.messageIDs(in: source, sort: .newest).isEmpty)
        }
    }

    @Test func destinationCollisionRetainsAliasAndCascadesOnCacheDeletion() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let destination = try await archiveFolder(store, account: account.id, path: "Archive")
            let destinationGeneration = try await store.openLiveGeneration(
                folder: destination,
                uidValidity: 9,
                baselineUID: IMAPUID(rawValue: 1000)
            )
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 21, body: "Source body"),
                makeMessage(generation: destinationGeneration, uid: 121, body: "Fetched destination")
            ])
            let sourceID = try #require(await store.messageID(
                generation: generation,
                uid: IMAPUID(rawValue: 21)
            ))
            let destinationID = try #require(await store.messageID(
                generation: destinationGeneration,
                uid: IMAPUID(rawValue: 121)
            ))
            try await store.enqueueMove(message: sourceID, to: destination)
            let operation = try #require(await store.snapshotMoveQueue().first)

            try await store.completeMoveOp(
                operation,
                destinations: [MoveDestinationIdentity(
                    sourceUID: operation.uid,
                    uidValidity: destinationGeneration.uidValidity,
                    uid: IMAPUID(rawValue: 121)
                )]
            )

            #expect(sourceID != destinationID)
            #expect(try await store.detail(sourceID).bodyText == "Fetched destination")
            let state = try #require(await store.messageMutationStates([sourceID]).first)
            #expect(state.id == sourceID)
            #expect(state.canonicalID == destinationID)
            #expect(state.folderID == destination)
            #expect(try await store.messageRef(sourceID)?.uid == IMAPUID(rawValue: 121))

            try await store.deleteUIDs(
                generation: destinationGeneration,
                uids: [IMAPUID(rawValue: 121)]
            )
            #expect(try await store.details([sourceID]).isEmpty)
            #expect(try await store.accountID(for: sourceID) == nil)
        }
    }

    @Test func inverseMappedMoveFollowsExactDestinationAndKeepsContent() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let destination = try await archiveFolder(store, account: account.id, path: "Archive")
            let destinationGeneration = try await store.openLiveGeneration(
                folder: destination,
                uidValidity: 9,
                baselineUID: IMAPUID(rawValue: 1000)
            )
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 31, body: "Undoable body")
            ])
            let id = try #require(await store.messageID(
                generation: generation,
                uid: IMAPUID(rawValue: 31)
            ))
            try await store.enqueueMove(message: id, to: destination)
            let first = try #require(await store.snapshotMoveQueue().first)
            try await store.completeMoveOp(
                first,
                destinations: [MoveDestinationIdentity(
                    sourceUID: first.uid,
                    uidValidity: destinationGeneration.uidValidity,
                    uid: IMAPUID(rawValue: 131)
                )]
            )

            try await store.undo()
            let inverse = try #require(await store.snapshotMoveQueue().first)
            #expect(inverse.folder == destination)
            #expect(inverse.uid == IMAPUID(rawValue: 131))
            #expect(inverse.destinationFolderID == source)
            try await store.completeMoveOp(
                inverse,
                destinations: [MoveDestinationIdentity(
                    sourceUID: inverse.uid,
                    uidValidity: generation.uidValidity,
                    uid: IMAPUID(rawValue: 231)
                )]
            )

            #expect(try await store.messageID(
                generation: generation,
                uid: IMAPUID(rawValue: 231)
            ) == id)
            #expect(try await store.detail(id).bodyText == "Undoable body")
            #expect(try await store.messageRef(id)?.folder == source)
        }
    }

    @Test func mappedMoveIntoReplacementNeverRelabelsOrActivatesLiveGeneration() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let destination = try await archiveFolder(store, account: account.id, path: "Archive")
            let liveDestination = try await store.openLiveGeneration(
                folder: destination,
                uidValidity: 9,
                baselineUID: IMAPUID(rawValue: 1000)
            )
            let replacement = try await store.createReplacementGeneration(
                folder: destination,
                uidValidity: 10,
                baselineUID: IMAPUID(rawValue: 2000)
            )
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 41, body: "Replacement-safe body")
            ])
            let id = try #require(await store.messageID(
                generation: generation,
                uid: IMAPUID(rawValue: 41)
            ))
            try await store.enqueueMove(message: id, to: destination)
            let operation = try #require(await store.snapshotMoveQueue().first)

            try await store.completeMoveOp(
                operation,
                destinations: [MoveDestinationIdentity(
                    sourceUID: operation.uid,
                    uidValidity: replacement.uidValidity,
                    uid: IMAPUID(rawValue: 141)
                )]
            )

            #expect(try await store.liveGeneration(for: destination) == liveDestination)
            #expect(try await store.messageID(
                generation: replacement,
                uid: IMAPUID(rawValue: 141)
            ) == id)
            #expect(try await store.detail(id).bodyText == "Replacement-safe body")
        }
    }

    @Test func mappedMoveCreatesExactUnactivatedReplacementWithoutBaselineGuess() async throws {
        try await withStore { store, _ in
            let (account, source, generation) = try await seedInbox(store)
            let destination = try await archiveFolder(store, account: account.id, path: "NotYetSelected")
            _ = try await store.upsertMessages([
                makeMessage(generation: generation, uid: 51, body: "Deferred destination body")
            ])
            let id = try #require(await store.messageID(
                generation: generation,
                uid: IMAPUID(rawValue: 51)
            ))
            try await store.enqueueMove(message: id, to: destination)
            let operation = try #require(await store.snapshotMoveQueue().first)

            try await store.completeMoveOp(
                operation,
                destinations: [MoveDestinationIdentity(
                    sourceUID: operation.uid,
                    uidValidity: 12,
                    uid: IMAPUID(rawValue: 151)
                )]
            )

            #expect(try await store.liveGeneration(for: destination) == nil)
            let replacement = MailboxGeneration(folder: destination, uidValidity: 12)
            #expect(try await store.messageID(
                generation: replacement,
                uid: IMAPUID(rawValue: 151)
            ) == id)
            #expect(try await store.fetchSyncState(for: replacement)?.baselineUID == nil)
            #expect(try await store.detail(id).bodyText == "Deferred destination body")
        }
    }

    private func archiveFolder(
        _ store: MailStore,
        account: AccountID,
        path: String
    ) async throws -> FolderID {
        try await store.upsertFolder(
            account: account,
            path: path,
            name: path,
            separator: nil,
            role: .archive,
            objectID: nil
        )
    }
}
