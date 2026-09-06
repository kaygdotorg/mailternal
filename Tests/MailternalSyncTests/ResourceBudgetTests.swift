import Foundation
import Testing
import MailternalIMAP
import MailternalStore
@testable import MailternalSync

@Test func backfillBudgetFairlyServesQueuedAccounts() async throws {
    let budget = BackfillConnectionBudget(capacity: 4)
    let first = try #require(await budget.acquire(owner: AccountID(rawValue: "account-a")))
    let second = try #require(await budget.acquire(owner: AccountID(rawValue: "account-a")))
    let third = try #require(await budget.acquire(owner: AccountID(rawValue: "account-a")))

    let accountA = AccountID(rawValue: "account-a")
    let accountB = AccountID(rawValue: "account-b")
    let aWaiter = Task { await budget.acquire(owner: accountA) }
    try await Task.sleep(for: .milliseconds(20))
    let bWaiter = Task { await budget.acquire(owner: accountB) }
    #expect((await budget.snapshot()).waiting >= 1)

    await budget.release(first)
    let bLease = try #require(await bWaiter.value)
    #expect((await budget.snapshot()).activeByOwner[accountB] == 1)

    aWaiter.cancel()
    if let aLease = await aWaiter.value {
        await budget.release(aLease)
    }
    await budget.release(second)
    await budget.release(third)
    await budget.release(bLease)
}

@Test func twoScriptedEnginesShareBackfillConnectionBudget() async throws {
    try await withSyncStore { store, dir in
        var mailboxA = populatedInbox(uidValidity: 1, count: 1, prefix: "account-a")
        var mailboxB = populatedInbox(uidValidity: 1, count: 1, prefix: "account-b")
        mailboxA.messages[1] = makePlainMessage(uid: 1, subject: "a", body: "a body")
        mailboxB.messages[1] = makePlainMessage(uid: 1, subject: "b", body: "b body")
        let worldA = ScriptedWorld(capabilities: basicCaps(), folders: [inboxMailbox()], mailboxes: ["INBOX": mailboxA])
        let worldB = ScriptedWorld(capabilities: basicCaps(), folders: [inboxMailbox()], mailboxes: ["INBOX": mailboxB])
        worldA.fetchNanos = 20_000_000
        worldB.fetchNanos = 20_000_000
        let budget = BackfillConnectionBudget(capacity: 4)
        var configB = sampleConfig()
        configB.id = AccountID(rawValue: "qa-b")
        let engineA = SyncEngine(
            store: store,
            config: sampleConfig(),
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: worldA),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: chaosSettings(dir: dir, window: 1),
            backfillBudget: budget
        )
        let engineB = SyncEngine(
            store: store,
            config: configB,
            credentials: StaticPassword(value: "pw"),
            clientFactory: ScriptedFactory(world: worldB),
            disk: ampleDisk(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            settings: chaosSettings(dir: dir, window: 1),
            backfillBudget: budget
        )
        await engineA.start()
        await engineB.start()
        try await Task.sleep(for: .seconds(2))
        let snapshot = await budget.snapshot()
        #expect(snapshot.active <= 4)
        await engineA.stop()
        await engineB.stop()
    }
}

