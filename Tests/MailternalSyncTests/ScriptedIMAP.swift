import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
@testable import MailternalSync

final class ScriptedWorld: @unchecked Sendable {
    let lock = NSLock()
    var capabilities: IMAPCapabilities
    var folders: [IMAPMailbox]
    var mailboxes: [String: ScriptedMailbox]
    var failQResync = false
    var failSelect: Error?
    var storeSeenError: Error?
    var storeFlagsError: Error?
    var isGmail = false
    var moveError: Error?
    var copyError: Error?
    var storeDeletedError: Error?
    var expungeError: Error?
    var storedSeen: [UInt32] = []
    var flagCommands: [String] = []
    var archiveCommands: [String] = []
    var fetchNanos: UInt64 = 0
    /// Sleep `fetchNanos` only on fetches after this count. `nil` sleeps every fetch.
    var stallFetchesAfter: Int?
    var connectError: Error?
    var connectAttempts = 0
    var fetchError: Error?
    var fetchErrorAfter: Int?
    var fetchCount = 0
    private var completedFetchCount = 0
    private var fetchCompletionWaiters: [
        (after: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    var selectCount = 0
    /// UID ranges requested by envelope/bodystructure metadata fetches.
    /// Follow-up body peeks and bounded flag sweeps are intentionally omitted.
    var metadataFetchRanges: [[ClosedRange<UInt32>]] = []
    var flagFetchRanges: [[ClosedRange<UInt32>]] = []
    /// Pauses the first metadata FETCH after capturing its mailbox snapshot.
    /// Tests use this to interleave a deterministic expunge revision.
    var pauseMetadataFetch = false
    private var metadataFetchReleased = false
    private var metadataFetchEntered = false
    private var metadataFetchWaiters: [CheckedContinuation<Void, Never>] = []
    /// Pauses the quarantine FLAGS fallback after capturing its server response.
    /// This lets tests deterministically interleave an EXPUNGE delta.
    var pauseFlagFallback = false
    private var flagFallbackReleased = false
    private var flagFallbackEntered = false
    private var flagFallbackReturned = false
    private var flagFallbackWaiters: [CheckedContinuation<Void, Never>] = []
    /// Pauses the fallback STORE phase so stop() can be tested while the
    /// archive write gate is held.
    var pauseArchiveStore = false
    private var archiveStoreReleased = false
    private var archiveStoreEntered = false
    private var archiveStoreWaiters: [CheckedContinuation<Void, Never>] = []
    init(
        capabilities: IMAPCapabilities,
        folders: [IMAPMailbox],
        mailboxes: [String: ScriptedMailbox]
    ) {
        self.capabilities = capabilities
        self.folders = folders
        self.mailboxes = mailboxes
    }

    func snapshotCapabilities() -> IMAPCapabilities {
        lock.lock()
        defer { lock.unlock() }
        return capabilities
    }

    func discovery() -> (folders: [IMAPMailbox], isGmail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (folders, isGmail)
    }

    func qresyncShouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failQResync
    }

    func selectFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failSelect
    }

