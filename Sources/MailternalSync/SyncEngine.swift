import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalMIME
import MailternalStore
private enum BackfillAttemptResult: Equatable {
    case committed
    case invalidated
    case halted
}


/// Sync orchestration (spec: docs/spec/sync.md).
///
/// Topology: dedicated INBOX IDLE connection plus a serialized sync/fetch
/// connection; falls back to one multiplexed connection on `NO`/`BYE` when
/// opening the second. `start()` launches background work and returns.
public actor SyncEngine {
    private let store: MailStore
    private let config: AccountConfig
    private let credentials: any IMAPCredentialProvider
    private let clientFactory: any IMAPClientFactory
    private let disk: any DiskSpaceProviding
    private let clock: @Sendable () -> Date
    private let settings: SyncSettings

    private var runTask: Task<Void, Never>?
    private var stopping = false
    private var connected = false
    private var sessionBroken = false
    private var backfillPassFinished = false
    private var dualConnection = false
    private var syncChannel: SyncChannel?
    private var idleChannel: SyncChannel?
    private var folders: [FolderID: FolderRecord] = [:]
    private var inboxID: FolderID?
    private var currentStatus = SyncStatus(mode: .fullHistory, isOnline: false)
    private var windowedSince: Date?
    private var notified: Set<NotificationKey> = []
    private var statusWaiters: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var mailWaiters: [UUID: AsyncStream<NewMailEvent>.Continuation] = [:]
    private var failureWaiters: [UUID: AsyncStream<SyncFailure>.Continuation] = [:]
    private var lastFailure: SyncFailure?
    private var reconnectAttempt = 0
    private var refreshPulse: Int = 0
    /// Bumped when a delta observes expunges so an in-flight backfill window
    /// cannot commit a FETCH captured before that deletion.
    private var expungeRevision: [FolderID: UInt64] = [:]
    private var activeWriteOperations = 0
    private var writeDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var qresyncEnabled = false

    /// HEADER for threading fields; `1` covers the common single-part body.
    /// Nested text parts are follow-up PEEKed in small UID chunks so a mixed
    /// specifier FETCH cannot kill NIOIMAP's decoder.
    /// Never `TEXT` — that is the whole body including attachments.
    private static let speculativePeeks: [IMAPPeekSection] = [
        .header, .part("1"),
    ]
    private static let followUpPeekChunk = 32

    /// - Parameter qaAmpleDisk: QA/testing only. When `true`, disk policy sees a
    ///   spacious synthetic volume so a nearly-full host cannot halt INBOX
    ///   backfill. Production callers omit this.
    public init(
        store: MailStore,
        config: AccountConfig,
        credentials: any IMAPCredentialProvider,
        qaAmpleDisk: Bool = false
    ) {
        self.init(
            store: store,
            config: config,
            credentials: credentials,
            clientFactory: LiveIMAPClientFactory(),
            disk: qaAmpleDisk ? AmpleDiskSpace() : FileDiskSpace(),
            clock: { Date() },
            settings: .production
        )
    }

    /// Test/LiveWiring seam: inject a scripted IMAP client without exposing disk policy.
    package init(
        store: MailStore,
        config: AccountConfig,
        credentials: any IMAPCredentialProvider,
        clientFactory: any IMAPClientFactory,
        qaAmpleDisk: Bool = false
    ) {
        self.init(
            store: store,
            config: config,
            credentials: credentials,
            clientFactory: clientFactory,
            disk: qaAmpleDisk ? AmpleDiskSpace() : FileDiskSpace(),
            clock: { Date() },
            settings: .production
        )
    }

    init(
        store: MailStore,
        config: AccountConfig,
        credentials: any IMAPCredentialProvider,
        clientFactory: any IMAPClientFactory,
        disk: any DiskSpaceProviding,
        clock: @escaping @Sendable () -> Date,
        settings: SyncSettings
    ) {
        self.store = store
        self.config = config
        self.credentials = credentials
        self.clientFactory = clientFactory
        self.disk = disk
        self.clock = clock
        self.settings = settings
    }

    public func start() async {
        guard runTask == nil else { return }
        stopping = false
        runTask = Task { await self.runLoop() }
    }
    public func stop() async {
        stopping = true
        // Let any in-flight mailbox write finish its server sequence and
        // revision repair before closing the command channel or cancelling
        // the session group.
        await waitForWriteDrain()
        // Close first so in-flight send() waiters resume, then cancel the run loop.
        await teardown()
        runTask?.cancel()
        if let runTask {
            await runTask.value
        }
        self.runTask = nil
        connected = false
        publishStatus(online: false)
    }

    public func refreshNow() async {
        refreshPulse &+= 1
        guard connected, let channel = syncChannel else { return }
        do {
            try await deltaAll(channel: channel, notify: true)
        } catch {
            await logSync("refresh failed", detail: String(describing: error))
        }
    }

    public var status: AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.dropStatus(id) }
            }
            addStatus(id, continuation)
        }
    }

    public var newMail: AsyncStream<NewMailEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.dropMail(id) }
            }
            addMail(id, continuation)
        }
    }

    /// Terminal auth / TLS failures. Transport errors are not emitted here.
    public var failures: AsyncStream<SyncFailure> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.dropFailure(id) }
            }
            addFailure(id, continuation)
        }
    }

    public func fetchPart(message: MessageID, part: String) async throws -> URL {
        guard IMAPSectionSpecifier.isLegal(part) else {
            throw SyncEngineError.invalidPartSpecifier
        }
        let located = try await locateLiveMessage(message)
        let attachment = (try? await store.detail(message))?.attachments.first {
            $0.id.caseInsensitiveCompare(part) == .orderedSame
        }
        var transferEncoding = attachment?.transferEncoding
        if transferEncoding == nil {
            do {
                let headerFetch = try await located.channel.fetch(
                    in: located.path,
                    expectedUIDValidity: located.uidValidity,
                    .peek(
                        uids: IMAPUIDSet(uid: located.uid),
                        section: IMAPPeekSection(specifier: "\(part).MIME")
                    )
                )
                if let header = headerFetch.first?.parts.first(where: {
                    $0.specifier.caseInsensitiveCompare("\(part).MIME") == .orderedSame
                })?.data {
                    transferEncoding = Self.transferEncoding(fromMIMEHeader: header)
                }
            } catch SyncChannelError.staleMailbox {
                throw SyncEngineError.staleMessage
            }
        }
        let fetched: [IMAPFetchedMessage]
        do {
            fetched = try await located.channel.fetch(
                in: located.path,
                expectedUIDValidity: located.uidValidity,
                .peek(uids: IMAPUIDSet(uid: located.uid), section: .part(part))
            )
        } catch SyncChannelError.staleMailbox {
            throw SyncEngineError.staleMessage
        }
        guard let rawData = fetched.first?.parts.first(where: {
            $0.specifier == part || $0.specifier.uppercased() == part.uppercased()
        })?.data, !rawData.isEmpty else {
            throw SyncEngineError.partMissing
        }
        let data: Data
        if let transferEncoding {
            data = try MIMEParser.decodeEncodedPart(
                rawData,
                encoding: ContentTransferEncoding(headerValue: transferEncoding)
            )
        } else {
            data = rawData
        }
        guard !data.isEmpty else { throw SyncEngineError.partMissing }
        let stored = try await store.putAttachment(data: data)
        return stored.url
    }

    private static func transferEncoding(fromMIMEHeader data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame else {
                continue
            }
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }


    public func rawSource(message: MessageID) async throws -> String {
        let located = try await locateLiveMessage(message)
        let section = IMAPPeekSection(specifier: "", binary: false, origin: 0, length: SyncPolicy.rawSourceCap)
        let fetched: [IMAPFetchedMessage]
        do {
            fetched = try await located.channel.fetch(
                in: located.path,
                expectedUIDValidity: located.uidValidity,
                IMAPFetchRequest(uids: IMAPUIDSet(uid: located.uid), uid: true, peek: [section])
            )
        } catch SyncChannelError.staleMailbox {
            throw SyncEngineError.staleMessage
        }
        let data = fetched.first?.parts.first?.data ?? Data()
        return MessageAssembler.escapeRaw(data)
    }

    /// Rejects on-demand fetches tagged with a prior mailbox generation
    /// (spec: sync.md UIDVALIDITY). `messageRef` may return a retiring row;
    /// the UIDVALIDITY pin is enforced atomically with the UID command by the
    /// channel (`fetch(in:expectedUIDValidity:)`), so a selection stolen
    /// between locate and fetch cannot hit the wrong mailbox or generation.
    private func locateLiveMessage(
        _ message: MessageID
    ) async throws -> (uid: UInt32, path: String, uidValidity: UInt32, channel: SyncChannel) {
        try ensureRunning()
        guard let ref = try await store.messageRef(message) else {
            throw SyncEngineError.messageNotFound
        }
        let live = try await store.liveGeneration(for: ref.folder)
        guard live == ref.generation else {
            throw SyncEngineError.staleMessage
        }
        guard let summary = try await store.fetchFolderSummary(ref.folder) else {
            throw SyncEngineError.folderNotFound
        }
        guard let channel = syncChannel else { throw SyncEngineError.stopped }
        return (ref.uid.rawValue, summary.path, ref.generation.uidValidity, channel)
    }

    private func addStatus(_ id: UUID, _ continuation: AsyncStream<SyncStatus>.Continuation) {
        statusWaiters[id] = continuation
        continuation.yield(currentStatus)
    }

    private func dropStatus(_ id: UUID) { statusWaiters.removeValue(forKey: id) }

    private func addMail(_ id: UUID, _ continuation: AsyncStream<NewMailEvent>.Continuation) {
        mailWaiters[id] = continuation
    }

    private func dropMail(_ id: UUID) { mailWaiters.removeValue(forKey: id) }

    private func addFailure(_ id: UUID, _ continuation: AsyncStream<SyncFailure>.Continuation) {
        failureWaiters[id] = continuation
        if let lastFailure {
            continuation.yield(lastFailure)
        }
    }

    private func dropFailure(_ id: UUID) { failureWaiters.removeValue(forKey: id) }

    private func emitFailure(_ failure: SyncFailure) {
        lastFailure = failure
        for continuation in failureWaiters.values {
            continuation.yield(failure)
        }
    }

    private static func classifyTerminal(_ error: Error) -> SyncFailure? {
        if let imap = error as? IMAPError {
            switch imap {
            case .auth(let message):
                return .authentication(message: message)
            case .tls(let message):
                return .tls(message: message)
            default:
                return nil
            }
        }
        return nil
    }

    private func publishStatus(online: Bool? = nil, mode: SyncStatus.Mode? = nil) {
        if let online {
            currentStatus = SyncStatus(mode: mode ?? currentStatus.mode, isOnline: online)
        } else if let mode {
            currentStatus = SyncStatus(mode: mode, isOnline: currentStatus.isOnline)
        }
        for continuation in statusWaiters.values {
            continuation.yield(currentStatus)
        }
    }

    private func emit(_ event: NewMailEvent) {
        for continuation in mailWaiters.values {
            continuation.yield(event)
        }
    }

    private func ensureRunning() throws {
        if stopping || runTask == nil { throw SyncEngineError.stopped }
    }

    private func beginWriteOperation() {
        activeWriteOperations += 1
    }

    private func endWriteOperation() {
        activeWriteOperations -= 1
        guard activeWriteOperations == 0 else { return }
        let waiters = writeDrainWaiters
        writeDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForWriteDrain() async {
        guard activeWriteOperations > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeDrainWaiters.append(continuation)
        }
    }

    private func runLoop() async {
        while !stopping && !Task.isCancelled {
            do {
                try await session()
            } catch is CancellationError {
                break
            } catch {
                if (stopping || Task.isCancelled) && SyncPolicy.isTransport(error) {
                    break
                }
                if let failure = Self.classifyTerminal(error) {
                    emitFailure(failure)
                    stopping = true
                    await logSync("terminal failure", detail: String(describing: error))
                } else {
                    await logSync("session ended", detail: String(describing: error))
                }
            }
            await teardown()
            connected = false
            publishStatus(online: false)
            if stopping || Task.isCancelled { break }
            reconnectAttempt += 1
            let delay = settings.reconnect.delay(forAttempt: reconnectAttempt)
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        await teardown()
    }

    private func session() async throws {
        sessionBroken = false
        backfillPassFinished = false
        try await store.upsertAccount(config)
        let password = try await credentials.password(for: config.id)
        let syncClient = clientFactory.makeClient(
            endpoint: config.imap,
            username: config.username,
            password: password
        )
        let sync = SyncChannel(client: syncClient)
        do {
            try await sync.connect()
        } catch {
            await sync.close()
            throw error
        }
        syncChannel = sync

        dualConnection = false
        idleChannel = nil
        // Second connection opens only after every folder walk settles.
        // Opening it (or IDLEing) during the 100k FETCH stalls Dovecot/NIO.

        connected = true
        reconnectAttempt = 0
        lastFailure = nil
        publishStatus(online: true)

        try await enablePreferredExtensions(channel: sync)
        try await discover(channel: sync)
        try await deltaAll(channel: sync, notify: true)
        try await repairLegacyIncompleteBackfills()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.backfillAll() }
            group.addTask { await self.idleAfterInboxBackfill(password: password) }
            group.addTask { await self.periodicLoop() }
            group.addTask { await self.seenLoop() }
            group.addTask { await self.cleanupLoop() }
            group.addTask { await self.watchBye() }
            while (!self.stopping || self.activeWriteOperations > 0)
                    && !self.sessionBroken && !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(200))
            }
            group.cancelAll()
        }
    }

    private func teardown() async {
        let idle = idleChannel
        let sync = syncChannel
        idleChannel = nil
        syncChannel = nil
        if let idle { await idle.close() }
        if let sync { await sync.close() }
        dualConnection = false
        sessionBroken = false
        qresyncEnabled = false
    }

    private func enablePreferredExtensions(channel: SyncChannel) async throws {
        let caps = await channel.capabilities()
        guard caps.qresync, settings.allowEnableQResync else {
            qresyncEnabled = false
            return
        }
        do {
            try await channel.enableQResync()
            qresyncEnabled = true
        } catch {
            qresyncEnabled = false
            await logSync("ENABLE QRESYNC failed", detail: String(describing: error))
        }
    }

    private func advertisedDeltaPath(_ caps: IMAPCapabilities) -> DeltaPath {
        var path = SyncPolicy.advertisedPath(caps.recommendedDeltaPath)
        if path == .qresync && !qresyncEnabled {
            path = caps.condstore ? .condstore : .basic
        }
        return path
    }

    private func watchBye() async {
        guard let channel = syncChannel else { return }
        let events = await channel.eventStream()
        for await event in events {
            if case .bye = event {
                sessionBroken = true
                return
            }
            if Task.isCancelled { return }
        }
    }

    private func discover(channel: SyncChannel) async throws {
        let discovery = try await channel.listFolders()
        if discovery.isGmail {
            try await store.recordError(StoreLogEntry(
                kind: .sync,
                account: config.id,
                message: "Gmail-via-IMAP is unsupported",
                detail: "X-GM-EXT-1 or known Gmail host"
            ))
        }
        var records: [FolderRecord] = []
        records.reserveCapacity(discovery.folders.count)
        var seen: [FolderKey] = []
        seen.reserveCapacity(discovery.folders.count)
        for mailbox in discovery.folders {
            let folderID = try await store.upsertFolder(
                account: config.id,
                path: mailbox.path,
                name: mailbox.name,
                separator: mailbox.separator,
                role: mailbox.role,
                objectID: mailbox.mailboxID
            )
            seen.append(FolderKey(path: mailbox.path, objectID: mailbox.mailboxID))
            let record = try await prepare(
                channel: channel,
                folderID: folderID,
                mailbox: mailbox,
                persistBaseline: mailbox.role == .inbox
            )
            records.append(record)
            if mailbox.role == .inbox { inboxID = folderID }
        }
        // Successful LIST only — never call this on a thrown listFolders.
        // Empty `seen` retires every live folder, which is correct for a
        // successful empty LIST and wrong for a failed one.
        let retired = try await store.reconcileFolders(account: config.id, seen: seen)
        folders = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for id in retired {
            folders.removeValue(forKey: id)
            if inboxID == id { inboxID = nil }
        }
    }

    private func prepare(
        channel: SyncChannel,
        folderID: FolderID,
        mailbox: IMAPMailbox,
        persistBaseline: Bool
    ) async throws -> FolderRecord {
        let selected = try await channel.select(mailbox.path)
        let advertised = advertisedDeltaPath(await channel.capabilities())
        let computedBaseline = SyncPolicy.baseline(uidNext: selected.uidNext)
        let baseline = persistBaseline ? computedBaseline : nil
        let existingLive = try await store.liveGeneration(for: folderID)
        let generation: MailboxGeneration
        var isReplacement = false
        var isFresh = existingLive == nil
        if let existingLive, existingLive.uidValidity != selected.uidValidity {
            generation = try await store.createReplacementGeneration(
                folder: folderID,
                uidValidity: selected.uidValidity,
                baselineUID: persistBaseline ? computedBaseline : nil
            )
            isReplacement = true
            isFresh = true
        } else {
            generation = try await store.openLiveGeneration(
                folder: folderID,
                uidValidity: selected.uidValidity,
                baselineUID: baseline
            )
        }

        var state = try await store.fetchSyncState(for: generation) ?? FolderSyncState(generation: generation)
        if persistBaseline, state.baselineUID == nil {
            state.baselineUID = computedBaseline
        }
        if isFresh {
            state.deltaPath = advertised
        } else {
            state.deltaPath = SyncPolicy.initialPath(
                stored: state.deltaPath,
                advertised: advertised,
                isFresh: false
            )
        }
        if selected.noModSeq, state.deltaPath != .basic {
            state.deltaPath = .basic
            try await store.recordError(StoreLogEntry(
                kind: .sync,
                account: config.id,
                folder: folderID,
                generation: generation,
                message: "downgraded to basic (NOMODSEQ)",
                detail: mailbox.path
            ))
        }
        if let mod = selected.highestModSeq {
            state.highestModseq = max(state.highestModseq ?? 0, mod)
        }
        try await store.saveSyncState(state)

        let storedUIDs = try await store.uids(in: generation, range: nil)
        let maxStored = storedUIDs.last?.rawValue ?? 0
        let uidNext = selected.uidNext ?? 1

        // Empty store → current UIDNEXT so the first delta does not fetch
        // history (backfill owns that, without notify). After any stored UID,
        // maxStored+1 is the offline gap; max(uidNext, maxStored+1) would hide it.
        let lastUidNext: UInt32 = maxStored >= 1 ? maxStored &+ 1 : max(uidNext, 1)

        return FolderRecord(
            id: folderID,
            path: mailbox.path,
            name: mailbox.name,
            role: mailbox.role,
            generation: generation,
            baseline: state.baselineUID,
            deltaPath: state.deltaPath,
            highestModseq: state.highestModseq,
            lastUidNext: lastUidNext,
            lastDeltaAt: Date(timeIntervalSince1970: 0),
            serverMessageCount: selected.exists,
            isReplacement: isReplacement
        )
    }
    private func backfillAll() async {
        let ordered = SyncPolicy.sortFolders(Array(folders.values))
        let maxRevisionRetries = 3
        for record in ordered {
            var revisionRetries = 0
            while !stopping && !Task.isCancelled {
                let revisionBefore = expungeRevision[record.id, default: 0]
                let result = await syncFolderHistory(folderID: record.id)
                let revisionAfter = expungeRevision[record.id, default: 0]
                let state: FolderSyncState?
                if let current = folders[record.id] {
                    state = try? await store.fetchSyncState(for: current.generation)
                } else {
                    state = nil
                }
                let shouldRetry = result == .invalidated
                    && !stopping
                    && !Task.isCancelled
                    && !sessionBroken
                    && state?.backfillPhase == .walking
                    && revisionAfter != revisionBefore
                    && revisionRetries < maxRevisionRetries
                guard shouldRetry else { break }
                revisionRetries += 1
            }
        }
        if !stopping && !Task.isCancelled {
            backfillPassFinished = true
        }
    }
    /// Older builds advanced the durable cursor across messages rejected by
    /// the setup-time cutoff. A completed generation with fewer local rows than
    /// the post-delta server count is therefore incomplete. Reset its cursor
    /// once so the normal idempotent upsert walk fills every gap.
    private func repairLegacyIncompleteBackfills() async throws {
        for record in folders.values where !record.isReplacement {
            guard record.serverMessageCount > 0,
                  let summary = try await store.fetchFolderSummary(record.id),
                  summary.totalCount < record.serverMessageCount,
                  var state = try await store.fetchSyncState(for: record.generation),
                  state.backfillPhase == .complete
            else {
                continue
            }
            state.backfillPhase = .walking
            state.lowWaterUID = nil
            state.progress = 0
            state.haltedThrough = nil
            try await store.saveSyncState(state)
            try await store.recordError(StoreLogEntry(
                kind: .sync,
                account: config.id,
                folder: record.id,
                generation: record.generation,
                message: "repairing incomplete completed backfill",
                detail: "local=\(summary.totalCount) server=\(record.serverMessageCount) path=\(record.path)"
            ))
        }
    }
    private func clearWindowedModeIfResolved() async {
        guard windowedSince != nil else { return }
        for record in folders.values {
            if let state = try? await store.fetchSyncState(for: record.generation),
               state.backfillPhase == .halted {
                return
            }
        }
        windowedSince = nil
        publishStatus(mode: .fullHistory)
    }

    /// Backfill, then atomically switch a replacement generation only once it is complete.
    private func syncFolderHistory(folderID: FolderID) async -> BackfillAttemptResult {
        let result = await backfill(folderID: folderID)
        await activateIfReplacementComplete(folderID: folderID)
        return result
    }

    private func activateIfReplacementComplete(folderID: FolderID) async {
        guard folders[folderID]?.isReplacement == true else { return }
        guard let record = folders[folderID] else { return }
        guard let state = try? await store.fetchSyncState(for: record.generation),
              state.backfillPhase == .complete else { return }
        await activateReplacement(folderID: folderID)
    }

    private func backfill(folderID: FolderID) async -> BackfillAttemptResult {
        guard var record = folders[folderID], let channel = syncChannel else { return .halted }
        do {
            var state = try await store.fetchSyncState(for: record.generation)
                ?? FolderSyncState(generation: record.generation, baselineUID: record.baseline)
            if state.backfillPhase == .complete { return .committed }
            if state.backfillPhase == .halted {
                let snap = disk.snapshot(for: settings.diskURL)
                let reserve = SyncPolicy.reserveBytes(volumeBytes: snap.volumeBytes)
                if SyncPolicy.shouldResume(freeBytes: snap.freeBytes, reserveBytes: reserve) {
                    state.backfillPhase = .walking
                    state.haltedThrough = nil
                    try await store.saveSyncState(state)
                    await clearWindowedModeIfResolved()
                } else {
                    let since = state.haltedThrough ?? clock()
                    if state.haltedThrough == nil {
                        state.haltedThrough = since
                        try await store.saveSyncState(state)
                    }
                    if windowedSince == nil {
                        windowedSince = since
                    }
                    if let windowedSince {
                        publishStatus(mode: .windowed(since: windowedSince))
                    }
                    return .halted
                }
            }

            let selected = try await channel.select(record.path)
            let previousGeneration = record.generation
            try await maybeReplace(selected: selected, record: &record)
            folders[folderID] = record
            if record.generation != previousGeneration {
                state = try await store.fetchSyncState(for: record.generation)
                    ?? FolderSyncState(generation: record.generation, baselineUID: record.baseline)
                if state.backfillPhase == .complete { return .committed }
            }
            let uidNext = selected.uidNext ?? record.lastUidNext

            if let low = state.lowWaterUID, state.backfillPhase != .complete {
                await logSync(
                    "resuming backfill from cursor",
                    detail: "path=\(record.path) lowWater=\(low.rawValue) uidNext=\(uidNext)",
                    folder: folderID
                )
            }

            state.backfillPhase = .walking
            try await store.saveSyncState(state)

            while !stopping && !Task.isCancelled {
                try Task.checkCancellation()
                let snap = disk.snapshot(for: settings.diskURL)
                let reserve = SyncPolicy.reserveBytes(volumeBytes: snap.volumeBytes)
                // Spec: start the newest INBOX window immediately. Halt the
                // backward walk only after at least one window has committed.
                let hasCommittedWindow = state.lowWaterUID != nil
                if hasCommittedWindow && SyncPolicy.shouldHalt(freeBytes: snap.freeBytes, reserveBytes: reserve) {
                    state.backfillPhase = .halted
                    state.haltedThrough = clock()
                    try await store.saveSyncState(state)
                    try await store.recordError(StoreLogEntry(
                        kind: .sync,
                        account: config.id,
                        folder: folderID,
                        generation: record.generation,
                        message: "backfill halted: free space below reserve",
                        detail: "free=\(snap.freeBytes) reserve=\(reserve) path=\(record.path)"
                    ))
                    if windowedSince == nil {
                        windowedSince = state.haltedThrough
                    }
                    if let since = windowedSince {
                        publishStatus(mode: .windowed(since: since))
                    }
                    return .halted
                }

                let windowSize = SyncPolicy.backfillWindowSize(
                    configured: settings.backfillWindowSize,
                    lowWater: state.lowWaterUID?.rawValue
                )
                guard let window = SyncPolicy.nextWindow(
                    uidNext: uidNext,
                    windowSize: windowSize,
                    lowWater: state.lowWaterUID?.rawValue
                ) else {
                    state.backfillPhase = .complete
                    state.progress = 1
                    try await store.saveSyncState(state)
                    await clearWindowedModeIfResolved()
                    return .committed
                }
                let capturedGeneration = record.generation
                let result = try await ingestWindow(
                    record: record,
                    window: window,
                    channel: channel,
                    notify: false,
                    expectedExpungeRevision: expungeRevision[folderID] ?? 0
                )

                // Cursor advances only after a committed window. Cancellation
                // mid-ingest must not persist low-water (spec: sync.md backfill).
                try Task.checkCancellation()
                switch result {
                case .committed:
                    break
                case .invalidated, .halted:
                    return result
                }
                guard stillCurrentGeneration(capturedGeneration, folder: folderID) else { return .invalidated }
                state.lowWaterUID = IMAPUID(rawValue: window.lowerBound)
                state.progress = SyncPolicy.backfillProgress(uidNext: uidNext, lowWater: state.lowWaterUID?.rawValue)
                try await store.saveSyncState(state)
            }
        } catch is CancellationError {
            return .halted
        } catch {
            if (stopping || Task.isCancelled) && SyncPolicy.isTransport(error) {
                return .halted
            }
            await logSync("backfill \(record.path)", detail: String(describing: error), folder: folderID)
            if SyncPolicy.isTransport(error) {
                sessionBroken = true
            }
            return .halted
        }
        return .halted
    }

    private func ingestWindow(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        channel: SyncChannel,
        notify: Bool,
        expectedExpungeRevision: UInt64? = nil
    ) async throws -> BackfillAttemptResult {
        let capturedGeneration = record.generation
        let uidSet = IMAPUIDSet(window)
        let meta: [IMAPFetchedMessage]
        do {
            meta = try await channel.fetch(
                in: record.path,
                expectedUIDValidity: capturedGeneration.uidValidity,
                IMAPFetchRequest(
                    uids: uidSet,
                    envelope: true,
                    bodyStructure: true,
                    flags: true,
                    internalDate: true,
                    uid: true,
                    peek: Self.speculativePeeks
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch SyncChannelError.staleMailbox {
            // UIDVALIDITY moved; the next delta pass opens a replacement
            // generation. Window not committed.
            return .invalidated
        } catch {
            if (stopping || Task.isCancelled) && SyncPolicy.isTransport(error) {
                return .halted
            }
            await logSync("window fetch \(record.path)", detail: String(describing: error), folder: record.id)
            if SyncPolicy.isTransport(error) { throw error }
            return try await quarantineUnknown(
                record: record,
                window: window,
                channel: channel,
                reason: String(describing: error),
                expectedExpungeRevision: expectedExpungeRevision
            )
        }


        var bodies: [UInt32: [IMAPPeekedPart]] = [:]
        var missingByUID: [UInt32: [String]] = [:]
        for message in meta {
            guard let uid = message.uid else { continue }
            bodies[uid] = message.parts
            guard let structure = message.bodyStructure else { continue }
            let needed = MessageAssembler.textNeeds(structure).map(\.specifier)
            let have = Set(message.parts.map { $0.specifier.uppercased() })
            let missing = needed.filter { specifier in
                let upper = specifier.uppercased()
                if have.contains(upper) { return false }
                if upper == "1" && (have.contains("TEXT") || have.contains("")) { return false }
                return true
            }
            if !missing.isEmpty {
                missingByUID[uid] = missing
            }
        }

        if !missingByUID.isEmpty {
            var grouped: [[String]: [UInt32]] = [:]
            for (uid, specs) in missingByUID {
                let filtered = specs.filter { spec in
                    spec.unicodeScalars.allSatisfy { $0 == "." || ("0"..."9").contains($0) }
                }.sorted()
                if !filtered.isEmpty {
                    grouped[filtered, default: []].append(uid)
                }
            }
            for (specifiers, uids) in grouped {
                let sortedUIDs = uids.sorted()
                var index = 0
                while index < sortedUIDs.count {
                    let end = min(index + Self.followUpPeekChunk, sortedUIDs.count)
                    let chunk = Array(sortedUIDs[index..<end])
                    index = end
                    do {
                        let fetched = try await channel.fetch(
                            in: record.path,
                            expectedUIDValidity: capturedGeneration.uidValidity,
                            IMAPFetchRequest(
                                uids: SyncPolicy.uidSet(uids: chunk),
                                uid: true,
                                peek: specifiers.map { IMAPPeekSection.part($0) }
                            )
                        )
                        for message in fetched {
                            guard let uid = message.uid else { continue }
                            var parts = bodies[uid] ?? []
                            parts.append(contentsOf: message.parts)
                            bodies[uid] = parts
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if (stopping || Task.isCancelled) && SyncPolicy.isTransport(error) {
                            return .halted
                        }
                        await logSync("body peek \(record.path)", detail: String(describing: error), folder: record.id)
                        if SyncPolicy.isTransport(error) { throw error }
                    }
                }
            }
        }

        let generation = record.generation
        let now = clock()
        var built: [IncomingMessage] = []
        built.reserveCapacity(meta.count)
        for fetched in meta {
            guard let uid = fetched.uid else { continue }
            let incoming = MessageAssembler.incoming(
                generation: generation,
                fetched: fetched,
                bodyParts: bodies[uid] ?? fetched.parts,
                now: now
            )
            built.append(incoming)
        }

        guard stillCurrentGeneration(capturedGeneration, folder: record.id) else { return .invalidated }
        if built.isEmpty { return .committed }
        built.sort { $0.uid > $1.uid }

        let canNotify = notify && record.role == .inbox && !record.isReplacement
        var pendingNotify: [IncomingMessage] = []
        if canNotify {
            for message in built {
                if SyncPolicy.isNotifiable(uid: message.uid, baseline: record.baseline) {
                    let existed = try await store.messageID(generation: generation, uid: message.uid) != nil
                    if !existed { pendingNotify.append(message) }
                }
            }
        }

        if let expectedExpungeRevision,
           expectedExpungeRevision != expungeRevision[record.id, default: 0] {
            return .invalidated
        }
        guard stillCurrentGeneration(capturedGeneration, folder: record.id) else { return .invalidated }
        _ = try await store.upsertMessages(built)

        // An expunge can arrive while the upsert is suspended. Reconcile
        // again after the write so the stale FETCH cannot resurrect rows that
        // the concurrent delta already removed.
        if let expectedExpungeRevision,
           expectedExpungeRevision != expungeRevision[record.id, default: 0] {
            let latest = try await channel.select(record.path)
            try await reconcileExpunges(
                record: record,
                selected: latest,
                channel: channel,
                revisionAlreadyAdvanced: true
            )
            return .committed
        }

        if canNotify {
            for message in pendingNotify {
                let key = NotificationKey(generation: generation, uid: message.uid)
                if notified.insert(key).inserted,
                   let id = try await store.messageID(generation: generation, uid: message.uid) {
                    emit(NewMailEvent(
                        folder: record.id,
                        from: MessageAssembler.senderDisplay(message.envelope),
                        subject: message.envelope.subject,
                        messageID: id
                    ))
                }
            }
        }
        return .committed
    }

    private func ingestNewUIDs(
        record: FolderRecord,
        from lo: UInt32,
        to hi: UInt32,
        channel: SyncChannel,
        notify: Bool,
        expectedExpungeRevision: UInt64? = nil
    ) async throws {
        let uidNext = hi < UInt32.max ? hi &+ 1 : hi
        var expectedRevision = expectedExpungeRevision

        // A concurrent EXPUNGE/append can invalidate a FETCH after it has
        // captured its UID range. Retry the complete append range against the
        // new revision so a delta never advances lastUidNext past unwritten
        // messages. A generation replacement is not retryable with this
        // record, and repeated revisions are bounded.
        for _ in 0...3 {
            var lowWater: UInt32? = nil
            var invalidated = false
            while let window = SyncPolicy.nextWindow(
                uidNext: uidNext,
                windowSize: settings.backfillWindowSize,
                lowWater: lowWater
            ) {
                let start = max(window.lowerBound, lo)
                if start <= window.upperBound {
                    let result = try await ingestWindow(
                        record: record,
                        window: start...window.upperBound,
                        channel: channel,
                        notify: notify,
                        expectedExpungeRevision: expectedRevision
                    )
                    switch result {
                    case .committed:
                        break
                    case .invalidated:
                        invalidated = true
                    case .halted:
                        return
                    }
                    if invalidated { break }
                }
                if window.lowerBound <= lo { break }
                lowWater = window.lowerBound
            }
            if !invalidated { return }
            guard !stopping, !Task.isCancelled,
                  folders[record.id]?.generation == record.generation else {
                return
            }
            expectedRevision = expungeRevision[record.id, default: 0]
        }
    }

    private func quarantineUnknown(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        channel: SyncChannel,
        reason: String,
        expectedExpungeRevision: UInt64? = nil
    ) async throws -> BackfillAttemptResult {
        // Quarantine rows are what make cursor advance legal for a failed
        // window (spec: every UID committed as message or quarantine). A
        // failure here must propagate so the cursor never skips the window.
        let flags = try await channel.fetch(
            in: record.path,
            expectedUIDValidity: record.generation.uidValidity,
            .flags(uids: IMAPUIDSet(window))
        )
        // Stop may have released a paused FLAGS continuation after teardown;
        // never let that late result start a quarantine write.
        guard !stopping else { return .halted }
        let now = clock()
        let incoming = flags.compactMap { fetched -> IncomingMessage? in
            guard let uid = fetched.uid else { return nil }
            return MessageAssembler.quarantined(
                generation: record.generation,
                uid: IMAPUID(rawValue: uid),
                fetched: fetched,
                reason: reason,
                now: now
            )
        }

        if let expectedExpungeRevision,
           expectedExpungeRevision != expungeRevision[record.id, default: 0] {
            // The fallback FLAGS reply may have crossed an EXPUNGE delta.
            // Do not write its stale UID set or advance the cursor.
            return .invalidated
        }
        guard !incoming.isEmpty else { return .committed }

        // Once the write begins, stop waits for the post-write revision check
        // and expunge repair instead of cancelling it halfway through.
        beginWriteOperation()
        defer { endWriteOperation() }
        _ = try await store.upsertMessages(incoming)
        if let expectedExpungeRevision,
           expectedExpungeRevision != expungeRevision[record.id, default: 0] {
            let latest = try await channel.select(record.path)
            try await reconcileExpunges(
                record: record,
                selected: latest,
                channel: channel,
                revisionAlreadyAdvanced: true
            )
            return .invalidated
        }
        return .committed
    }


    private func activateReplacement(folderID: FolderID) async {
        guard var record = folders[folderID] else { return }
        do {
            try await store.activateReplacementGeneration(folder: folderID)
            record.isReplacement = false
            folders[folderID] = record
            try await store.dropStaleFlag(folder: folderID)
            try await store.dropStaleMove(folder: folderID)
        } catch {
            await logSync("activate replacement", detail: String(describing: error), folder: folderID)
        }
    }

    private func maybeReplace(selected: IMAPSelectedMailbox, record: inout FolderRecord) async throws {
        if selected.uidValidity == record.generation.uidValidity { return }
        let baseline = SyncPolicy.baseline(uidNext: selected.uidNext)
        let persist = record.role == .inbox
        let generation = try await store.createReplacementGeneration(
            folder: record.id,
            uidValidity: selected.uidValidity,
            baselineUID: persist ? baseline : nil
        )
        var state = try await store.fetchSyncState(for: generation) ?? FolderSyncState(generation: generation)
        if persist {
            state.baselineUID = baseline
        }
        state.deltaPath = record.deltaPath
        try await store.saveSyncState(state)
        record.generation = generation
        record.baseline = persist ? baseline : nil
        record.isReplacement = true
        record.lastUidNext = selected.uidNext ?? 1
        record.highestModseq = selected.highestModSeq
    }

    private func deltaAll(channel: SyncChannel, notify: Bool) async throws {
        let ordered = SyncPolicy.sortFolders(Array(folders.values))
        for record in ordered {
            if stopping || Task.isCancelled { return }
            try await delta(folderID: record.id, channel: channel, notify: notify)
        }
    }

    private func delta(folderID: FolderID, channel: SyncChannel, notify: Bool) async throws {
        guard var record = folders[folderID] else { return }
        do {
            try await runDelta(record: &record, channel: channel, notify: notify)
            record.lastDeltaAt = clock()
            folders[folderID] = record
        } catch {
            if let reason = SyncPolicy.taggedReason(error) {
                try await persistDowngrade(&record, reason: reason, channel: channel)
                folders[folderID] = record
                try await runDelta(record: &record, channel: channel, notify: notify)
                record.lastDeltaAt = clock()
                folders[folderID] = record
            } else {
                throw error
            }
        }
    }

    private func persistDowngrade(
        _ record: inout FolderRecord,
        reason: SyncPolicy.DowngradeReason,
        channel: SyncChannel
    ) async throws {
        let caps = await channel.capabilities()
        let next = SyncPolicy.downgrade(
            from: record.deltaPath,
            reason: reason,
            advertisedHasCondstore: caps.condstore
        )
        if next == record.deltaPath { return }
        record.deltaPath = next
        var state = try await store.fetchSyncState(for: record.generation)
            ?? FolderSyncState(generation: record.generation)
        state.deltaPath = next
        try await store.saveSyncState(state)
        try await store.recordError(StoreLogEntry(
            kind: .sync,
            account: config.id,
            folder: record.id,
            generation: record.generation,
            message: "downgraded to \(next.rawValue)",
            detail: reason.rawValue
        ))
    }

    private func runDelta(record: inout FolderRecord, channel: SyncChannel, notify: Bool) async throws {
        let selected: IMAPSelectedMailbox
        let vanished: [UInt32]
        switch record.deltaPath {
        case .qresync:
            let qresync: IMAPQResyncSelect?
            if let mod = record.highestModseq, mod > 0 {
                qresync = IMAPQResyncSelect(
                    uidValidity: record.generation.uidValidity,
                    modificationSequence: mod,
                    knownUIDs: SyncPolicy.knownUIDSet(uidNext: max(record.lastUidNext, 1))
                )
            } else {
                qresync = nil
            }
            selected = try await channel.select(record.path, qresync: qresync)
            vanished = selected.vanishedEarlier + selected.vanished
        case .condstore, .basic:
            selected = try await channel.select(record.path)
            vanished = []
        }

        let observedExpunge = selected.exists < record.serverMessageCount || !vanished.isEmpty
        let uidNextChanged = selected.uidNext.map { $0 != record.lastUidNext } ?? false
        // Invalidate an in-flight FETCH before any path-specific await. UIDNEXT
        // identifies the selected mailbox even when a removed UID was never
        // written locally, so this also covers an expunge+append with unchanged
        // EXISTS. Append-only changes conservatively invalidate the FETCH too.
        let revisionAlreadyAdvanced = observedExpunge || uidNextChanged
        if revisionAlreadyAdvanced {
            expungeRevision[record.id, default: 0] &+= 1
        }

        switch record.deltaPath {
        case .qresync:
            if selected.noModSeq {
                try await persistDowngrade(&record, reason: .noModSeq, channel: channel)
            }
            let generationChanged = selected.uidValidity != record.generation.uidValidity
            try await maybeReplace(selected: selected, record: &record)
            // Publish a replacement before any following await so an in-flight
            // backfill cannot continue committing rows into the retired generation.
            folders[record.id] = record
            // VANISHED, expunge reconciliation, and flag FETCHes belong to the
            // generation selected above. A UIDVALIDITY change has already moved
            // `record` to a fresh generation, so those old-generation results
            // must not be applied to it.
            if !generationChanged {
                if !vanished.isEmpty {
                    _ = try await store.deleteUIDs(
                        generation: record.generation,
                        uids: vanished.map { IMAPUID(rawValue: $0) }
                    )
                }
                // A QRESYNC SELECT can race an in-flight EXPUNGE burst delivered
                // on the IDLE socket. If EXISTS moved backwards or QRESYNC
                // carried a VANISHED set, sweep stored UIDs as the lossless
                // fallback. This never runs on an ordinary refresh.
                if observedExpunge {
                    try await reconcileExpunges(
                        record: record,
                        selected: selected,
                        channel: channel,
                        revisionAlreadyAdvanced: revisionAlreadyAdvanced
                    )
                }
                if let mod = record.highestModseq, await folderHasMessages(record) {
                    let flags = try await channel.fetch(
                        in: record.path,
                        expectedUIDValidity: record.generation.uidValidity,
                        .flagsChangedSince(
                            uids: SyncPolicy.knownUIDSet(uidNext: selected.uidNext ?? record.lastUidNext),
                            modSeq: mod
                        )
                    )
                    try await applyFlagFetch(flags, record: record)
                }
            }
        case .condstore:
            if selected.noModSeq {
                try await persistDowngrade(&record, reason: .noModSeq, channel: channel)
            }
            let generationChanged = selected.uidValidity != record.generation.uidValidity
            try await maybeReplace(selected: selected, record: &record)
            folders[record.id] = record
            if !generationChanged {
                try await reconcileExpunges(
                    record: record,
                    selected: selected,
                    channel: channel,
                    revisionAlreadyAdvanced: revisionAlreadyAdvanced
                )
                if let mod = record.highestModseq, await folderHasMessages(record) {
                    let flags = try await channel.fetch(
                        in: record.path,
                        expectedUIDValidity: record.generation.uidValidity,
                        .flagsChangedSince(
                            uids: SyncPolicy.knownUIDSet(uidNext: selected.uidNext ?? record.lastUidNext),
                            modSeq: mod
                        )
                    )
                    try await applyFlagFetch(flags, record: record)
                }
            }
        case .basic:
            let generationChanged = selected.uidValidity != record.generation.uidValidity
            try await maybeReplace(selected: selected, record: &record)
            folders[record.id] = record
            if !generationChanged {
                try await reconcileExpunges(
                    record: record,
                    selected: selected,
                    channel: channel,
                    revisionAlreadyAdvanced: revisionAlreadyAdvanced
                )
            }
        }
        // Repair decisions compare the local count with the latest EXISTS,
        // not the count captured during discovery.
        record.serverMessageCount = selected.exists

        let uidNext = selected.uidNext ?? record.lastUidNext
        if uidNext > record.lastUidNext {
            let lo = record.lastUidNext
            let hi = uidNext &- 1
            if lo >= 1, lo <= hi {
                try await ingestNewUIDs(
                    record: record,
                    from: lo,
                    to: hi,
                    channel: channel,
                    notify: notify && !record.isReplacement,
                    expectedExpungeRevision: expungeRevision[record.id] ?? 0
                )
            }
        }
        record.lastUidNext = max(record.lastUidNext, uidNext)
        if let mod = selected.highestModSeq {
            record.highestModseq = max(record.highestModseq ?? 0, mod)
        }
        var state = try await store.fetchSyncState(for: record.generation)
            ?? FolderSyncState(generation: record.generation)
        state.highestModseq = record.highestModseq
        state.deltaPath = record.deltaPath
        try await store.saveSyncState(state)

        folders[record.id] = record
        if record.isReplacement {
            _ = await backfill(folderID: record.id)
            await activateIfReplacementComplete(folderID: record.id)
            if let latest = folders[record.id] {
                record = latest
            }
        }
    }

    private func applyFlagFetch(_ messages: [IMAPFetchedMessage], record: FolderRecord) async throws {
        let deltas = messages.compactMap { fetched -> FlagDelta? in
            guard let uid = fetched.uid else { return nil }
            return FlagDelta(uid: IMAPUID(rawValue: uid), flags: SyncPolicy.messageFlags(fetched.flags))
        }
        if !deltas.isEmpty {
            try await store.applyFlags(generation: record.generation, deltas: deltas)
        }
    }

    private func reconcileExpunges(
        record: FolderRecord,
        selected: IMAPSelectedMailbox,
        channel: SyncChannel,
        revisionAlreadyAdvanced: Bool = false
    ) async throws {
        var revisionAdvanced = revisionAlreadyAdvanced
        let uidNext = selected.uidNext ?? record.lastUidNext
        guard uidNext > 1 else {
            let stored = try await store.uids(in: record.generation, range: nil)
            if !stored.isEmpty {
                if !revisionAdvanced {
                    expungeRevision[record.id, default: 0] &+= 1
                    revisionAdvanced = true
                }
                _ = try await store.deleteUIDs(generation: record.generation, uids: stored)
            }
            return
        }
        for range in SyncPolicy.flagSweepWindows(uidNext: uidNext, windowSize: settings.flagSweepWindowSize) {
            try Task.checkCancellation()
            let stored = try await store.uids(in: record.generation, range: range)
            if stored.isEmpty { continue }
            // Atomic in-mailbox fetch: a stolen selection here would make the
            // server set miss every stored UID and mass-delete live rows.
            let fetched = try await channel.fetch(
                in: record.path,
                expectedUIDValidity: record.generation.uidValidity,
                .flags(uids: IMAPUIDSet(range))
            )
            let server = Set(fetched.compactMap(\.uid))
            let gone = stored.filter { !server.contains($0.rawValue) }
            if !gone.isEmpty {
                if !revisionAdvanced {
                    expungeRevision[record.id, default: 0] &+= 1
                    revisionAdvanced = true
                }
                _ = try await store.deleteUIDs(generation: record.generation, uids: gone)
            }
            try await applyFlagFetch(fetched, record: record)
        }
    }

    /// IDLE on a second connection while the sync connection is mid-FETCH
    /// can stall Dovecot/NIO (no tagged FETCH reply). Wait until every folder
    /// walk has settled, then open the idle socket so the 100k INBOX + Horrors
    /// backfill stays single-connection.
    private func idleAfterInboxBackfill(password: String) async {
        await waitUntilWalksSettle()
        if stopping || Task.isCancelled { return }
        // Catch up INBOX before sitting in IDLE. Mail and VANISHED that arrived
        // during backfill (or a UIDVALIDITY replacement) otherwise wait on a
        // hint that was never observed: dual-connection periodic skips INBOX,
        // and EXISTS emitted before beginIdle is dropped.
        await catchUpInboxDelta()
        await openIdleChannel(password: password)
        await idleLoop()
    }

    private func catchUpInboxDelta() async {
        guard let sync = syncChannel, let inboxID else { return }
        try? await delta(folderID: inboxID, channel: sync, notify: true)
    }

    private func waitUntilWalksSettle() async {
        while !stopping && !Task.isCancelled {
            if backfillPassFinished { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func folderHasMessages(_ record: FolderRecord) async -> Bool {
        (try? await store.fetchFolderSummary(record.id))?.totalCount ?? 0 > 0
    }

    private func openIdleChannel(password: String) async {
        guard idleChannel == nil else { return }
        let idleClient = clientFactory.makeClient(
            endpoint: config.imap,
            username: config.username,
            password: password
        )
        let idle = SyncChannel(client: idleClient)
        do {
            try await idle.connect()
            idleChannel = idle
            dualConnection = true
        } catch {
            await idle.close()
            dualConnection = false
            idleChannel = nil
            if SyncPolicy.isConnectionCap(error) {
                await logSync("single-connection fallback", detail: String(describing: error))
            } else {
                await logSync("idle connect failed; multiplex", detail: String(describing: error))
            }
        }
    }

    private func idleLoop() async {
        let caps = await syncChannel?.capabilities()
        guard caps?.idle == true else { return }
        guard let inboxID, var record = folders[inboxID] else { return }
        let channel = dualConnection ? (idleChannel ?? syncChannel) : syncChannel
        guard let channel else { return }
        while !stopping && !Task.isCancelled {
            do {
                let selected = try await channel.select(record.path)
                if let latest = folders[inboxID] { record = latest }
                let uidNext = selected.uidNext ?? record.lastUidNext
                if selected.uidValidity != record.generation.uidValidity
                    || uidNext > record.lastUidNext
                    || !selected.vanished.isEmpty
                    || !selected.vanishedEarlier.isEmpty
                {
                    if let sync = syncChannel {
                        try await delta(folderID: inboxID, channel: sync, notify: true)
                        if let latest = folders[inboxID] { record = latest }
                    }
                }
                let idle = try await channel.beginIdle()
                let outcome = await waitIdle(idle)
                try await channel.leaveIdle()
                switch outcome {
                case .bye:
                    sessionBroken = true
                    return
                case .hint, .wake, .renew:
                    if outcome == .hint {
                        try? await Task.sleep(for: settings.hintDebounce)
                    }
                    if let sync = syncChannel {
                        try await delta(folderID: inboxID, channel: sync, notify: true)
                    }
                case .cancel:
                    if stopping || Task.isCancelled { return }
                    // IDLE event stream ended without a mailbox hint. Back off
                    // so a dead idle socket cannot spin the run loop.
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if let latest = folders[inboxID] { record = latest }
            } catch is CancellationError {
                return
            } catch {
                if stopping { return }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private enum IdleOutcome: Sendable { case hint, renew, wake, bye, cancel }

    private func waitIdle(_ idle: IMAPIdle) async -> IdleOutcome {
        let pulse = refreshPulse
        let renewal = settings.idleRenewal
        return await withTaskGroup(of: IdleOutcome.self) { group in
            group.addTask {
                for await event in idle.events {
                    switch event {
                    case .bye: return .bye
                    case .exists, .expunge, .vanished, .vanishedEarlier, .fetchHint:
                        return .hint
                    }
                }
                return .cancel
            }
            group.addTask {
                try? await Task.sleep(for: renewal)
                return .renew
            }
            group.addTask {
                while !Task.isCancelled {
                    if await self.stopping { return .cancel }
                    if await self.refreshPulse != pulse { return .wake }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return .cancel
            }
            let first = await group.next() ?? .cancel
            group.cancelAll()
            return first
        }
    }

    private func periodicLoop() async {
        while !stopping && !Task.isCancelled {
            try? await Task.sleep(for: settings.periodicTick)
            if stopping { return }
            guard let channel = syncChannel else { continue }
            // INBOX live mail must not wait for every folder walk to finish.
            // IDLE only starts after backfillPassFinished; without this,
            // APPEND/EXISTS during the 100k walk is never ingested.
            if let inboxID, !dualConnection || !backfillPassFinished {
                try? await delta(folderID: inboxID, channel: channel, notify: true)
            }
            if !backfillPassFinished { continue }
            let now = clock()
            for record in folders.values where record.role != .inbox {
                let interval = SyncPolicy.isSpecialUse(record.role)
                    ? settings.specialUseDelta
                    : settings.otherFolderDelta
                if now.timeIntervalSince(record.lastDeltaAt) >= durationSeconds(interval) {
                    try? await delta(folderID: record.id, channel: channel, notify: true)
                }
            }
            for record in SyncPolicy.sortFolders(Array(folders.values)) {
                if stopping { return }
                if let state = try? await store.fetchSyncState(for: record.generation),
                   state.backfillPhase != .complete {
                    _ = await syncFolderHistory(folderID: record.id)
                } else {
                    await activateIfReplacementComplete(folderID: record.id)
                }
            }
        }
    }

    private func stillCurrentGeneration(
        _ captured: MailboxGeneration,
        folder: FolderID
    ) -> Bool {
        folders[folder]?.generation == captured
    }

    /// Test seam: UIDVALIDITY replacement mid-FETCH updates this map from another
    /// engine task. Production only writes it in prepare/maybeReplace.
    func adoptFolderGenerationForTesting(_ folder: FolderID, _ generation: MailboxGeneration) {
        guard var record = folders[folder] else { return }
        record.generation = generation
        record.isReplacement = true
        folders[folder] = record
    }
    /// Test seam: simulate an expunge revision arriving while a FETCH is in
    /// flight, without relying on scheduler timing to run a second SELECT.
    func bumpExpungeRevisionForTesting(_ folder: FolderID) {
        expungeRevision[folder, default: 0] &+= 1
    }



    private func seenLoop() async {
        while !stopping && !Task.isCancelled {
            if let channel = syncChannel {
                try? await drainFlags(channel: channel)
                try? await drainMove(channel: channel)
            }
            try? await Task.sleep(for: settings.seenPoll)
        }
    }

    private func drainFlags(channel: SyncChannel) async throws {
        let ops = try await store.snapshotFlagQueue(limit: 32)
        for op in ops {
            if stopping { return }
            try Task.checkCancellation()
            let live = try await store.liveGeneration(for: op.folder)
            if live?.uidValidity != op.uidValidity {
                try await store.dropStaleFlag(folder: op.folder)
                try await store.dropStaleMove(folder: op.folder)
                continue
            }
            guard let summary = try await store.fetchFolderSummary(op.folder) else {
                try await store.dropFlag(op, reason: "folder missing")
                continue
            }
            do {
                let liveNow = try await store.liveGeneration(for: op.folder)
                if liveNow?.uidValidity != op.uidValidity {
                    try await store.dropStaleFlag(folder: op.folder)
                    try await store.dropStaleMove(folder: op.folder)
                    continue
                }
                try await channel.storeFlags(
                    in: summary.path,
                    expectedUIDValidity: op.uidValidity,
                    uids: IMAPUIDSet(uid: op.uid.rawValue),
                    flag: op.flag,
                    set: op.set
                )
                try await store.dequeueFlag(op)
            } catch SyncChannelError.staleMailbox {
                try await store.dropFlag(op, reason: "stale UIDVALIDITY")
            } catch let error as IMAPError {
                if error.isTaggedNO || error.isTaggedBAD {
                    try await store.dropFlag(op, reason: error.description)
                } else {
                    throw error
                }
            }
        }
    }

 
    private func drainMove(channel: SyncChannel) async throws {
        let ops = try await store.snapshotMoveQueue(limit: 32)
        for op in ops {
            if stopping { return }
            try Task.checkCancellation()
            let live = try await store.liveGeneration(for: op.folder)
            if live?.uidValidity != op.uidValidity {
                try await store.dropStaleMove(folder: op.folder)
                continue
            }
            guard let source = try await store.fetchFolderSummary(op.folder) else {
                try await discardMove(op, reason: "folder missing")
                continue
            }
            let destinationName = op.destination.rawValue.capitalized
            guard let target = folders.values.first(where: { $0.role == op.destination }) else {
                try await discardMove(op, reason: "no \(destinationName) folder")
                continue
            }
            // Keep the gate over the whole server sequence (and its local
            // acknowledgement), so stop cannot close the channel between
            // fallback phases.
            guard !stopping else { return }
            beginWriteOperation()
            defer { endWriteOperation() }
            let capabilities = await channel.capabilities()
            let useMove = !op.copied && capabilities.move
            var phase = useMove ? "MOVE" : (op.copied ? "STORE" : "COPY")
            do {
                let liveNow = try await store.liveGeneration(for: op.folder)
                if liveNow?.uidValidity != op.uidValidity {
                    try await store.dropStaleMove(folder: op.folder)
                    continue
                }
                let uids = IMAPUIDSet(uid: op.uid.rawValue)
                if useMove {
                    try await channel.archiveMove(
                        in: source.path,
                        expectedUIDValidity: op.uidValidity,
                        uids: uids,
                        destination: target.path
                    )
                } else {
                    if !op.copied {
                        phase = "COPY"
                        try await channel.archiveCopy(
                            in: source.path,
                            expectedUIDValidity: op.uidValidity,
                            uids: uids,
                            destination: target.path
                        )
                        try await store.markMoveCopied(op)
                    }
                    phase = "STORE"
                    try await channel.archiveStoreDeleted(
                        in: source.path,
                        expectedUIDValidity: op.uidValidity,
                        uids: uids
                    )
                    phase = "EXPUNGE"
                    try await channel.archiveExpunge(
                        in: source.path,
                        expectedUIDValidity: op.uidValidity,
                        uids: uids
                    )
                }
                expungeRevision[op.folder, default: 0] &+= 1
                try await store.deleteMoveOp(op)
            } catch SyncChannelError.staleMailbox {
                try await store.dropStaleMove(folder: op.folder)
                try await store.deleteMoveOp(op)
            } catch let error as IMAPError {
                if error.isTaggedNO || error.isTaggedBAD {
                    if useMove || phase == "COPY" {
                        try await discardMove(op, reason: error.description)
                    } else {
                        try await retainMove(
                            op,
                            phase: phase,
                            reason: error.description
                        )
                    }
                } else {
                    throw error
                }
            }
        }
    }

    private func discardMove(_ op: MoveOp, reason: String) async throws {
        try await store.deleteMoveOp(op)
        try await store.recordError(StoreLogEntry(
            kind: .archive,
            account: op.account,
            folder: op.folder,
            generation: MailboxGeneration(folder: op.folder, uidValidity: op.uidValidity),
            uid: op.uid,
            message: reason
        ))
    }

    private func retainMove(
        _ op: MoveOp,
        phase: String,
        reason: String
    ) async throws {
        try await store.recordError(StoreLogEntry(
            kind: .archive,
            account: op.account,
            folder: op.folder,
            generation: MailboxGeneration(folder: op.folder, uidValidity: op.uidValidity),
            uid: op.uid,
            message: "uid \(op.uid.rawValue) phase \(phase): \(reason)"
        ))
    }
    private func cleanupLoop() async {
        while !stopping && !Task.isCancelled {
            do {

                var deleted: Int
                repeat {
                    deleted = try await store.cleanupRetiredGenerations(batchSize: 200)
                } while deleted > 0 && !stopping
            } catch {
                await logSync("retired cleanup", detail: String(describing: error))
            }
            try? await Task.sleep(for: settings.cleanupTick)
        }
    }

    private func logSync(_ message: String, detail: String? = nil, folder: FolderID? = nil) async {
        if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
            let extra = detail.map { " " + $0 } ?? ""
            let line = "[mailternal-qa] sync " + message + extra + "\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
        try? await store.recordError(StoreLogEntry(
            kind: .sync,
            account: config.id,
            folder: folder,
            message: message,
            detail: detail
        ))
    }
}

private func durationSeconds(_ duration: Duration) -> TimeInterval {
    let c = duration.components
    return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
}

