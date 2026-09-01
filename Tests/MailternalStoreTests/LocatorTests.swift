import Foundation
import Testing
@testable import MailternalStore

@Test func messageRefLocatesFolderGenerationAndUID() async throws {
    try await withStore { store, _ in
        let (_, folder, generation) = try await seedInbox(store, uidValidity: 7)
        _ = try await store.upsertMessages([
            makeMessage(generation: generation, uid: 42, subject: "loc"),
        ])
        let id = try await store.messageID(generation: generation, uid: IMAPUID(rawValue: 42))
        #expect(id != nil)
        let ref = try await store.messageRef(id!)
        #expect(ref?.folder == folder)
        #expect(ref?.generation == generation)
        #expect(ref?.uid.rawValue == 42)

        #expect(try await store.messageRef(MessageID(rawValue: 9_999_999)) == nil)
    }
}

@Test func messageRefWorksForNonLiveGeneration() async throws {
    try await withStore { store, _ in
        let (_, folder, live) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([makeMessage(generation: live, uid: 5)])
        let replacement = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 99,
            baselineUID: IMAPUID(rawValue: 1)
        )
        _ = try await store.upsertMessages([makeMessage(generation: replacement, uid: 3)])
        let id = try await store.messageID(generation: replacement, uid: IMAPUID(rawValue: 3))
        #expect(id != nil)
        let ref = try await store.messageRef(id!)
        #expect(ref?.folder == folder)
        #expect(ref?.generation == replacement)
        #expect(ref?.uid.rawValue == 3)
    }
}

@Test func messageRefNilAfterRetiredCleanup() async throws {
    try await withStore { store, _ in
        let (_, folder, live) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages([makeMessage(generation: live, uid: 1)])
        let oldID = try await store.messageID(generation: live, uid: IMAPUID(rawValue: 1))
        #expect(oldID != nil)

        _ = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 2,
            baselineUID: nil
        )
        try await store.activateReplacementGeneration(folder: folder)
        #expect(try await store.messageRef(oldID!) != nil)

        var deleted = 0
        repeat {
            let n = try await store.cleanupRetiredGenerations(batchSize: 10)
            deleted += n
            if n == 0 { break }
        } while true
        #expect(deleted >= 1)
        #expect(try await store.messageRef(oldID!) == nil)
        #expect(try await store.uids(in: live, range: nil).isEmpty)
    }
}

@Test func uidsListsAndFiltersInclusiveRange() async throws {
    try await withStore { store, _ in
        let (_, folder, live) = try await seedInbox(store, uidValidity: 1)
        _ = try await store.upsertMessages((1...5).map {
            makeMessage(generation: live, uid: UInt32($0))
        })
        let replacement = try await store.createReplacementGeneration(
            folder: folder,
            uidValidity: 2,
            baselineUID: IMAPUID(rawValue: 10)
        )
        _ = try await store.upsertMessages([
            makeMessage(generation: replacement, uid: 10),
            makeMessage(generation: replacement, uid: 12),
        ])

        #expect(try await store.uids(in: live, range: nil).map(\.rawValue) == [1, 2, 3, 4, 5])
        #expect(try await store.uids(in: live, range: 2...4).map(\.rawValue) == [2, 3, 4])
        #expect(try await store.uids(in: live, range: 5...5).map(\.rawValue) == [5])
        #expect(try await store.uids(in: live, range: 100...200).isEmpty)
        #expect(try await store.uids(in: replacement, range: nil).map(\.rawValue) == [10, 12])
        #expect(try await store.uids(in: replacement, range: 10...11).map(\.rawValue) == [10])

        let missing = MailboxGeneration(folder: folder, uidValidity: 404)
        #expect(try await store.uids(in: missing, range: nil).isEmpty)

        _ = try await store.deleteUIDs(generation: live, uids: [IMAPUID(rawValue: 3)])
        #expect(try await store.uids(in: live, range: nil).map(\.rawValue) == [1, 2, 4, 5])
        #expect(try await store.messageID(generation: live, uid: IMAPUID(rawValue: 3)) == nil)
    }
}