    func seenError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storeSeenError
    }
    func flagsError() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return storeFlagsError ?? storeSeenError
    }


    func mailbox(_ path: String) -> ScriptedMailbox {
        lock.lock()
        defer { lock.unlock() }
        if let existing = mailboxes[path] { return existing }
        let created = ScriptedMailbox(path: path)
        mailboxes[path] = created
        return created
    }

    func seenUIDs() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return storedSeen
    }
    func flagCommandSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return flagCommands
    }


    func archiveCommandSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return archiveCommands
    }

    func mutationError(_ command: String) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        switch command {
        case "MOVE": return moveError
        case "COPY": return copyError
        case "STORE": return storeDeletedError
        case "EXPUNGE": return expungeError
        default: return nil
        }
    }

    func applyArchiveMove(path: String, destination: String, uids: IMAPUIDSet) {
        lock.lock()
        defer { lock.unlock() }
        guard var source = mailboxes[path] else { return }
        var target = mailboxes[destination] ?? ScriptedMailbox(path: destination)
        let selected = source.messages.keys.filter { SyncPolicy.contains(uids, uid: $0) }
        for uid in selected {
            guard let message = source.messages.removeValue(forKey: uid) else { continue }
            target.messages[uid] = message
        }
        if !selected.isEmpty {
            archiveCommands.append("MOVE \(path) \(destination) \(uidSetDescription(selected))")
        }
        target.uidNext = max(target.uidNext, target.messages.keys.max().map { $0 &+ 1 } ?? target.uidNext)
        mailboxes[path] = source
        mailboxes[destination] = target
    }

    func applyArchiveCopy(path: String, destination: String, uids: IMAPUIDSet) {
        lock.lock()
        defer { lock.unlock() }
        guard let source = mailboxes[path] else { return }
        var target = mailboxes[destination] ?? ScriptedMailbox(path: destination)
        let selected = source.messages.keys.filter { SyncPolicy.contains(uids, uid: $0) }
        for uid in selected {
            guard let message = source.messages[uid] else { continue }
            target.messages[uid] = message
        }
        if !selected.isEmpty {
            archiveCommands.append("COPY \(path) \(destination) \(uidSetDescription(selected))")
        }
        target.uidNext = max(target.uidNext, target.messages.keys.max().map { $0 &+ 1 } ?? target.uidNext)
        mailboxes[destination] = target
    }

    func applyStoreDeleted(path: String, uids: IMAPUIDSet) {
        lock.lock()
        defer { lock.unlock() }
        guard var source = mailboxes[path] else { return }
        let selected = source.messages.keys.filter { SyncPolicy.contains(uids, uid: $0) }
        for uid in selected {
            guard var message = source.messages[uid] else { continue }
            if !message.flags.contains(where: { $0.lowercased().contains("deleted") }) {
                message.flags.append("\\Deleted")
            }
            source.messages[uid] = message
        }
        if !selected.isEmpty {
            archiveCommands.append("STORE \(path) \(uidSetDescription(selected))")
        }
        mailboxes[path] = source
    }

    func applyExpunge(path: String, uids: IMAPUIDSet) {
        lock.lock()
        defer { lock.unlock() }
        guard var source = mailboxes[path] else { return }
        let selected = source.messages.keys.filter { SyncPolicy.contains(uids, uid: $0) }
        var expunged: [UInt32] = []
        for uid in selected {
            guard let message = source.messages[uid],
                  message.flags.contains(where: { $0.lowercased().contains("deleted") })
            else { continue }
            source.messages.removeValue(forKey: uid)
            expunged.append(uid)
        }
        if !expunged.isEmpty {
            archiveCommands.append("EXPUNGE \(path) \(uidSetDescription(expunged))")
        }
        mailboxes[path] = source
    }

    private func uidSetDescription<S: Sequence>(_ uids: S) -> String where S.Element == UInt32 {
        let sorted = uids.sorted()
        var ranges: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 {
                end += 1
            }
            if index == end {
                ranges.append(String(sorted[index]))
            } else {
                ranges.append("\(sorted[index]):\(sorted[end])")
            }
            index = end + 1
        }
        return ranges.joined(separator: ",")
    }

    func updateMailbox(_ path: String, _ body: (inout ScriptedMailbox) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var box = mailboxes[path] ?? ScriptedMailbox(path: path)
        body(&box)
        mailboxes[path] = box
    }

    func replaceFolders(_ folders: [IMAPMailbox]) {
        lock.lock()
        self.folders = folders
        lock.unlock()
    }

    func applyStoreFlags(path: String, flag: FlagKind, set: Bool, uids: IMAPUIDSet) {
        lock.lock()
        defer { lock.unlock() }
        guard var box = mailboxes[path] else { return }
        let rawFlag = flag == .seen ? "\\Seen" : "\\Flagged"
        let operation = set ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        for (uid, var message) in box.messages {
            if SyncPolicy.contains(uids, uid: uid) {
                if set {
                    if !message.flags.contains(where: { $0.lowercased() == rawFlag.lowercased() }) {
                        message.flags.append(rawFlag)
                    }
                } else {
                    message.flags.removeAll { $0.lowercased() == rawFlag.lowercased() }
                }
                box.messages[uid] = message
                flagCommands.append("STORE \(path) \(uid) \(operation) (\(rawFlag))")
                if flag == .seen && set {
                    storedSeen.append(uid)
                }
            }
        }
        mailboxes[path] = box
    }

    func applyStoreSeen(path: String, uids: IMAPUIDSet) {
        applyStoreFlags(path: path, flag: .seen, set: true, uids: uids)
    }

    func fetchSleepNanos() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let limit = stallFetchesAfter, fetchCount <= limit {
            return 0
        }
        return fetchNanos
    }

    func noteFetch(_ request: IMAPFetchRequest) {
        lock.lock()
        defer { lock.unlock() }
        if request.envelope || request.bodyStructure {
            metadataFetchRanges.append(request.uids.ranges)
        }
        if request.flags && !request.envelope && !request.bodyStructure && request.peek.isEmpty {
            flagFetchRanges.append(request.uids.ranges)
        }
    }
    func metadataFetchSnapshotIfPaused(
        path: String
    ) -> (snapshot: ScriptedMailbox, alreadyReleased: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard pauseMetadataFetch else { return nil }
        let snapshot = mailboxes[path] ?? ScriptedMailbox(path: path)
        metadataFetchEntered = true
        return (snapshot, metadataFetchReleased)
    }

    func waitMetadataFetchPause() async throws {
        try await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if registerMetadataFetchWaiter(continuation) {
                    continuation.resume()
                }
            }
        }, onCancel: {
            releaseMetadataFetch()
        })
        try Task.checkCancellation()
    }

    private func registerMetadataFetchWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if metadataFetchReleased || Task.isCancelled {
            return true
        }
        metadataFetchWaiters.append(continuation)
        return false
    }

    func metadataFetchDidEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadataFetchEntered
    }

    func releaseMetadataFetch() {
        lock.lock()
        metadataFetchReleased = true
        pauseMetadataFetch = false
        let waiters = metadataFetchWaiters
        metadataFetchWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }


    func flagFallbackSnapshotIfPaused(
        _ request: IMAPFetchRequest,
        path: String
    ) async throws -> ScriptedMailbox? {
        guard request.flags,
              !request.envelope,
              !request.bodyStructure,
              request.peek.isEmpty
        else {
            return nil
        }
        guard let captured = captureFlagFallback(path: path) else {
            return nil
        }
        if captured.alreadyReleased {
            noteFlagFallbackReturned()
            return captured.snapshot
        }
        try await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if registerFlagFallbackWaiter(continuation) {
                    continuation.resume()
                }
            }
        }, onCancel: {
            cancelFlagFallbackWaiters()
        })
        try Task.checkCancellation()
        noteFlagFallbackReturned()
        return captured.snapshot
    }

    private func captureFlagFallback(
        path: String
    ) -> (snapshot: ScriptedMailbox, alreadyReleased: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard pauseFlagFallback else { return nil }
        let snapshot = mailboxes[path] ?? ScriptedMailbox(path: path)
        flagFallbackEntered = true
        return (snapshot, flagFallbackReleased)
    }

    private func registerFlagFallbackWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flagFallbackReleased || Task.isCancelled {
            return true
        }
        flagFallbackWaiters.append(continuation)
        return false
    }

    private func cancelFlagFallbackWaiters() {
        lock.lock()
        flagFallbackReleased = true
        let waiters = flagFallbackWaiters
        flagFallbackWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func noteFlagFallbackReturned() {
        lock.lock()
        flagFallbackReturned = true
        lock.unlock()
    }

    func flagFallbackDidEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagFallbackEntered
    }

    func flagFallbackDidReturn() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagFallbackReturned
    }

    func releaseFlagFallback() {
        lock.lock()
        flagFallbackReleased = true
        let waiters = flagFallbackWaiters
        flagFallbackWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
    func archiveStorePauseIfNeeded() async throws {
        let alreadyReleased = captureArchiveStorePause()
        guard alreadyReleased != nil else { return }
        if alreadyReleased == true { return }
        try await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if registerArchiveStoreWaiter(continuation) {
                    continuation.resume()
                }
            }
        }, onCancel: {
            releaseArchiveStore()
        })
        try Task.checkCancellation()
    }

    private func captureArchiveStorePause() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard pauseArchiveStore else { return nil }
        archiveStoreEntered = true
        return archiveStoreReleased
    }

    private func registerArchiveStoreWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if archiveStoreReleased || Task.isCancelled {
            return true
        }
        archiveStoreWaiters.append(continuation)
        return false
    }

    func archiveStoreDidEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return archiveStoreEntered
    }

    func releaseArchiveStore() {
        lock.lock()
        archiveStoreReleased = true
        let waiters = archiveStoreWaiters
        archiveStoreWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }



    func snapshotMetadataFetchRanges() -> [[ClosedRange<UInt32>]] {
        lock.lock()
        defer { lock.unlock() }
        return metadataFetchRanges
    }

    func snapshotFlagFetchRanges() -> [[ClosedRange<UInt32>]] {
        lock.lock()
        defer { lock.unlock() }
        return flagFetchRanges
    }

    func resetFlagFetchRanges() {
        lock.lock()
        flagFetchRanges = []
        lock.unlock()
    }

    func snapshotFetchCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fetchCount
    }

    func connectFailure() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        connectAttempts += 1
        return connectError
    }

    func snapshotConnectAttempts() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return connectAttempts
    }

    func setConnectError(_ error: Error?) {
        lock.lock()
        connectError = error
        lock.unlock()
    }

    func beginFetch() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        fetchCount += 1
        if let after = fetchErrorAfter {
            guard fetchCount >= after, let error = fetchError else { return nil }
            fetchErrorAfter = nil
            fetchError = nil
            return error
        }
        return fetchError
    }
    func noteFetchCompleted() {
        lock.lock()
        completedFetchCount += 1
        let waiters = fetchCompletionWaiters.filter { $0.after < completedFetchCount }
        fetchCompletionWaiters.removeAll { $0.after < completedFetchCount }
        lock.unlock()
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    func snapshotCompletedFetchCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return completedFetchCount
    }

    func waitForFetchCompletion(after count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completedFetchCount > count {
                lock.unlock()
                continuation.resume()
            } else {
                fetchCompletionWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }


    func noteSelect() {
        lock.lock()
        selectCount += 1
        lock.unlock()
    }

}