@Test func scriptedPeekResponsesHonorWindowByteLimits() async throws {
    try await withSyncStore { store, dir in
        let body = String(repeating: "x", count: SyncPolicy.backfillTextPeekByteLimit * 10)
        var mailbox = populatedInbox(uidValidity: 1, count: 1, prefix: "large")
        mailbox.messages[1] = makePlainMessage(uid: 1, subject: "large", body: body)
        let world = ScriptedWorld(capabilities: basicCaps(), folders: [inboxMailbox()], mailboxes: ["INBOX": mailbox])
        let (engine, _) = makeEngine(store: store, world: world, dir: dir, window: 1)
        await engine.start()
        try await Task.sleep(for: .milliseconds(700))
        let requests = world.peekRequestSnapshot().flatMap { $0 }
        #expect(requests.contains { $0.length == SyncPolicy.backfillTextPeekByteLimit })
        #expect(requests.filter { $0.specifier.uppercased() == "HEADER" }.allSatisfy { ($0.length ?? 0) <= SyncPolicy.backfillHeaderPeekByteLimit })
        #expect(requests.filter { $0.specifier.uppercased() != "HEADER" }.allSatisfy { ($0.length ?? 0) <= SyncPolicy.backfillTextPeekByteLimit })
        let peekRanges = world.peekRequestUIDRangeSnapshot()
        let responseLimits = world.peekRequestResponseLimitSnapshot()
        #expect(responseLimits.count == world.peekRequestSnapshot().count)
        #expect(responseLimits.allSatisfy {
            guard let limit = $0 else { return false }
            return limit > 0 && limit <= SyncPolicy.backfillWindowPeekByteBudget
        })
        for (sections, ranges) in zip(world.peekRequestSnapshot(), peekRanges) {
            let perUID = sections.reduce(UInt64(0)) { $0 + UInt64(max(0, $1.length ?? 0)) }
            let uidCount = ranges.reduce(UInt64(0)) {
                $0 + UInt64($1.upperBound) - UInt64($1.lowerBound) + 1
            }
            #expect(perUID * uidCount <= UInt64(SyncPolicy.backfillWindowPeekByteBudget))
        }
        await engine.stop()
    }
}

@Test func interleavedMIMEShapesShareCompatiblePeekFetches() async throws {
    try await withSyncStore { store, dir in
        var mailbox = populatedInbox(uidValidity: 1, count: 4, prefix: "layout")
        for uid in UInt32(1)...UInt32(4) where uid.isMultiple(of: 2) {
            var message = makePlainMessage(uid: uid, subject: "multipart-\(uid)")
            let plain = IMAPBodyStructure(
                partSpecifier: "1",
                type: "text",
                subtype: "plain",
                encoding: "7bit",
                octetCount: uid == 2 ? 5 : 8,
                charset: "utf-8",
                filename: nil,
                contentID: nil,
                children: []
            )
            let html = IMAPBodyStructure(
                partSpecifier: "2",
                type: "text",
                subtype: "html",
                encoding: "7bit",
                octetCount: uid == 2 ? 12 : 15,
                charset: "utf-8",
                filename: nil,
                contentID: nil,
                children: []
            )
            message.structure = IMAPBodyStructure(
                partSpecifier: "",
                type: "multipart",
                subtype: "alternative",
                encoding: nil,
                octetCount: nil,
                charset: nil,
                filename: nil,
                contentID: nil,
                children: [plain, html]
            )
            message.parts = [
                "1": Data("plain".utf8),
                "2": Data("<p>html</p>".utf8),
            ]
            mailbox.messages[uid] = message
        }
        let world = ScriptedWorld(
            capabilities: basicCaps(),
            folders: [inboxMailbox()],
            mailboxes: ["INBOX": mailbox]
        )
        let (engine, _) = makeEngine(store: store, world: world, dir: dir, window: 4)
        await engine.start()
        try await waitUntil(timeout: .seconds(8)) {
            try await store.fetchFolders(account: sampleConfig().id)
                .contains { $0.role == .inbox && $0.backfill == .complete }
        }
        #expect(world.peekRequestSnapshot().count == 2)
        let folder = try #require(await inboxFolder(store))
        let page = try await store.page(in: folder.id, after: nil, limit: 10, sort: .newest)
        #expect(page.rows.map(\.subject) == [
            "multipart-4", "layout-3", "multipart-2", "layout-1",
        ])
        for row in page.rows where row.subject.hasPrefix("multipart-") {
            let detail = try await store.detail(row.id)
            #expect(detail.bodyText != nil)
        }
        await engine.stop()
    }
}
