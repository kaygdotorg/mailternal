import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalMIME
import MailternalStore
/// Process-wide FIFO permit pool for connections that participate in
/// backfill. A single pool is shared by every `SyncEngine` owned by the
/// application, so account count cannot multiply the connection budget.
public actor BackfillConnectionBudget {
    package struct Lease: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let owner: AccountID
    }

    public struct Snapshot: Sendable, Equatable {
        public let active: Int
        public let peak: Int
        public let waiting: Int
        public let activeByOwner: [AccountID: Int]

        fileprivate init(
            active: Int,
            peak: Int,
            waiting: Int,
            activeByOwner: [AccountID: Int]
        ) {
            self.active = active
            self.peak = peak
            self.waiting = waiting
            self.activeByOwner = activeByOwner
        }
    }

    public static let shared = BackfillConnectionBudget(
        capacity: SyncPolicy.globalBackfillConnections
    )

    private struct Waiter {
        let id: UUID
        let owner: AccountID
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private let capacity: Int
    private var active = 0
    private var peak = 0
    private var activeLeases: Set<UUID> = []
    private var activeByOwner: [AccountID: Int] = [:]
    private var lastGrantedOwner: AccountID?
    private var waiters: [Waiter] = []
    /// Keep one permit available for an account that joins after another
    /// account has started its workers. `maxBackfillConnections` is three.
    private var ownerLimit: Int { max(1, capacity - 1) }

    public init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    /// Acquires permits in FIFO order. When several accounts are queued, the
    /// next permit prefers an owner different from the owner most recently
    /// granted, preventing one account's reconnect loop from monopolizing the
    /// shared pool.
    package func acquire(owner: AccountID) async -> Lease? {
        let requestID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if waiters.isEmpty,
                   active < capacity,
                   activeByOwner[owner, default: 0] < ownerLimit {
                    continuation.resume(returning: issueLease(owner: owner))
                } else {
                    waiters.append(Waiter(
                        id: requestID,
                        owner: owner,
                        continuation: continuation
                    ))
                    drainWaiters()
                }
            }
        }, onCancel: {
            Task { await self.cancel(requestID) }
        })
    }

    package func release(_ lease: Lease) {
        guard activeLeases.remove(lease.id) != nil else { return }
        active = max(0, active - 1)
        activeByOwner[lease.owner] = max(0, (activeByOwner[lease.owner] ?? 1) - 1)
        if activeByOwner[lease.owner] == 0 {
            activeByOwner[lease.owner] = nil
        }
        drainWaiters()
    }

    package func snapshot() -> Snapshot {
        Snapshot(
            active: active,
            peak: peak,
            waiting: waiters.count,
            activeByOwner: activeByOwner
        )
    }

    private func issueLease(owner: AccountID) -> Lease {
        let lease = Lease(id: UUID(), owner: owner)
        activeLeases.insert(lease.id)
        active += 1
        peak = max(peak, active)
        activeByOwner[owner, default: 0] += 1
        lastGrantedOwner = owner
        return lease
    }

    private func drainWaiters() {
        while active < capacity, !waiters.isEmpty {
            let alternate = waiters.firstIndex {
                $0.owner != lastGrantedOwner
                    && activeByOwner[$0.owner, default: 0] < ownerLimit
            }
            let eligible = waiters.firstIndex {
                activeByOwner[$0.owner, default: 0] < ownerLimit
            }
            guard let index = alternate ?? eligible else { break }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: issueLease(owner: waiter.owner))
        }
    }

    private func cancel(_ requestID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == requestID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}

struct BackfillJob: Sendable {
    let id: FolderID
    let path: String
    let role: FolderRole
}

/// Actor-isolated priority queue shared by the bounded backfill workers.
/// Queue ownership is separate from engine state so ON/OFF transitions can
/// wake a waiting worker or cancel a queued job without polling.
actor FolderBackfillScheduler {
    private var jobs: [FolderID: BackfillJob]
    private var queue: [FolderID] = []
    private var queued: Set<FolderID> = []
    private var running: Set<FolderID> = []
    private var requeueOnFinish: Set<FolderID> = []
    private var enabled: Set<FolderID>
    private var initialOutstanding: Set<FolderID>
    private var visibleFolder: FolderID?
    private var stopped = false
    private var waiters: [CheckedContinuation<FolderID?, Never>] = []

    init(jobs: [BackfillJob], enabled: Set<FolderID>) {
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        self.jobs = jobsByID
        self.enabled = enabled
        self.initialOutstanding = enabled
        let initialQueue = enabled.filter { jobsByID[$0] != nil }
        self.queue = Array(initialQueue)
        self.queued = Set(initialQueue)
    }

    func setVisibleFolder(_ id: FolderID?) {
        visibleFolder = id
        sortQueue()
        signalWaiters()
    }

    func setEnabled(_ id: FolderID, _ isEnabled: Bool) {
        guard !stopped else { return }
        if isEnabled {
            enabled.insert(id)
            if running.contains(id) {
                requeueOnFinish.insert(id)
            } else {
                enqueueIfNeeded(id)
            }
        } else {
            enabled.remove(id)
            requeueOnFinish.remove(id)
            queued.remove(id)
            queue.removeAll { $0 == id }
        }
        sortQueue()
        signalWaiters()
    }

    func next() async -> FolderID? {
        if stopped { return nil }
        if let id = dequeue() { return id }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if stopped {
                    continuation.resume(returning: nil)
                } else if let id = dequeue() {
                    continuation.resume(returning: id)
                } else {
                    waiters.append(continuation)
                }
            }
        }, onCancel: {
            Task { await self.stop() }
        })
    }

    func finish(_ id: FolderID, completed: Bool) {
        running.remove(id)
        initialOutstanding.remove(id)
        let shouldRequeue = requeueOnFinish.remove(id) != nil
        if shouldRequeue, enabled.contains(id), !completed {
            enqueueIfNeeded(id)
        }
        signalWaiters()
    }

    func initialPassComplete() -> Bool {
        initialOutstanding.isEmpty
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        queue.removeAll()
        queued.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
    }

    private func enqueueIfNeeded(_ id: FolderID) {
        guard enabled.contains(id), !queued.contains(id), !running.contains(id),
              jobs[id] != nil else { return }
        queued.insert(id)
        queue.append(id)
    }

    private func dequeue() -> FolderID? {
        guard !queue.isEmpty else { return nil }
        sortQueue()
        let id = queue.removeFirst()
        queued.remove(id)
        running.insert(id)
        return id
    }

    private func sortQueue() {
        queue.sort { lhs, rhs in
            guard let a = jobs[lhs], let b = jobs[rhs] else { return lhs.rawValue < rhs.rawValue }
            let ar = rank(a)
            let br = rank(b)
            if ar != br { return ar < br }
            if a.path != b.path {
                return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
            }
            return a.id.rawValue < b.id.rawValue
        }
    }

    private func rank(_ job: BackfillJob) -> Int {
        if job.role == .inbox { return 0 }
        if job.id == visibleFolder { return 1 }
        return SyncPolicy.isSpecialUse(job.role) ? 2 : 3
    }

    private func signalWaiters() {
        while !waiters.isEmpty, let id = dequeue() {
            waiters.removeFirst().resume(returning: id)
        }
    }
}