enum ScriptedFetchError: Error {
    case metadata
}

struct ScriptedMessage: Sendable {
    var uid: UInt32
    var flags: [String]

    var internalDate: Date
    var envelope: IMAPEnvelope
    var structure: IMAPBodyStructure
    var header: Data
    var parts: [String: Data]
    var modSeq: UInt64
}

struct ScriptedMailbox: Sendable {
    var path: String
    var uidValidity: UInt32 = 1
    var uidNext: UInt32 = 1
    var highestModSeq: UInt64? = 10
    var noModSeq = false
    var vanishedEarlier: [UInt32] = []
    var vanished: [UInt32] = []
    var messages: [UInt32: ScriptedMessage] = [:]

    var exists: Int { messages.count }
}

actor ScriptedIMAPClient: IMAPClient {
    let world: ScriptedWorld
    let connectError: Error?
    private var connected = false
    private var selectedPath: String?
    private let eventStream: AsyncStream<IMAPMailboxEvent>
    private let eventContinuation: AsyncStream<IMAPMailboxEvent>.Continuation
    private var idleContinuation: AsyncStream<IMAPMailboxEvent>.Continuation?

    init(world: ScriptedWorld, connectError: Error? = nil) {
        self.world = world
        self.connectError = connectError
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    nonisolated var events: AsyncStream<IMAPMailboxEvent> { eventStream }

    func emit(_ event: IMAPMailboxEvent) {
        eventContinuation.yield(event)
        idleContinuation?.yield(event)
    }

    func capabilities() async -> IMAPCapabilities { world.snapshotCapabilities() }
    func connect() async throws {
        if let connectError { throw connectError }
        if let error = world.connectFailure() { throw error }
        connected = true
        closed = false
    }
    func selectedMailbox() async -> IMAPSelectedMailbox? {
        guard let selectedPath else { return nil }
        return makeSelected(world.mailbox(selectedPath), name: selectedPath)
    }

    private var closed = false

    func wasClosed() -> Bool { closed }

    func close() async {
        // Closing a client must not strand a fetch or archive phase paused by
        // the test gates.
        world.releaseMetadataFetch()
        world.releaseFlagFallback()
        world.releaseArchiveStore()
        connected = false
        closed = true
        idleContinuation?.finish()
        idleContinuation = nil
        eventContinuation.finish()
    }
    func listFolders() async throws -> IMAPFolderDiscovery {
        let discovery = world.discovery()
        return IMAPFolderDiscovery(folders: discovery.folders, isGmail: discovery.isGmail)
    }

    func select(_ mailbox: String, qresync: IMAPQResyncSelect?) async throws -> IMAPSelectedMailbox {
        world.noteSelect()
        if let fail = world.selectFailure() { throw fail }
        if qresync != nil, world.qresyncShouldFail() {
            throw IMAPError.taggedBAD(tag: "t", message: "QRESYNC failed", code: nil)
        }
        selectedPath = mailbox
        let box = world.mailbox(mailbox)
        return makeSelected(box, name: mailbox)
    }

    func enableQResync() async throws {
        if world.qresyncShouldFail() {
            throw IMAPError.taggedBAD(tag: "t", message: "ENABLE QRESYNC failed", code: nil)
        }
    }

    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        if let error = world.beginFetch() { throw error }
        world.noteFetch(request)
        let pausedMetadataSnapshot: (snapshot: ScriptedMailbox, alreadyReleased: Bool)?
        if (request.envelope || request.bodyStructure), let selectedPath {
            pausedMetadataSnapshot = world.metadataFetchSnapshotIfPaused(path: selectedPath)
            if let pausedMetadataSnapshot, !pausedMetadataSnapshot.alreadyReleased {
                try await world.waitMetadataFetchPause()
            }
        } else {
            pausedMetadataSnapshot = nil
        }
        let pausedFlagSnapshot: ScriptedMailbox?
        if let selectedPath {
            pausedFlagSnapshot = try await world.flagFallbackSnapshotIfPaused(request, path: selectedPath)
        } else {
            pausedFlagSnapshot = nil
        }
        let delay = world.fetchSleepNanos()
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        guard let selectedPath else {
            world.noteFetchCompleted()
            return []
        }
        let box = pausedFlagSnapshot ?? pausedMetadataSnapshot?.snapshot ?? world.mailbox(selectedPath)
        var results: [IMAPFetchedMessage] = []
        for (uid, message) in box.messages.sorted(by: { $0.key < $1.key }) {
            if !SyncPolicy.contains(request.uids, uid: uid) { continue }
            if let changed = request.changedSince, message.modSeq <= changed { continue }
            var parts: [IMAPPeekedPart] = []
            for peek in request.peek {
                let spec = peek.specifier
                if spec.uppercased() == "HEADER" {
                    parts.append(IMAPPeekedPart(specifier: "HEADER", binary: false, data: message.header))
                } else if spec.isEmpty {
                    let body = message.parts["1"] ?? Data()
                    var full = message.header
                    if full.suffix(4) != Data("\r\n\r\n".utf8) {
                        full.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
                    }
                    full.append(body)
                    let capped: Data
                    if let origin = peek.origin, let length = peek.length {
                        let start = min(origin, full.count)
                        capped = Data(full.dropFirst(start).prefix(length))
                    } else {
                        capped = full
                    }
                    parts.append(IMAPPeekedPart(specifier: "", binary: false, data: capped))
                } else if let data = message.parts[spec] ?? (spec == "1" ? message.parts["TEXT"] : nil) {
                    parts.append(IMAPPeekedPart(specifier: spec, binary: false, data: data))
                }
            }
            results.append(IMAPFetchedMessage(
                uid: uid,
                sequence: uid,
                flags: message.flags,
                internalDate: message.internalDate,
                envelope: request.envelope ? message.envelope : nil,
                bodyStructure: request.bodyStructure ? message.structure : nil,
                rfc822Size: nil,
                modSeq: request.modSeq ? message.modSeq : nil,
                parts: parts
            ))
        }
        world.noteFetchCompleted()
        return results
    }

    func storeFlags(uids: IMAPUIDSet, flag: FlagKind, set: Bool) async throws {
        if let error = world.flagsError() { throw error }
        guard let selectedPath else { return }
        world.applyStoreFlags(path: selectedPath, flag: flag, set: set, uids: uids)
    }

    func storeSeen(uids: IMAPUIDSet) async throws {
        try await storeFlags(uids: uids, flag: .seen, set: true)
    }
 
    func move(uids: IMAPUIDSet, to mailbox: String) async throws {
        if let error = world.mutationError("MOVE") { throw error }
        guard let selectedPath else { return }
        world.applyArchiveMove(path: selectedPath, destination: mailbox, uids: uids)
    }

    func copy(uids: IMAPUIDSet, to mailbox: String) async throws {
        if let error = world.mutationError("COPY") { throw error }
        guard let selectedPath else { return }
        world.applyArchiveCopy(path: selectedPath, destination: mailbox, uids: uids)
    }

    func storeDeleted(uids: IMAPUIDSet) async throws {
        try await world.archiveStorePauseIfNeeded()
        if let error = world.mutationError("STORE") { throw error }
        guard let selectedPath else { return }
        world.applyStoreDeleted(path: selectedPath, uids: uids)
    }

    func expunge(uids: IMAPUIDSet) async throws {
        if let error = world.mutationError("EXPUNGE") { throw error }
        guard let selectedPath else { return }
        world.applyExpunge(path: selectedPath, uids: uids)
    }

    func beginIdle() async throws -> IMAPIdle {
        var continuation: AsyncStream<IMAPMailboxEvent>.Continuation!
        let stream = AsyncStream<IMAPMailboxEvent> { continuation = $0 }
        idleContinuation = continuation
        return IMAPIdle(events: stream)
    }

    func endIdle() async throws {
        idleContinuation?.finish()
        idleContinuation = nil
    }

    func renewIdle() async throws -> IMAPIdle {
        try await endIdle()
        return try await beginIdle()
    }

    private func makeSelected(_ box: ScriptedMailbox, name: String) -> IMAPSelectedMailbox {
        IMAPSelectedMailbox(
            name: name,
            exists: box.exists,
            uidValidity: box.uidValidity,
            uidNext: box.uidNext,
            highestModSeq: box.highestModSeq,
            noModSeq: box.noModSeq,
            mailboxID: nil,
            flags: ["\\Seen", "\\Flagged"],
            vanishedEarlier: box.vanishedEarlier,
            vanished: box.vanished,
            isReadWrite: true
        )
    }
}

