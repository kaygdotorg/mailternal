import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

private func renameWorld() -> ScriptedWorld {
    let path = "Projects/Old"
    return ScriptedWorld(
        capabilities: basicCaps(),
        folders: [
            inboxMailbox(),
            IMAPMailbox(
                path: path,
                name: "Old",
                separator: "/",
                role: .none,
                mailboxID: "rename-object",
                attributes: []
            ),
        ],
        mailboxes: [
            "INBOX": ScriptedMailbox(path: "INBOX"),
            path: ScriptedMailbox(path: path),
        ]
    )
}

private func prepareRenameEngine(
    store: MailStore,
    world: ScriptedWorld,
    dir: URL
) async throws -> (SyncEngine, FolderID) {
    let engine = SyncEngine(
        store: store,
        config: sampleConfig(),
        credentials: StaticPassword(value: "pw"),
        clientFactory: ScriptedFactory(world: world),
        disk: ampleDisk(),
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        settings: testSettings(dir: dir, periodicTick: .seconds(3600))
    )
    await engine.start()
    try await waitUntil(timeout: .seconds(5)) {
        let folders = try await store.fetchFolders(account: sampleConfig().id)
        return folders.contains { $0.path == "Projects/Old" }
    }
    let folder = try #require(
        try await store.fetchFolders(account: sampleConfig().id).first { $0.path == "Projects/Old" }
    )
    return (engine, folder.id)
}

@Test func engineDrainsFolderRenameOnTaggedOKAndRefreshesDiscovery() async throws {
    try await withSyncStore { store, dir in
        let world = renameWorld()
        let (engine, folder) = try await prepareRenameEngine(store: store, world: world, dir: dir)

        try await store.enqueueFolderRename(folder: folder, to: "New")
        await engine.refreshNow()

        try await waitUntil(timeout: .seconds(5)) {
            let pending = try await store.snapshotFolderRenameQueue()
            let summary = try await store.fetchFolderSummary(folder)
            return pending.isEmpty && summary?.path == "Projects/New"
        }
        #expect(world.renameCommandSnapshot() == ["RENAME Projects/Old Projects/New"])
        #expect(try await store.fetchFolderSummary(folder)?.name == "New")
        await engine.stop()
    }
}

@Test func engineRetainsFolderRenameAcrossTransportFailureThenRetries() async throws {
    try await withSyncStore { store, dir in
        let world = renameWorld()
        let (engine, folder) = try await prepareRenameEngine(store: store, world: world, dir: dir)
        try await store.enqueueFolderRename(folder: folder, to: "Retry")
        world.renameError = IMAPError.transport("connection lost")
        await engine.refreshNow()
        #expect(try await store.snapshotFolderRenameQueue().count == 1)

        world.renameError = nil
        await engine.refreshNow()
        try await waitUntil(timeout: .seconds(5)) {
            try await store.snapshotFolderRenameQueue().isEmpty
        }
        #expect(world.renameCommandSnapshot().count == 1)
        await engine.stop()
    }
}

@Test func engineDropsTaggedTerminalFolderRenameAndRecordsError() async throws {
    try await withSyncStore { store, dir in
        let world = renameWorld()
        let (engine, folder) = try await prepareRenameEngine(store: store, world: world, dir: dir)
        world.renameError = IMAPError.taggedNO(tag: "t", message: "name exists", code: nil)
        try await store.enqueueFolderRename(folder: folder, to: "Taken")
        await engine.refreshNow()

        try await waitUntil(timeout: .seconds(5)) {
            try await store.snapshotFolderRenameQueue().isEmpty
        }
        let errors = try await store.fetchErrorLog()
        #expect(errors.contains {
            $0.message == "Couldn’t rename folder" && $0.detail?.contains("name exists") == true
        })
        #expect(try await store.fetchFolderSummary(folder)?.path == "Projects/Old")
        await engine.stop()
    }
}
