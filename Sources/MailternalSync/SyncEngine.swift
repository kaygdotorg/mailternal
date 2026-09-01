import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore

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
    private var setupDecided = false
    private var sampleTextBytes: Int64 = 0
    private var sampleCount = 0
    private var inboxExists = 0
    private var notified: Set<NotificationKey> = []
    private var statusWaiters: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var mailWaiters: [UUID: AsyncStream<NewMailEvent>.Continuation] = [:]
    private var reconnectAttempt = 0
    private var refreshPulse: Int = 0
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
    ///   spacious synthetic volume so a nearly-full host (reserve = max(5 GiB,
    ///   10% of volume)) cannot halt INBOX backfill. Production callers omit this.
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

    public func fetchPart(message: MessageID, part: String) async throws -> URL {
        try ensureRunning()
        guard let ref = try await store.messageRef(message) else {
            throw SyncEngineError.messageNotFound
        }
        guard let summary = try await store.fetchFolderSummary(ref.folder) else {
            throw SyncEngineError.folderNotFound
        }
        guard let channel = syncChannel else { throw SyncEngineError.stopped }
        _ = try await channel.select(summary.path)
        let fetched = try await channel.fetch(
            .peek(uids: IMAPUIDSet(uid: ref.uid.rawValue), section: .part(part))
        )
        guard let data = fetched.first?.parts.first(where: {
            $0.specifier == part || $0.specifier.uppercased() == part.uppercased()
        })?.data ?? fetched.first?.parts.first?.data, !data.isEmpty else {
            throw SyncEngineError.partMissing
        }
        let stored = try await store.putAttachment(data: data)
        return stored.url
    }

    public func rawSource(message: MessageID) async throws -> String {
        try ensureRunning()
        guard let ref = try await store.messageRef(message) else {
            throw SyncEngineError.messageNotFound
        }
        guard let summary = try await store.fetchFolderSummary(ref.folder) else {
            throw SyncEngineError.folderNotFound
        }
        guard let channel = syncChannel else { throw SyncEngineError.stopped }
        _ = try await channel.select(summary.path)
        let section = IMAPPeekSection(specifier: "", binary: false, origin: 0, length: SyncPolicy.rawSourceCap)
        let fetched = try await channel.fetch(
            IMAPFetchRequest(uids: IMAPUIDSet(uid: ref.uid.rawValue), uid: true, peek: [section])
        )
        let data = fetched.first?.parts.first?.data ?? Data()
        return MessageAssembler.escapeRaw(data)
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

    private func runLoop() async {
        while !stopping && !Task.isCancelled {
            do {
                try await session()
            } catch is CancellationError {
                break
            } catch {
                await logSync("session ended", detail: String(describing: error))
            }
            await teardown()
            connected = false
            publishStatus(online: false)
            if stopping || Task.isCancelled { break }
            reconnectAttempt += 1
            let delay = IMAPReconnectBackoff().delay(forAttempt: reconnectAttempt)
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
        publishStatus(online: true)

        try await enablePreferredExtensions(channel: sync)
        try await discover(channel: sync)
        try await deltaAll(channel: sync, notify: true)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.backfillAll() }
            group.addTask { await self.idleAfterInboxBackfill(password: password) }
            group.addTask { await self.periodicLoop() }
            group.addTask { await self.seenLoop() }
            group.addTask { await self.cleanupLoop() }
            group.addTask { await self.watchBye() }
            while !self.stopping && !self.sessionBroken && !Task.isCancelled {
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
        guard caps.qresync else {
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
        for mailbox in discovery.folders {
            let folderID = try await store.upsertFolder(
                account: config.id,
                path: mailbox.path,
                name: mailbox.name,
                role: mailbox.role,
                objectID: mailbox.mailboxID
            )
            let record = try await prepare(
                channel: channel,
                folderID: folderID,
                mailbox: mailbox,
                persistBaseline: mailbox.role == .inbox
            )
            records.append(record)
            if mailbox.role == .inbox { inboxID = folderID }
        }
        folders = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
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
        if mailbox.role == .inbox { inboxExists = selected.exists }

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
            isReplacement: isReplacement
        )
    }

    private func backfillAll() async {
        let ordered = SyncPolicy.sortFolders(Array(folders.values))
        for record in ordered {
            if stopping || Task.isCancelled { return }
            await syncFolderHistory(folderID: record.id)
        }
        if !stopping && !Task.isCancelled {
            backfillPassFinished = true
        }
    }

    /// Backfill, then atomically switch a replacement generation only once it is complete.
    private func syncFolderHistory(folderID: FolderID) async {
        await backfill(folderID: folderID)
        await activateIfReplacementComplete(folderID: folderID)
    }

    private func activateIfReplacementComplete(folderID: FolderID) async {
        guard folders[folderID]?.isReplacement == true else { return }
        guard let record = folders[folderID] else { return }
        guard let state = try? await store.fetchSyncState(for: record.generation),
              state.backfillPhase == .complete else { return }
        await activateReplacement(folderID: folderID)
    }

    private func backfill(folderID: FolderID) async {
        guard var record = folders[folderID], let channel = syncChannel else { return }
        do {
            var state = try await store.fetchSyncState(for: record.generation)
                ?? FolderSyncState(generation: record.generation, baselineUID: record.baseline)
            if state.backfillPhase == .complete { return }
            if state.backfillPhase == .halted {
                let snap = disk.snapshot(for: settings.diskURL)
                let reserve = SyncPolicy.reserveBytes(volumeBytes: snap.volumeBytes)
                if SyncPolicy.shouldResume(freeBytes: snap.freeBytes, reserveBytes: reserve) {
                    state.backfillPhase = .walking
                    state.haltedThrough = nil
                    try await store.saveSyncState(state)
                } else {
                    return
                }
            }

            let selected = try await channel.select(record.path)
            let previousGeneration = record.generation
            try await maybeReplace(selected: selected, record: &record)
            folders[folderID] = record
            if record.generation != previousGeneration {
                state = try await store.fetchSyncState(for: record.generation)
                    ?? FolderSyncState(generation: record.generation, baselineUID: record.baseline)
                if state.backfillPhase == .complete { return }
            }
            let uidNext = selected.uidNext ?? record.lastUidNext

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
                    return
                }

                guard let window = SyncPolicy.nextWindow(
                    uidNext: uidNext,
                    windowSize: settings.backfillWindowSize,
                    lowWater: state.lowWaterUID?.rawValue
                ) else {
                    state.backfillPhase = .complete
                    state.progress = 1
                    try await store.saveSyncState(state)
                    return
                }

                try await ingestWindow(
                    record: record,
                    window: window,
                    channel: channel,
                    notify: false,
                    accumulateSample: record.role == .inbox && !setupDecided
                )

                state.lowWaterUID = IMAPUID(rawValue: window.lowerBound)
                state.progress = SyncPolicy.backfillProgress(uidNext: uidNext, lowWater: state.lowWaterUID?.rawValue)
                try await store.saveSyncState(state)
                await maybeDecideSetup()
            }
        } catch is CancellationError {
            return
        } catch {
            await logSync("backfill \(record.path)", detail: String(describing: error), folder: folderID)
            if SyncPolicy.isTransport(error) {
                sessionBroken = true
            }
        }
    }

    private func ingestWindow(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        channel: SyncChannel,
        notify: Bool,
        accumulateSample: Bool
    ) async throws {
        let uidSet = IMAPUIDSet(window)
        let meta: [IMAPFetchedMessage]
        do {
            meta = try await channel.fetch(IMAPFetchRequest(
                uids: uidSet,
                envelope: true,
                bodyStructure: true,
                flags: true,
                internalDate: true,
                uid: true,
                peek: Self.speculativePeeks
            ))
        } catch {
            await logSync("window fetch \(record.path)", detail: String(describing: error), folder: record.id)
            if SyncPolicy.isTransport(error) { throw error }
            try await quarantineUnknown(record: record, window: window, channel: channel, reason: String(describing: error))
            return
        }

        if accumulateSample {
            for message in meta {
                if let structure = message.bodyStructure {
                    sampleTextBytes += MessageAssembler.textPartOctets(structure)
                    sampleCount += 1
                }
            }
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
                        let fetched = try await channel.fetch(IMAPFetchRequest(
                            uids: SyncPolicy.uidSet(uids: chunk),
                            uid: true,
                            peek: specifiers.map { IMAPPeekSection.part($0) }
                        ))
                        for message in fetched {
                            guard let uid = message.uid else { continue }
                            var parts = bodies[uid] ?? []
                            parts.append(contentsOf: message.parts)
                            bodies[uid] = parts
                        }
                    } catch {
                        await logSync("body peek \(record.path)", detail: String(describing: error), folder: record.id)
                        if SyncPolicy.isTransport(error) { throw error }
                    }
                }
            }
        }

        let generation = record.generation
        let now = clock()
        let cutoff = windowedSince
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
            if let cutoff, incoming.envelope.internalDate < cutoff {
                continue
            }
            built.append(incoming)
        }

        if built.isEmpty { return }
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

        _ = try await store.upsertMessages(built)

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
    }

    private func ingestNewUIDs(
        record: FolderRecord,
        from lo: UInt32,
        to hi: UInt32,
        channel: SyncChannel,
        notify: Bool
    ) async throws {
        var lowWater: UInt32? = nil
        let uidNext = hi < UInt32.max ? hi &+ 1 : hi
        while let window = SyncPolicy.nextWindow(
            uidNext: uidNext,
            windowSize: settings.backfillWindowSize,
            lowWater: lowWater
        ) {
            let start = max(window.lowerBound, lo)
            if start <= window.upperBound {
                try await ingestWindow(
                    record: record,
                    window: start...window.upperBound,
                    channel: channel,
                    notify: notify,
                    accumulateSample: false
                )
            }
            if window.lowerBound <= lo { break }
            lowWater = window.lowerBound
        }
    }

    private func quarantineUnknown(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        channel: SyncChannel,
        reason: String
    ) async throws {
        let flags: [IMAPFetchedMessage]
        do {
            flags = try await channel.fetch(.flags(uids: IMAPUIDSet(window)))
        } catch {
            return
        }
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
        if !incoming.isEmpty {
            _ = try await store.upsertMessages(incoming)
        }
    }

    private func maybeDecideSetup() async {
        guard !setupDecided, sampleCount > 0 else { return }
        let target = min(settings.setupSampleSize, max(inboxExists, 1))
        guard sampleCount >= target else { return }
        setupDecided = true
        let snap = disk.snapshot(for: settings.diskURL)
        let reserve = SyncPolicy.reserveBytes(volumeBytes: snap.volumeBytes)
        let text = SyncPolicy.extrapolatedTextBytes(
            sampleTextBytes: sampleTextBytes,
            sampleCount: sampleCount,
            messageCount: max(inboxExists, sampleCount)
        )
        let projected = SyncPolicy.projectedStoreBytes(textPartBytes: text)
        if SyncPolicy.shouldEnterWindowed(freeBytes: snap.freeBytes, projectedBytes: projected, reserveBytes: reserve) {
            let since = clock().addingTimeInterval(TimeInterval(-settings.windowedDays * 24 * 3600))
            windowedSince = since
            publishStatus(mode: .windowed(since: since))
        }
    }

    private func activateReplacement(folderID: FolderID) async {
        guard var record = folders[folderID] else { return }
        do {
            try await store.activateReplacementGeneration(folder: folderID)
            record.isReplacement = false
            folders[folderID] = record
            try await store.dropStaleSeen(folder: folderID)
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
            if selected.noModSeq {
                try await persistDowngrade(&record, reason: .noModSeq, channel: channel)
            }
            try await maybeReplace(selected: selected, record: &record)
            let vanished = selected.vanishedEarlier + selected.vanished
            if !vanished.isEmpty {
                _ = try await store.deleteUIDs(
                    generation: record.generation,
                    uids: vanished.map { IMAPUID(rawValue: $0) }
                )
            }
            if let mod = record.highestModseq, await folderHasMessages(record) {
                let flags = try await channel.fetch(.flagsChangedSince(
                    uids: SyncPolicy.knownUIDSet(uidNext: selected.uidNext ?? record.lastUidNext),
                    modSeq: mod
                ))
                try await applyFlagFetch(flags, record: record)
            }
        case .condstore:
            selected = try await channel.select(record.path)
            if selected.noModSeq {
                try await persistDowngrade(&record, reason: .noModSeq, channel: channel)
            }
            try await maybeReplace(selected: selected, record: &record)
            if let mod = record.highestModseq, await folderHasMessages(record) {
                let flags = try await channel.fetch(.flagsChangedSince(
                    uids: SyncPolicy.knownUIDSet(uidNext: selected.uidNext ?? record.lastUidNext),
                    modSeq: mod
                ))
                try await applyFlagFetch(flags, record: record)
            }
            try await reconcileExpunges(record: record, selected: selected, channel: channel)
        case .basic:
            selected = try await channel.select(record.path)
            try await maybeReplace(selected: selected, record: &record)
            try await reconcileExpunges(record: record, selected: selected, channel: channel)
        }

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
                    notify: notify && !record.isReplacement
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
            await backfill(folderID: record.id)
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
        channel: SyncChannel
    ) async throws {
        let uidNext = selected.uidNext ?? record.lastUidNext
        guard uidNext > 1 else {
            let stored = try await store.uids(in: record.generation, range: nil)
            if !stored.isEmpty {
                _ = try await store.deleteUIDs(generation: record.generation, uids: stored)
            }
            return
        }
        let range: ClosedRange<UInt32> = 1...(uidNext &- 1)
        let stored = try await store.uids(in: record.generation, range: range)
        if stored.isEmpty { return }
        let fetched = try await channel.fetch(.flags(uids: IMAPUIDSet(range)))
        let server = Set(fetched.compactMap(\.uid))
        let gone = stored.filter { !server.contains($0.rawValue) }
        if !gone.isEmpty {
            _ = try await store.deleteUIDs(generation: record.generation, uids: gone)
        }
        try await applyFlagFetch(fetched, record: record)
    }

    /// IDLE on a second connection while the sync connection is mid-FETCH
    /// can stall Dovecot/NIO (no tagged FETCH reply). Wait until every folder
    /// walk has settled, then open the idle socket so the 100k INBOX + Horrors
    /// backfill stays single-connection.
    private func idleAfterInboxBackfill(password: String) async {
        await waitUntilWalksSettle()
        if stopping || Task.isCancelled { return }
        await openIdleChannel(password: password)
        await idleLoop()
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
                _ = try await channel.select(record.path)
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
        await waitUntilWalksSettle()
        while !stopping && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if stopping { return }
            guard let channel = syncChannel else { continue }
            let now = clock()
            for record in folders.values where record.role != .inbox {
                let interval = SyncPolicy.isSpecialUse(record.role)
                    ? settings.specialUseDelta
                    : settings.otherFolderDelta
                if now.timeIntervalSince(record.lastDeltaAt) >= durationSeconds(interval) {
                    try? await delta(folderID: record.id, channel: channel, notify: true)
                }
            }
            if !dualConnection, let inboxID {
                try? await delta(folderID: inboxID, channel: channel, notify: true)
            }
            for record in SyncPolicy.sortFolders(Array(folders.values)) {
                if stopping { return }
                if let state = try? await store.fetchSyncState(for: record.generation),
                   state.backfillPhase != .complete {
                    await syncFolderHistory(folderID: record.id)
                } else {
                    await activateIfReplacementComplete(folderID: record.id)
                }
            }
        }
    }

    private func seenLoop() async {
        while !stopping && !Task.isCancelled {
            if let channel = syncChannel {
                try? await drainSeen(channel: channel)
            }
            try? await Task.sleep(for: settings.seenPoll)
        }
    }

    private func drainSeen(channel: SyncChannel) async throws {
        let ops = try await store.snapshotSeenQueue(limit: 32)
        for op in ops {
            if stopping { return }
            try Task.checkCancellation()
            let live = try await store.liveGeneration(for: op.folder)
            if live?.uidValidity != op.uidValidity {
                try await store.dropStaleSeen(folder: op.folder)
                continue
            }
            guard let summary = try await store.fetchFolderSummary(op.folder) else {
                try await store.dropSeen(op, reason: "folder missing")
                continue
            }
            do {
                _ = try await channel.select(summary.path)
                try await channel.storeSeen(uids: IMAPUIDSet(uid: op.uid.rawValue))
                try await store.dequeueSeen(op)
            } catch let error as IMAPError {
                if error.isTaggedNO || error.isTaggedBAD {
                    try await store.dropSeen(op, reason: error.description)
                } else {
                    throw error
                }
            }
        }
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
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func logSync(_ message: String, detail: String? = nil, folder: FolderID? = nil) async {
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