final class ScriptedFactory: IMAPClientFactory, @unchecked Sendable {
    let world: ScriptedWorld
    let secondConnectError: Error?
    private let lock = NSLock()
    private var count = 0
    private(set) var clients: [ScriptedIMAPClient] = []

    init(world: ScriptedWorld, secondConnectError: Error? = nil) {
        self.world = world
        self.secondConnectError = secondConnectError
    }

    func makeClient(endpoint: IMAPEndpoint, username: String, password: String) -> any IMAPClient {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        let error = count >= 2 ? secondConnectError : nil
        let client = ScriptedIMAPClient(world: world, connectError: error)
        clients.append(client)
        return client
    }

    private func snapshotClients() -> [ScriptedIMAPClient] {
        lock.lock()
        defer { lock.unlock() }
        return clients
    }

    func emitAll(_ event: IMAPMailboxEvent) async {
        for client in snapshotClients() {
            await client.emit(event)
        }
    }

    func closedClientCount() async -> Int {
        var closed = 0
        for client in snapshotClients() {
            if await client.wasClosed() { closed += 1 }
        }
        return closed
    }
}

struct StaticPassword: IMAPCredentialProvider {
    var value: String
    func password(for account: AccountID) async throws -> String { value }
}

struct FixedDisk: DiskSpaceProviding {
    var freeBytes: Int64
    var volumeBytes: Int64
    func snapshot(for url: URL) -> DiskSnapshot {
        DiskSnapshot(freeBytes: freeBytes, volumeBytes: volumeBytes)
    }
}