private enum BackfillAttemptResult: Equatable {
    case committed
    case invalidated
    case halted
}

private struct MetadataWindowFetchFailure: Error {
    let underlying: Error

    var reason: String { String(describing: underlying) }
}

private struct WindowIngestResult {
    let result: BackfillAttemptResult
    let channel: SyncChannel
}

private struct BackfillAttempt {
    let result: BackfillAttemptResult
    let channel: SyncChannel
}

public actor SyncEngine {
    private let store: MailStore
    private let config: AccountConfig
    private let credentials: any IMAPCredentialProvider
    private let clientFactory: any IMAPClientFactory
    private let disk: any DiskSpaceProviding
    private let clock: @Sendable () -> Date
    private let settings: SyncSettings
    private let backfillBudget: BackfillConnectionBudget

    private var runTask: Task<Void, Never>?
    private var stopping = false
    private var connected = false
    private var backfillTasks: [FolderID: Task<BackfillAttempt, Never>] = [:]
    private var sessionBroken = false
    private var backfillPassFinished = false
    private var dualConnection = false
    private var syncChannel: SyncChannel?
    private var idleChannel: SyncChannel?
    private var backfillChannels: [SyncChannel] = []
    private var syncLease: BackfillConnectionBudget.Lease?
    private var backfillLeases: [ObjectIdentifier: BackfillConnectionBudget.Lease] = [:]
    private var backfillScheduler: FolderBackfillScheduler?
    /// Learned per session after a provider rejects a new connection.
    private var backfillConnectionCap: Int?
    private var visibleFolderID: FolderID?
    private var folders: [FolderID: FolderRecord] = [:]
    private var inboxID: FolderID?
    private var currentStatus = SyncStatus(mode: .fullHistory, isOnline: false)
    private var windowedSince: Date?
    private var notified: Set<NotificationKey> = []
    private var statusWaiters: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var activityWaiters: [UUID: AsyncStream<FolderActivityUpdate>.Continuation] = [:]
    private var currentActivities: [FolderID: FolderActivity] = [:]
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
    private var folderRenameInFlight: Set<FolderID> = []
    /// Store folder rows can become visible during the initial LIST pass. Do
    /// not let a UI wake race that pass and mistake an as-yet-unprepared row
    /// for a retired folder.
    private var discoveryReady = false

    /// Backfill PEEK bodies are fetched one UID/section at a time. The request
    /// limits and aggregate window budget live in `SyncPolicy`.

    /// - Parameter qaAmpleDisk: QA/testing only. When `true`, disk policy sees a
    ///   spacious synthetic volume so a nearly-full host cannot halt INBOX
    ///   backfill. Production callers omit this.
    public init(
        store: MailStore,
        config: AccountConfig,
        credentials: any IMAPCredentialProvider,
        qaAmpleDisk: Bool = false,
        backfillBudget: BackfillConnectionBudget = BackfillConnectionBudget(
            capacity: 4
        )
    ) {
        self.init(
            store: store,
            config: config,
            credentials: credentials,
            clientFactory: LiveIMAPClientFactory(),
            disk: qaAmpleDisk ? AmpleDiskSpace() : FileDiskSpace(),
            clock: { Date() },
            settings: .production,
            backfillBudget: backfillBudget
        )
    }

    /// Test/LiveWiring seam: inject a scripted IMAP client without exposing disk policy.
    package init(
        store: MailStore,
        config: AccountConfig,
        credentials: any IMAPCredentialProvider,
        clientFactory: any IMAPClientFactory,
        qaAmpleDisk: Bool = false,
        backfillBudget: BackfillConnectionBudget = BackfillConnectionBudget(
            capacity: 4
        )
    ) {
        self.init(
            store: store,
            config: config,
            credentials: credentials,
            clientFactory: clientFactory,
            disk: qaAmpleDisk ? AmpleDiskSpace() : FileDiskSpace(),
            clock: { Date() },
            settings: .production,
            backfillBudget: backfillBudget
        )
    }
    init(
        store: MailStore,
        config: AccountConfig,
        credentials: any IMAPCredentialProvider,
        clientFactory: any IMAPClientFactory,
        disk: any DiskSpaceProviding,
        clock: @escaping @Sendable () -> Date,
        settings: SyncSettings,
        backfillBudget: BackfillConnectionBudget = BackfillConnectionBudget(
            capacity: 4
        )
    ) {
        self.store = store
        self.config = config
        self.credentials = credentials
        self.clientFactory = clientFactory
        self.disk = disk
        self.clock = clock
        self.settings = settings
        self.backfillBudget = backfillBudget
    }
    public func start() async {
        guard runTask == nil else { return }
        stopping = false
        runTask = Task { await self.runLoop() }
    }
    public func stop() async {
        stopping = true
        await backfillScheduler?.stop()
        for task in backfillTasks.values {
            task.cancel()
        }
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

    public func reportVisibleFolder(_ folder: FolderID?) async {
        visibleFolderID = folder
        await backfillScheduler?.setVisibleFolder(folder)
    }

    /// Applies a local-retention transition to the in-memory scheduler. The
    /// facade persists the flag first; this method only coordinates running
    /// work and keeps already-indexed rows intact.
    public func setKeepLocally(_ keep: Bool, for folder: FolderID) async {
        guard var record = folders[folder] else { return }
        record.keepLocally = keep
        folders[folder] = record

        if !keep {
            backfillTasks[folder]?.cancel()
        }
        await backfillScheduler?.setEnabled(folder, keep)

        guard !keep,
              var state = try? await store.fetchSyncState(for: record.generation),
              state.backfillPhase == .walking
    else { return }
        state.backfillPhase = .idle
        try? await store.saveSyncState(state)
    }
    /// Runs the durable mutation drain immediately, then reconciles the
    /// affected folders. User moves must not wait for `seenPoll` or the
    /// periodic mailbox tick.
    public func refreshNow() async {
        refreshPulse &+= 1
        guard connected, discoveryReady, let channel = syncChannel else { return }
        do {
            let renamed = try await drainFolderRenames(channel: channel)
            if renamed {
                try await discover(channel: channel)
            }
            try await drainFlags(channel: channel)
            let movedFolders = try await drainMove(channel: channel)
            for folderID in movedFolders.sorted(by: { $0.rawValue < $1.rawValue }) {
                if stopping { return }
                try await delta(folderID: folderID, channel: channel, notify: true)
            }
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
    /// Per-folder activity used by the sidebar accessory. A stream is separate
    /// from `status` because several folders can be downloading concurrently.
    public var activity: AsyncStream<FolderActivityUpdate> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { _ in
                Task { await self.dropActivity(id) }
            }
            addActivity(id, continuation)
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
    private func addActivity(
        _ id: UUID,
        _ continuation: AsyncStream<FolderActivityUpdate>.Continuation
    ) {
        activityWaiters[id] = continuation
        for (folder, activity) in currentActivities {
            continuation.yield(FolderActivityUpdate(folder: folder, activity: activity))
        }
    }

    private func dropActivity(_ id: UUID) {
        activityWaiters.removeValue(forKey: id)
    }

    private func publishActivity(_ activity: FolderActivity, for folder: FolderID) {
        currentActivities[folder] = activity
        let update = FolderActivityUpdate(folder: folder, activity: activity)
        for continuation in activityWaiters.values {
            continuation.yield(update)
        }
    }


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
        discoveryReady = false
        backfillPassFinished = false
        try await store.upsertAccount(config)
        let password = try await credentials.password(for: config.id)
        guard let lease = await backfillBudget.acquire(owner: config.id) else {
            throw CancellationError()
        }
        syncLease = lease
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
            await backfillBudget.release(lease)
            syncLease = nil
            throw error
        }
        syncChannel = sync

        dualConnection = false
        idleChannel = nil
        backfillChannels = [sync]
        backfillLeases.removeAll()
        backfillScheduler = nil
        backfillTasks.removeAll()
        backfillConnectionCap = nil
        // Reserve the dedicated INBOX IDLE socket before discovery/backfill.
        // A provider cap only reduces the backfill pool; it never delays
        // discovery or makes local retention unavailable.
        await openIdleChannel(password: password)

        connected = true
        reconnectAttempt = 0
        lastFailure = nil
        publishStatus(online: true)

        try await enablePreferredExtensions(channel: sync)
        try await discover(channel: sync)
        discoveryReady = true
        let renamed = try await drainFolderRenames(channel: sync)
        if renamed {
            try await discover(channel: sync)
        }
        await openBackfillConnections(password: password)
        try await deltaAll(channel: sync, notify: true)
        try await repairLegacyIncompleteBackfills()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.backfillAll() }
            group.addTask { await self.idleLoop() }
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
        let extras = Array(backfillChannels.dropFirst())
        let leases = backfillLeases
        let primaryLease = syncLease
        idleChannel = nil
        syncChannel = nil
        backfillChannels.removeAll()
        backfillLeases.removeAll()
        syncLease = nil
        if let scheduler = backfillScheduler {
            await scheduler.stop()
        }
        backfillScheduler = nil
        backfillTasks.removeAll()
        if let idle { await idle.close() }
        for channel in extras {
            await channel.close()
            if let lease = leases[ObjectIdentifier(channel)] {
                await backfillBudget.release(lease)
            }
        }
        if let sync {
            await sync.close()
            if let primaryLease {
                await backfillBudget.release(primaryLease)
            }
        }
        dualConnection = false
        folderRenameInFlight.removeAll()
        discoveryReady = false
        sessionBroken = false
        qresyncEnabled = false
        backfillConnectionCap = nil
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
        try await store.updateServerMessageCount(selected.exists, for: folderID)
        let keepLocally = try await store.fetchFolderSummary(folderID)?.keepLocally
            ?? (mailbox.role != .none)
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
        if !keepLocally, state.backfillPhase == .walking {
            state.backfillPhase = .idle
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
            keepLocally: keepLocally,
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
        let jobs = ordered.map {
            BackfillJob(id: $0.id, path: $0.path, role: $0.role)
        }
        let enabled = Set(ordered.filter(\.keepLocally).map(\.id))
        let scheduler = FolderBackfillScheduler(jobs: jobs, enabled: enabled)
        backfillScheduler = scheduler
        await scheduler.setVisibleFolder(visibleFolderID)
        if enabled.isEmpty {
            backfillPassFinished = true
        }

        let channels = backfillChannels
        guard !channels.isEmpty else {
            await scheduler.stop()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask {
                    await self.backfillWorker(channel: channel, scheduler: scheduler)
                }
            }
            while !stopping && !sessionBroken && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            await scheduler.stop()
            group.cancelAll()
        }
    }

    private func backfillWorker(
        channel: SyncChannel,
        scheduler: FolderBackfillScheduler
    ) async {
        var activeChannel = channel
        while !stopping && !sessionBroken && !Task.isCancelled {
            guard let folderID = await scheduler.next() else { return }
            let taskChannel = activeChannel
            let task = Task {
                await self.runBackfillWithRetries(folderID: folderID, channel: taskChannel)
            }

            backfillTasks[folderID] = task
            let attempt = await task.value
            activeChannel = attempt.channel
            if backfillTasks[folderID] != nil {
                backfillTasks.removeValue(forKey: folderID)
            }
            var complete = false
            if attempt.result == .committed, let record = folders[folderID], record.keepLocally,
               let state = try? await store.fetchSyncState(for: record.generation) {
                complete = state.backfillPhase == .complete
            }
            await scheduler.finish(folderID, completed: complete)
            if await scheduler.initialPassComplete() {
                backfillPassFinished = true
            }
        }
    }

    private func runBackfillWithRetries(
        folderID: FolderID,
        channel: SyncChannel
    ) async -> BackfillAttempt {
        var retries = 0
        var activeChannel = channel
        while !stopping && !Task.isCancelled {
            let before = expungeRevision[folderID, default: 0]
            let attempt = await syncFolderHistory(folderID: folderID, channel: activeChannel)
            activeChannel = attempt.channel
            let after = expungeRevision[folderID, default: 0]
            let state: FolderSyncState?
            if let current = folders[folderID] {
                state = try? await store.fetchSyncState(for: current.generation)
            } else {
                state = nil
            }
            let retry = attempt.result == .invalidated
                && !stopping
                && !Task.isCancelled
                && !sessionBroken
                && folders[folderID]?.keepLocally == true
                && state?.backfillPhase == .walking
                && after != before
                && retries < 3
            guard retry else { return attempt }
            retries += 1
        }
        return BackfillAttempt(result: .halted, channel: activeChannel)
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
    private func syncFolderHistory(
        folderID: FolderID,
        channel: SyncChannel
    ) async -> BackfillAttempt {
        let attempt = await backfill(folderID: folderID, channel: channel)
        await activateIfReplacementComplete(folderID: folderID)
        return attempt
    }

    private func activateIfReplacementComplete(folderID: FolderID) async {
        guard folders[folderID]?.isReplacement == true else { return }
        guard let record = folders[folderID] else { return }
        guard let state = try? await store.fetchSyncState(for: record.generation),
              state.backfillPhase == .complete else { return }
        await activateReplacement(folderID: folderID)
    }

    private func backfill(
        folderID: FolderID,
        channel: SyncChannel
    ) async -> BackfillAttempt {
        var activeChannel = channel
        guard var record = folders[folderID],
              record.keepLocally else {
            return BackfillAttempt(result: .halted, channel: activeChannel)
        }
        publishActivity(.downloading, for: folderID)
        do {
            var state = try await store.fetchSyncState(for: record.generation)
                ?? FolderSyncState(generation: record.generation, baselineUID: record.baseline)
            if state.backfillPhase == .complete {
                publishActivity(.idle, for: folderID)
                return BackfillAttempt(result: .committed, channel: activeChannel)
            }
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
                    publishActivity(.halted, for: folderID)
                }
            }

            let selected = try await activeChannel.select(record.path)
            guard folders[folderID]?.keepLocally == true else {
                return BackfillAttempt(result: .halted, channel: activeChannel)
            }
            try await store.updateServerMessageCount(selected.exists, for: folderID)
            let previousGeneration = record.generation
            try await maybeReplace(selected: selected, record: &record)
            folders[folderID] = record
            if record.generation != previousGeneration {
                state = try await store.fetchSyncState(for: record.generation)
                    ?? FolderSyncState(generation: record.generation, baselineUID: record.baseline)
                if state.backfillPhase == .complete {
                    return BackfillAttempt(result: .committed, channel: activeChannel)
                }
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
                guard folders[folderID]?.keepLocally == true else {
                    publishActivity(.idle, for: folderID)
                    return BackfillAttempt(result: .halted, channel: activeChannel)
                }
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
                    publishActivity(.halted, for: folderID)
                    return BackfillAttempt(result: .halted, channel: activeChannel)
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
                    publishActivity(.idle, for: folderID)
                    return BackfillAttempt(result: .committed, channel: activeChannel)
                }
                let capturedGeneration = record.generation
                let windowAttempt = try await ingestWindowResilient(
                    record: record,
                    window: window,
                    channel: activeChannel,
                    notify: false,
                    expectedExpungeRevision: expungeRevision[folderID] ?? 0
                )
                activeChannel = windowAttempt.channel
                let result = windowAttempt.result

                // Cursor advances only after a committed window. Cancellation
                // mid-ingest must not persist low-water (spec: sync.md backfill).
                try Task.checkCancellation()
                switch result {
                case .committed:
                    break
                case .invalidated:
                    publishActivity(.downloading, for: folderID)
                    return BackfillAttempt(result: .invalidated, channel: activeChannel)
                case .halted:
                    publishActivity(.halted, for: folderID)
                    return BackfillAttempt(result: .halted, channel: activeChannel)
                }
                guard stillCurrentGeneration(capturedGeneration, folder: folderID) else {
                    return BackfillAttempt(result: .invalidated, channel: activeChannel)
                }
                state.lowWaterUID = IMAPUID(rawValue: window.lowerBound)
                state.progress = SyncPolicy.backfillProgress(uidNext: uidNext, lowWater: state.lowWaterUID?.rawValue)
                try await store.saveSyncState(state)
            }
        } catch is CancellationError {
            publishActivity(.halted, for: folderID)
            return BackfillAttempt(result: .halted, channel: activeChannel)
        } catch {
            if (stopping || Task.isCancelled) && SyncPolicy.isTransport(error) {
                publishActivity(.halted, for: folderID)
                return BackfillAttempt(result: .halted, channel: activeChannel)
            }
            await logSync("backfill \(record.path)", detail: String(describing: error), folder: folderID)
            if SyncPolicy.isTransport(error) {
                sessionBroken = true
            }
            publishActivity(.halted, for: folderID)
            return BackfillAttempt(result: .halted, channel: activeChannel)
        }
        publishActivity(.halted, for: folderID)
        return BackfillAttempt(result: .halted, channel: activeChannel)
    }

    private func ingestWindowResilient(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        channel: SyncChannel,
        notify: Bool,
        expectedExpungeRevision: UInt64? = nil
    ) async throws -> WindowIngestResult {
        do {
            let result = try await ingestWindow(
                record: record,
                window: window,
                channel: channel,
                notify: notify,
                expectedExpungeRevision: expectedExpungeRevision
            )
            return WindowIngestResult(result: result, channel: channel)
        } catch let failure as MetadataWindowFetchFailure {
            await logSync(
                "bisect window \(record.path)",
                detail: "range=\(window.lowerBound)...\(window.upperBound) depth=0 reason=\(failure.reason)",
                folder: record.id
            )
            return try await bisectWindow(
                record: record,
                window: window,
                replacing: channel,
                notify: notify,
                expectedExpungeRevision: expectedExpungeRevision,
                failure: failure,
                depth: 0,
                maxDepth: SyncPolicy.maxBisectionDepth(for: window)
            )
        }
    }

    private func bisectWindow(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        replacing channel: SyncChannel,
        notify: Bool,
        expectedExpungeRevision: UInt64?,
        failure: MetadataWindowFetchFailure,
        depth: Int,
        maxDepth: Int
    ) async throws -> WindowIngestResult {
        try Task.checkCancellation()
        guard let (lower, upper) = SyncPolicy.bisectWindow(window) else {
            let fresh = try await openFreshBackfillChannel(replacing: channel)
            do {
                let result = try await quarantineUnknown(
                    record: record,
                    window: window,
                    channel: fresh,
                    reason: failure.reason,
                    expectedExpungeRevision: expectedExpungeRevision
                )
                return WindowIngestResult(result: result, channel: fresh)
            } catch {
                await fresh.close()
                throw error
            }
        }
        guard depth < maxDepth else {
            throw failure.underlying
        }

        var currentChannel = channel
        for half in [lower, upper] {
            let candidate = try await openFreshBackfillChannel(replacing: currentChannel)
            currentChannel = candidate
            do {
                let result = try await ingestWindow(
                    record: record,
                    window: half,
                    channel: candidate,
                    notify: notify,
                    expectedExpungeRevision: expectedExpungeRevision
                )
                switch result {
                case .committed:
                    continue
                case .invalidated, .halted:
                    return WindowIngestResult(result: result, channel: candidate)
                }
            } catch let childFailure as MetadataWindowFetchFailure {
                await logSync(
                    "bisect window \(record.path)",
                    detail: "range=\(half.lowerBound)...\(half.upperBound) depth=\(depth + 1) reason=\(childFailure.reason)",
                    folder: record.id
                )
                let child = try await bisectWindow(
                    record: record,
                    window: half,
                    replacing: candidate,
                    notify: notify,
                    expectedExpungeRevision: expectedExpungeRevision,
                    failure: childFailure,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
                currentChannel = child.channel
                if child.result != .committed {
                    return child
                }
            } catch {
                await candidate.close()
                throw error
            }
        }
        return WindowIngestResult(result: .committed, channel: currentChannel)
    }

    private func openFreshBackfillChannel(replacing old: SyncChannel) async throws -> SyncChannel {
        let replacedSync = syncChannel === old
        let oldLease = backfillLeases.removeValue(forKey: ObjectIdentifier(old))
            ?? (replacedSync ? syncLease : nil)
        if replacedSync {
            syncLease = nil
        }
        await old.close()
        if let oldLease {
            await backfillBudget.release(oldLease)
        }
        let password = try await credentials.password(for: config.id)
        guard let lease = await backfillBudget.acquire(owner: config.id) else {
            throw CancellationError()
        }
        let client = clientFactory.makeClient(
            endpoint: config.imap,
            username: config.username,
            password: password
        )
        let fresh = SyncChannel(client: client)
        do {
            try await fresh.connect()
        } catch {
            await fresh.close()
            await backfillBudget.release(lease)
            throw error
        }
        if let index = backfillChannels.firstIndex(where: { $0 === old }) {
            backfillChannels[index] = fresh
        } else {
            backfillChannels.append(fresh)
        }
        if replacedSync {
            syncChannel = fresh
            syncLease = lease
        } else {
            backfillLeases[ObjectIdentifier(fresh)] = lease
        }
        return fresh
    }

    private func ingestWindow(
        record: FolderRecord,
        window: ClosedRange<UInt32>,
        channel: SyncChannel,
        notify: Bool,
        expectedExpungeRevision: UInt64? = nil,
        uidSetOverride: IMAPUIDSet? = nil
    ) async throws -> BackfillAttemptResult {
        guard folders[record.id]?.keepLocally == true else { return .halted }
        let capturedGeneration = record.generation
        let uidSet = uidSetOverride ?? IMAPUIDSet(window)
        let meta: [IMAPFetchedMessage]
        do {
            // Metadata contains no literals, so keeping one window of these
            // small values does not scale with message body size. Bodies are
            // fetched and committed one message at a time below.
            meta = try await channel.fetch(
                in: record.path,
                expectedUIDValidity: capturedGeneration.uidValidity,
                IMAPFetchRequest(
                    uids: uidSet,
                    envelope: true,
                    bodyStructure: true,
                    flags: true,
                    internalDate: true,
                    uid: true
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
            // Live IMAP failures are typed. Legacy test-only errors retain the
            // direct FLAGS fallback so those tests continue to exercise its
            // revision race; typed non-transport failures need a fresh channel.
            if error is IMAPError {
                throw MetadataWindowFetchFailure(underlying: error)
            }
            return try await quarantineUnknown(
                record: record,
                window: window,
                channel: channel,
                reason: String(describing: error),
                expectedExpungeRevision: expectedExpungeRevision
            )
        }

        let generation = record.generation
        let now = clock()
        let ordered = meta.sorted { ($0.uid ?? 0) > ($1.uid ?? 0) }
        var pending: [IncomingMessage] = []
        pending.reserveCapacity(WriteBudget.backfill.maxRows)
        var pendingBytes = 0
        var pendingNotify: [(uid: IMAPUID, sender: String, subject: String)] = []
        let canNotify = notify && record.role == .inbox && !record.isReplacement


        for fetched in ordered {
            try Task.checkCancellation()
            guard let uid = fetched.uid, uid > 0 else { continue }
            guard folders[record.id]?.keepLocally == true else { return .halted }
            if let expectedExpungeRevision,
               expectedExpungeRevision != expungeRevision[record.id, default: 0] {
                return .invalidated
            }

            var bodyParts: [IMAPPeekedPart] = []
            var peekedBytes = 0
            var didHitPeekLimit = false
            let header = IMAPPeekSection(
                specifier: "HEADER",
                origin: 0,
                length: SyncPolicy.backfillHeaderPeekByteLimit
            )
            let structure = fetched.bodyStructure
            var specifiers = structure.map {
                MessageAssembler.textNeeds($0).map(\.specifier)
            } ?? []
            var seenSpecifiers = Set<String>()
            specifiers = specifiers.filter { specifier in
                let upper = specifier.uppercased()
                guard specifier.unicodeScalars.allSatisfy({
                    $0 == "." || ("0"..."9").contains($0)
                }), seenSpecifiers.insert(upper).inserted else {
                    return false
                }
                return true
            }
            let peekSections = [header] + specifiers.map {
                IMAPPeekSection(
                    specifier: $0,
                    origin: 0,
                    length: SyncPolicy.backfillTextPeekByteLimit
                )
            }

            var boundedSections: [IMAPPeekSection] = []
            var requestedLengths: [String: Int] = [:]
            for section in peekSections {
                try Task.checkCancellation()
                let remaining = SyncPolicy.backfillWindowPeekByteBudget - peekedBytes
                guard remaining > 0 else { break }
                let length = min(section.length ?? remaining, remaining)
                let bounded = IMAPPeekSection(
                    specifier: section.specifier,
                    binary: section.binary,
                    origin: 0,
                    length: length
                )
                boundedSections.append(bounded)
                requestedLengths[section.specifier.uppercased()] = length
            }
            if !boundedSections.isEmpty {
                do {
                    let fetchedParts = try await channel.fetch(
                        in: record.path,
                        expectedUIDValidity: capturedGeneration.uidValidity,
                        IMAPFetchRequest(
                            uids: IMAPUIDSet(uid: uid),
                            uid: true,
                            peek: boundedSections
                        )
                    )
                    for response in fetchedParts {
                        for var part in response.parts {
                            let room = SyncPolicy.backfillWindowPeekByteBudget - peekedBytes
                            guard room > 0 else { break }
                            if let length = requestedLengths[part.specifier.uppercased()],
                               part.data.count >= length {
                                didHitPeekLimit = true
                            }
                            if part.data.count > room {
                                part.data = Data(part.data.prefix(room))
                                didHitPeekLimit = true
                            }
                            bodyParts.append(part)
                            peekedBytes += part.data.count
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if (stopping || Task.isCancelled) && SyncPolicy.isTransport(error) {
                        return .halted
                    }
                    await logSync(
                        "body peek \(record.path)",
                        detail: String(describing: error),
                        folder: record.id
                    )
                    if SyncPolicy.isTransport(error) { throw error }
                }
            }

            var incoming = MessageAssembler.incoming(
                generation: generation,
                fetched: fetched,
                bodyParts: bodyParts,
                now: now
            )
            if didHitPeekLimit {
                incoming.isTruncated = true
            }
            pending.append(incoming)
            pendingBytes += incoming.decodedBytes
            if canNotify,
               SyncPolicy.isNotifiable(uid: incoming.uid, baseline: record.baseline),
               try await store.messageID(generation: generation, uid: incoming.uid) == nil {
                pendingNotify.append((
                    uid: incoming.uid,
                    sender: MessageAssembler.senderDisplay(incoming.envelope),
                    subject: incoming.envelope.subject
                ))
            }
            if pending.count >= WriteBudget.backfill.maxRows
                || pendingBytes >= WriteBudget.backfill.maxDecodedBytes {
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                pendingBytes = 0
                if let result = try await commitBackfillBatch(
                    batch,
                    record: record,
                    capturedGeneration: capturedGeneration,
                    expectedExpungeRevision: expectedExpungeRevision
                ) {
                    return result
                }
            }
        }
        if !pending.isEmpty {
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            if let result = try await commitBackfillBatch(
                batch,
                record: record,
                capturedGeneration: capturedGeneration,
                expectedExpungeRevision: expectedExpungeRevision
            ) {
                return result
            }
        }
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
        guard stillCurrentGeneration(capturedGeneration, folder: record.id) else {
            return .invalidated
        }
        if canNotify {
            for pending in pendingNotify {
                let key = NotificationKey(generation: generation, uid: pending.uid)
                if notified.insert(key).inserted,
                   let id = try await store.messageID(generation: generation, uid: pending.uid) {
                    emit(NewMailEvent(
                        folder: record.id,
                        from: pending.sender,
                        subject: pending.subject,
                        messageID: id
                    ))
                }
            }
        }
        return .committed
    }
    private func commitBackfillBatch(
        _ batch: [IncomingMessage],
        record: FolderRecord,
        capturedGeneration: MailboxGeneration,
        expectedExpungeRevision: UInt64?
    ) async throws -> BackfillAttemptResult? {
        guard !batch.isEmpty else { return nil }
        if let expectedExpungeRevision,
           expectedExpungeRevision != expungeRevision[record.id, default: 0] {
            return .invalidated
        }
        guard stillCurrentGeneration(capturedGeneration, folder: record.id) else {
            return .invalidated
        }
        guard folders[record.id]?.keepLocally == true else { return .halted }
        publishActivity(.indexing, for: record.id)
        beginWriteOperation()
        do {
            _ = try await store.upsertMessages(batch)
            endWriteOperation()
        } catch {
            endWriteOperation()
            throw error
        }
        publishActivity(.downloading, for: record.id)
        return nil
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
        publishActivity(.quarantinedStall, for: record.id)
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
            if record.keepLocally {
                try await delta(folderID: record.id, channel: channel, notify: notify)
            } else {
                try await refreshStatus(folderID: record.id, channel: channel)
            }
        }
    }

    /// Refreshes a disabled mailbox without any UID FETCH. SELECT supplies the
    /// current EXISTS/UIDNEXT status while message rows remain untouched.
    private func refreshStatus(folderID: FolderID, channel: SyncChannel) async throws {
        guard let record = folders[folderID], !record.keepLocally else { return }
        let selected = try await channel.select(record.path)
        guard folders[folderID]?.keepLocally == false else { return }
        try await store.updateServerMessageCount(selected.exists, for: folderID)
        guard var latest = folders[folderID] else { return }
        latest.serverMessageCount = selected.exists
        latest.lastUidNext = selected.uidNext ?? latest.lastUidNext
        latest.lastDeltaAt = clock()
        folders[folderID] = latest
    }

    private func delta(folderID: FolderID, channel: SyncChannel, notify: Bool) async throws {
        guard let current = folders[folderID] else { return }
        guard current.keepLocally else {
            try await refreshStatus(folderID: folderID, channel: channel)
            return
        }
        var record = current
        do {
            try await runDelta(record: &record, channel: channel, notify: notify)
            record.lastDeltaAt = clock()
            folders[folderID] = record
        } catch {
            guard folders[folderID]?.keepLocally == true else { return }
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
        guard folders[record.id]?.keepLocally == true else { return }
        try await store.updateServerMessageCount(selected.exists, for: record.id)

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
                // A QRESYNC SELECT can race an in-flight EXPUNGE burst
                // delivered on the IDLE socket. If EXISTS moved backwards,
                // UIDNEXT advanced without VANISHED, or QRESYNC carried a
                // VANISHED set, sweep stored UIDs as the lossless fallback.
                if observedExpunge || uidNextChanged {
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
        if record.isReplacement, record.keepLocally {
            await backfillScheduler?.setEnabled(record.id, true)
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

    private func openBackfillConnections(password: String) async {
        let enabledFolders = folders.values.lazy.filter(\.keepLocally).count
        let requested = min(
            SyncPolicy.maxBackfillConnections,
            max(1, min(enabledFolders, backfillConnectionCap ?? SyncPolicy.maxBackfillConnections))
        )
        guard backfillChannels.count < requested else { return }
        while backfillChannels.count < requested {
            guard let lease = await backfillBudget.acquire(owner: config.id) else { return }
            let client = clientFactory.makeClient(
                endpoint: config.imap,
                username: config.username,
                password: password
            )
            let channel = SyncChannel(client: client)
            do {
                try await channel.connect()
                backfillChannels.append(channel)
                backfillLeases[ObjectIdentifier(channel)] = lease
            } catch {
                await channel.close()
                await backfillBudget.release(lease)
                if SyncPolicy.isConnectionCap(error) {
                    backfillConnectionCap = backfillChannels.count
                    await logSync(
                        "backfill connection cap",
                        detail: "cap=\(backfillChannels.count) \(String(describing: error))"
                    )
                } else {
                    await logSync("backfill connection failed", detail: String(describing: error))
                }
                break
            }
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
                backfillConnectionCap = 1
                await logSync("single-connection fallback", detail: String(describing: error))
            } else {
                await logSync("idle connect failed; multiplex", detail: String(describing: error))
            }
        }
    }

    private func idleLoop() async {
        // The socket is connected during session setup, but beginning IDLE
        // waits until the initial mailbox walk has settled. This keeps the
        // primary command channel free for the first windows.
        while !stopping && !Task.isCancelled && !backfillPassFinished {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard !stopping, !Task.isCancelled else { return }
        let caps = await syncChannel?.capabilities()
        guard caps?.idle == true else { return }
        guard let inboxID, var record = folders[inboxID],
              let channel = idleChannel else { return }
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
            // IDLE owns this path when its dedicated socket is available.
            if let inboxID, !dualConnection || !backfillPassFinished {
                try? await delta(folderID: inboxID, channel: channel, notify: true)
            }

            let now = clock()
            for record in folders.values where record.role != .inbox {
                guard record.keepLocally else {
                    try? await refreshStatus(folderID: record.id, channel: channel)
                    continue
                }
                let interval = SyncPolicy.isSpecialUse(record.role)
                    ? settings.specialUseDelta
                    : settings.otherFolderDelta
                if now.timeIntervalSince(record.lastDeltaAt) >= durationSeconds(interval) {
                    try? await delta(folderID: record.id, channel: channel, notify: true)
                }
            }

            for record in SyncPolicy.sortFolders(Array(folders.values)) where record.keepLocally {
                if stopping { return }
                if let state = try? await store.fetchSyncState(for: record.generation),
                   state.backfillPhase != .complete {
                    await backfillScheduler?.setEnabled(record.id, true)
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
                let renamed = (try? await drainFolderRenames(channel: channel)) ?? false
                if renamed {
                    try? await discover(channel: channel)
                }
                try? await drainFlags(channel: channel)
                let movedFolders = (try? await drainMove(channel: channel)) ?? []
                // A successful server move changes both mailboxes. Reuse the
                // normal delta path immediately, coalescing a batch into one
                // refresh per affected folder instead of waiting for a timer.
                for folderID in movedFolders.sorted(by: { $0.rawValue < $1.rawValue }) {
                    if stopping { return }
                    try? await delta(folderID: folderID, channel: channel, notify: true)
                }
            }
            try? await Task.sleep(for: settings.seenPoll)
        }
    }

    private func drainFolderRenames(channel: SyncChannel) async throws -> Bool {
        let ops = try await store.snapshotFolderRenameQueue(limit: 32)
        var didRename = false
        for op in ops {
            if stopping { return didRename }
            try Task.checkCancellation()
            if !folderRenameInFlight.insert(op.folder).inserted {
                continue
            }
            defer { folderRenameInFlight.remove(op.folder) }

            guard op.account == config.id else {
                try await store.dropFolderRename(op, reason: "account mismatch")
                continue
            }
            guard let summary = try await store.fetchFolderSummary(op.folder),
                  summary.accountID == config.id,
                  folders[op.folder] != nil
            else {
                try await store.dropFolderRename(op, reason: "folder missing or retired")
                continue
            }

            do {
                try await channel.renameMailbox(from: summary.path, to: op.targetPath)
                try await store.applyFolderRename(op)
                didRename = true
            } catch let error as IMAPError {
                if error.isTaggedNO || error.isTaggedBAD {
                    try await store.dropFolderRename(op, reason: error.description)
                } else {
                    throw error
                }
            }
        }
        return didRename
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

 
    private func drainMove(channel: SyncChannel) async throws -> Set<FolderID> {
        let ops = try await store.snapshotMoveQueue(limit: 32)
        var handled = Set<Int64>()
        var affectedFolders = Set<FolderID>()
        for op in ops {
            if stopping { return affectedFolders }
            try Task.checkCancellation()
            guard !handled.contains(op.id) else { continue }
            handled.insert(op.id)

            let live = try await store.liveGeneration(for: op.folder)
            if live?.uidValidity != op.uidValidity {
                affectedFolders.insert(op.folder)
                try await store.dropStaleMove(folder: op.folder)
                continue
            }
            guard (try await store.fetchFolderSummary(op.folder)) != nil,
                  let source = folders[op.folder] else {
                try await discardMove(op, reason: "folder missing")
                continue
            }

            let target: FolderRecord?
            if let destinationFolderID = op.destinationFolderID {
                target = folders[destinationFolderID]
            } else {
                target = SyncPolicy.destinationFolder(for: op.destination, in: folders.values)
            }
            let destinationName: String
            if let target {
                destinationName = target.name
            } else if let destinationFolderID = op.destinationFolderID {
                destinationName = "destination folder \(destinationFolderID.rawValue)"
            } else {
                destinationName = op.destination.rawValue.capitalized
            }
            guard let target else {
                affectedFolders.insert(op.folder)
                try await discardMove(op, reason: "no \(destinationName) folder")
                try? await restoreMoveMessages([op], source: source, channel: channel)
                continue
            }

            // Coalesce adjacent operations with the same source generation and
            // destination identity. One UID MOVE/COPY carries the whole set.
            let batch = ops.filter { candidate in
                guard !handled.contains(candidate.id),
                      candidate.folder == op.folder,
                      candidate.uidValidity == op.uidValidity,
                      candidate.copied == op.copied
                else { return false }
                if let destinationFolderID = op.destinationFolderID {
                    return candidate.destinationFolderID == destinationFolderID
                }
                return candidate.destinationFolderID == nil
                    && candidate.destination == op.destination
            } + [op]
            for candidate in batch {
                handled.insert(candidate.id)
            }
            let discovered = try await channel.listFolders()
            let destinationPresent = discovered.folders.contains {
                $0.path.compare(target.path, options: [.caseInsensitive]) == .orderedSame
            }
            guard destinationPresent else {
                affectedFolders.insert(op.folder)
                for candidate in batch {
                    try await discardMove(
                        candidate,
                        reason: "no \(destinationName) folder"
                    )
                }
                try? await restoreMoveMessages(batch, source: source, channel: channel)
                continue
            }


            // Keep the gate over the whole server sequence (and its local
            // acknowledgement), so stop cannot close the channel between
            // fallback phases.
            guard !stopping else { return affectedFolders }
            beginWriteOperation()
            defer { endWriteOperation() }
            let capabilities = await channel.capabilities()
            let useMove = !op.copied && capabilities.move
            var phase = useMove ? "MOVE" : (op.copied ? "STORE" : "COPY")
            let uids = SyncPolicy.uidSet(uids: batch.map { $0.uid.rawValue })
            do {
                let liveNow = try await store.liveGeneration(for: op.folder)
                if liveNow?.uidValidity != op.uidValidity {
                    affectedFolders.insert(op.folder)
                    try await store.dropStaleMove(folder: op.folder)
                    continue
                }
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
                        for candidate in batch {
                            try await store.markMoveCopied(candidate)
                        }
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
                affectedFolders.insert(op.folder)
                affectedFolders.insert(target.id)
                for candidate in batch {
                    try await store.deleteMoveOp(candidate)
                }
            } catch SyncChannelError.staleMailbox {
                // The source generation can change after the queue snapshot but
                // before the atomic MOVE/COPY select. Refresh it now so stale
                // queue rows are logged and dropped against the new generation,
                // rather than waiting for the periodic folder delta.
                try await delta(folderID: op.folder, channel: channel, notify: true)
                try await store.dropStaleMove(folder: op.folder)
                for candidate in batch {
                    try await store.deleteMoveOp(candidate)
                }
            } catch let error as IMAPError {
                if error.isTaggedNO || error.isTaggedBAD {
                    if useMove || phase == "COPY" {
                        affectedFolders.insert(op.folder)
                    }
                    for candidate in batch {
                        if useMove || phase == "COPY" {
                            affectedFolders.insert(candidate.folder)
                            try await discardMove(
                                candidate,
                                reason: "destination \(destinationName): \(error.description)"
                            )
                        } else {
                            try await retainMove(
                                candidate,
                                phase: phase,
                                reason: error.description
                            )
                        }
                    }
                    if useMove || phase == "COPY" {
                        try? await restoreMoveMessages(batch, source: source, channel: channel)
                    }
                } else {
                    throw error
                }
            }
        }
        return affectedFolders
        }

    private func restoreMoveMessages(
        _ ops: [MoveOp],
        source: FolderRecord,
        channel: SyncChannel
    ) async throws {
        let rawUIDs = ops.map { $0.uid.rawValue }
        guard let lower = rawUIDs.min(), let upper = rawUIDs.max() else { return }
        _ = try await ingestWindow(
            record: source,
            window: lower...upper,
            channel: channel,
            notify: false,
            uidSetOverride: SyncPolicy.uidSet(uids: rawUIDs)
        )
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

