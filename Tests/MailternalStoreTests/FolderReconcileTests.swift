import Foundation
import Testing
@testable import MailternalStore

@Test func pathOnlyRenameRetiresOldFolderAndCleansFTS() async throws {
    try await withStore { store, _ in
        let (account, _, _) = try await seedInbox(store)
        let work = try await store.upsertFolder(
            account: account.id,
            path: "Work",
            name: "Work",
            separator: nil,
            role: .none,
            objectID: nil
        )
        let workGen = try await store.openLiveGeneration(
            folder: work,
            uidValidity: 3,
            baselineUID: IMAPUID(rawValue: 10)
        )
        _ = try await store.upsertMessages([
            makeMessage(
                generation: workGen,
                uid: 1,
                subject: "old path mail",
                body: "oldpathtoken unique body"
            ),
        ])

        let projects = try await store.upsertFolder(
            account: account.id,
            path: "Projects",
            name: "Projects",
            separator: nil,
            role: .none,
            objectID: nil
        )
        #expect(projects != work)

        let retired = try await store.reconcileFolders(
            account: account.id,
            seen: [
                FolderKey(path: "INBOX"),
                FolderKey(path: "Projects"),
            ]
        )
        #expect(Set(retired) == [work])
        #expect(try await store.generationState(workGen) == .retiring)
        #expect(try await store.liveGenerationID(for: work) == nil)
        #expect(try await store.fetchFolderSummary(work) == nil)

        let summaries = try await store.fetchFolders(account: account.id)
        #expect(Set(summaries.map(\.path)) == ["INBOX", "Projects"])
        #expect(summaries.map(\.id).filter { $0 == work }.isEmpty)
        #expect(try await store.page(in: work, after: nil, limit: 10).rows.isEmpty)
        #expect(try await store.search("oldpathtoken", limit: 10).isEmpty)
        #expect(try await store.ftsUnfilteredCount(matching: "oldpathtoken") == 1)

        var deleted = 0
        repeat {
            let n = try await store.cleanupRetiredGenerations(batchSize: 10)
            deleted += n
            if n == 0 { break }
        } while true
        #expect(deleted >= 1)
        #expect(try await store.ftsUnfilteredCount(matching: "oldpathtoken") == 0)
        #expect(try await store.search("oldpathtoken", limit: 10).isEmpty)

        let again = try await store.reconcileFolders(
            account: account.id,
            seen: [
                FolderKey(path: "INBOX"),
                FolderKey(path: "Projects"),
            ]
        )
        #expect(again.isEmpty)
    }
}

@Test func objectIDRenameDoesNotRetire() async throws {
    try await withStore { store, _ in
        let (account, _, _) = try await seedInbox(store)
        let work = try await store.upsertFolder(
            account: account.id,
            path: "Work",
            name: "Work",
            separator: "/",
            role: .none,
            objectID: "mbox-1"
        )
        let generation = try await store.openLiveGeneration(
            folder: work,
            uidValidity: 7,
            baselineUID: IMAPUID(rawValue: 1)
        )
        _ = try await store.upsertMessages([
            makeMessage(
                generation: generation,
                uid: 2,
                subject: "kept mail",
                body: "objectidtoken unique body"
            ),
        ])
        let renamed = try await store.upsertFolder(
            account: account.id,
            path: "Projects",
            name: "Projects",
            separator: ".",
            role: .none,
            objectID: "mbox-1"
        )
        #expect(renamed == work)

        let retired = try await store.reconcileFolders(
            account: account.id,
            seen: [
                FolderKey(path: "INBOX"),
                FolderKey(path: "Projects", objectID: "mbox-1"),
            ]
        )
        #expect(retired.isEmpty)

        let summaries = try await store.fetchFolders(account: account.id)
        #expect(Set(summaries.map(\.path)) == ["INBOX", "Projects"])
        #expect(summaries.filter { $0.path == "Work" }.isEmpty)
        let project = try await store.fetchFolderSummary(work)
        #expect(project?.path == "Projects")
        #expect(project?.id == work)
        #expect(project?.separator == ".")

        let hits = try await store.search("objectidtoken", limit: 10)
        #expect(hits.count == 1)
        #expect(try await store.generationState(generation) == .live)
        #expect(try await store.page(in: work, after: nil, limit: 10).rows.count == 1)
    }
}