final class MutableDisk: DiskSpaceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int64
    private var volume: Int64

    init(freeBytes: Int64, volumeBytes: Int64) {
        self.free = freeBytes
        self.volume = volumeBytes
    }

    func snapshot(for url: URL) -> DiskSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiskSnapshot(freeBytes: free, volumeBytes: volume)
    }

    func setFree(_ freeBytes: Int64) {
        lock.lock()
        free = freeBytes
        lock.unlock()
    }
}

func makePlainMessage(
    uid: UInt32,
    subject: String,
    from: String = "alice@example.com",
    body: String = "hello",
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    flags: [String] = [],
    modSeq: UInt64 = 5
) -> ScriptedMessage {
    let envelope = IMAPEnvelope(
        date: nil,
        subject: subject,
        from: [IMAPAddress(displayName: "Alice", mailbox: "alice", host: "example.com")],
        sender: [],
        replyTo: [],
        to: [IMAPAddress(displayName: nil, mailbox: "qa", host: "mailternal.test")],
        cc: [],
        bcc: [],
        inReplyTo: nil,
        messageID: "<\(uid)@example.com>"
    )
    let structure = IMAPBodyStructure(
        partSpecifier: "",
        type: "text",
        subtype: "plain",
        encoding: "7bit",
        octetCount: body.utf8.count,
        charset: "utf-8",
        filename: nil,
        contentID: nil,
        children: []
    )
    let header = Data("From: Alice <alice@example.com>\r\nSubject: \(subject)\r\nMessage-ID: <\(uid)@example.com>\r\n\r\n".utf8)
    return ScriptedMessage(
        uid: uid,
        flags: flags,
        internalDate: date,
        envelope: envelope,
        structure: structure,
        header: header,
        parts: ["1": Data(body.utf8)],
        modSeq: modSeq
    )
}

func qresyncCaps() -> IMAPCapabilities {
    IMAPCapabilities(tokens: [
        "IMAP4REV1", "IDLE", "QRESYNC", "CONDSTORE", "ENABLE", "STARTTLS", "AUTH=PLAIN",
    ])
}

func basicCaps() -> IMAPCapabilities {
    IMAPCapabilities(tokens: ["IMAP4REV1", "IDLE"])
}

func condstoreCaps() -> IMAPCapabilities {
    IMAPCapabilities(tokens: [
        "IMAP4REV1", "IDLE", "CONDSTORE", "ENABLE", "STARTTLS", "AUTH=PLAIN",
    ])
}
enum EqualExistsRacePath: String, CaseIterable, Sendable {
    case basic
    case condstore
    case qresync

    var capabilities: IMAPCapabilities {
        switch self {
        case .basic:
            basicCaps()
        case .condstore:
            condstoreCaps()
        case .qresync:
            qresyncCaps()
        }
    }
}


func inboxMailbox() -> IMAPMailbox {
    IMAPMailbox(path: "INBOX", name: "INBOX", separator: "/", role: .inbox, mailboxID: nil, attributes: [])
}

func trashMailbox() -> IMAPMailbox {
    IMAPMailbox(path: "Trash", name: "Trash", separator: "/", role: .trash, mailboxID: nil, attributes: [])
}

func testSettings(
    dir: URL,
    window: UInt32 = 2,
    seenPoll: Duration = .milliseconds(20),
    periodicTick: Duration = .seconds(15),
    cleanupTick: Duration = .seconds(30),
    allowEnableQResync: Bool = true,
    flagSweep: UInt32 = 5000
) -> SyncSettings {
    SyncSettings(
        backfillWindowSize: window,
        idleRenewal: .seconds(3600),
        hintDebounce: .milliseconds(1),
        specialUseDelta: .seconds(3600),
        otherFolderDelta: .seconds(3600),
        seenPoll: seenPoll,
        diskURL: dir,
        periodicTick: periodicTick,
        cleanupTick: cleanupTick,
        reconnect: IMAPReconnectBackoff(base: 0.05, cap: 0.4, jitterFraction: 0.1),
        allowEnableQResync: allowEnableQResync,
        flagSweepWindowSize: flagSweep
    )
}

func chaosSettings(dir: URL, window: UInt32 = 2, allowEnableQResync: Bool = true) -> SyncSettings {
    testSettings(
        dir: dir,
        window: window,
        seenPoll: .milliseconds(15),
        periodicTick: .milliseconds(80),
        cleanupTick: .milliseconds(80),
        allowEnableQResync: allowEnableQResync
    )
}

func populatedInbox(
    uidValidity: UInt32,
    count: UInt32,
    uidNext: UInt32? = nil,
    prefix: String = "m",
    highestModSeq: UInt64 = 20
) -> ScriptedMailbox {
    var box = ScriptedMailbox(
        path: "INBOX",
        uidValidity: uidValidity,
        uidNext: uidNext ?? (count + 1),
        highestModSeq: highestModSeq
    )
    if count >= 1 {
        for uid in 1...count {
            box.messages[uid] = makePlainMessage(
                uid: uid,
                subject: "\(prefix)-\(uid)",
                body: "\(prefix) body \(uid)"
            )
        }
    }
    return box
}

func ampleDisk() -> FixedDisk {
    FixedDisk(freeBytes: 50 * 1024 * 1024 * 1024, volumeBytes: 100 * 1024 * 1024 * 1024)
}

func makeEngine(
    store: MailStore,
    world: ScriptedWorld,
    dir: URL,
    disk: any DiskSpaceProviding = ampleDisk(),
    window: UInt32 = 2,
    allowEnableQResync: Bool = true
) -> (SyncEngine, ScriptedFactory) {
    let factory = ScriptedFactory(world: world)
    let engine = SyncEngine(
        store: store,
        config: sampleConfig(),
        credentials: StaticPassword(value: "pw"),
        clientFactory: factory,
        disk: disk,
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        settings: chaosSettings(dir: dir, window: window, allowEnableQResync: allowEnableQResync)
    )
    return (engine, factory)
}

func drainRetired(_ store: MailStore) async throws {
    var deleted = 1
    while deleted > 0 {
        deleted = try await store.cleanupRetiredGenerations(batchSize: 500)
    }
}

func assertStoreInvariants(
    _ store: MailStore,
    drain: Bool = false,
    expectEmptySeen: Bool = false,
    expectNoReplacement: Bool = false
) async throws {
    if drain { try await drainRetired(store) }
    let report = try await store.checkInvariants()
    if !report.isClean {
        throw InvariantFailure(issues: report.issues)
    }
    if expectEmptySeen, report.seenQueueCount != 0 {
        throw InvariantFailure(issues: ["seen queue leftover: \(report.seenQueueCount)"])
    }
    if expectNoReplacement, report.replacementGenerations != 0 {
        throw InvariantFailure(issues: ["replacement leftover: \(report.replacementGenerations)"])
    }
}

struct InvariantFailure: Error, CustomStringConvertible {
    var issues: [String]
    var description: String { issues.joined(separator: "; ") }
}

func inboxFolder(_ store: MailStore) async throws -> FolderSummary? {
    try await store.fetchFolders(account: sampleConfig().id).first(where: { $0.role == .inbox })
}

func requireInbox(_ store: MailStore) async throws -> FolderSummary {
    guard let inbox = try await inboxFolder(store) else { throw WaitTimeout() }
    return inbox
}

func pageSubjects(_ store: MailStore, folder: FolderID, limit: Int = 200) async throws -> [String] {
    var cursor: MessagePageCursor?
    var subjects: [String] = []
    var seenIDs: Set<Int64> = []
    repeat {
        let page = try await store.page(in: folder, after: cursor, limit: limit)
        for row in page.rows {
            if !seenIDs.insert(row.id.rawValue).inserted {
                throw InvariantFailure(issues: ["duplicate page row \(row.id.rawValue)"])
            }
            subjects.append(row.subject)
        }
        cursor = page.next
        if page.rows.isEmpty { break }
    } while cursor != nil
    return subjects
}

private func runSyncStore(
    _ body: (MailStore, URL) async throws -> Void,
    dir: URL
) async throws {
    let store = try MailStore(
        databaseURL: dir.appendingPathComponent("mail.sqlite"),
        cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
    )
    try await body(store, dir)
}

func withSyncStore(_ body: (MailStore, URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mailternal-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    do {
        try await runSyncStore(body, dir: dir)
    } catch {
        try? FileManager.default.removeItem(at: dir)
        throw error
    }
    try? FileManager.default.removeItem(at: dir)
}

func sampleConfig() -> AccountConfig {
    AccountConfig(
        id: AccountID(rawValue: "qa"),
        accountLinkID: AccountLinkID(
            uuidString: "00000000-0000-4000-8000-000000000022"
        )!,
        displayName: "QA",
        emailAddress: "qa@mailternal.test",
        username: "qa@mailternal.test",
        imap: IMAPEndpoint(host: "127.0.0.1", port: 1143, security: .startTLS)
    )
}

func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(20),
    _ predicate: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: poll)
    }
    throw WaitTimeout()
}

struct WaitTimeout: Error {}
func nextMailEvent(
    from stream: AsyncStream<NewMailEvent>,
    timeout: Duration
) async throws -> NewMailEvent {
    try await withThrowingTaskGroup(of: NewMailEvent.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let event = await iterator.next() else { throw WaitTimeout() }
            return event
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw WaitTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

final class EventCountLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NewMailEvent] = []
    func append(_ event: NewMailEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    func snapshot() -> [NewMailEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
