import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import MailternalSync

struct LiveMailError: LocalizedError, Sendable {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct KeychainCredentialProvider: IMAPCredentialProvider {
    let keychain: KeychainStore

    func password(for account: AccountID) async throws -> String {
        try keychain.loadPassword(for: account)
    }
}

@MainActor
final class LiveMailFacade: MailFacade {
    private(set) var accountState: AccountState = .none {
        didSet { accountContinuation.yield(accountState) }
    }

    var activeAccountID: AccountID? { config?.id }
    var accountConfig: AccountConfig? { config }
    var accountDisplayName: String? {
        guard let config else { return nil }
        let displayName = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? config.emailAddress : displayName
    }


    let accountStateStream: AsyncStream<AccountState>
    let foldersStream: AsyncStream<[FolderSummary]>
    let syncStatusStream: AsyncStream<SyncStatus>

    private let accountContinuation: AsyncStream<AccountState>.Continuation
    private let foldersContinuation: AsyncStream<[FolderSummary]>.Continuation
    private let syncContinuation: AsyncStream<SyncStatus>.Continuation

    private let container: MailternalContainer
    private let keychain: KeychainStore
    private let notifications: LiveNotificationService
    private var store: MailStore
    private var engine: SyncEngine?
    private var config: AccountConfig?
    private var visibleFolderID: FolderID?
    private var engineTasks: [Task<Void, Never>] = []
    private var foldersTask: Task<Void, Never>?
    private var didRestore = false
    private var qaMonitorTask: Task<Void, Never>?
    private let qaStartedAt = Date()
    private var qaFirstPageLogged = false
    private var qaInboxCompleteLogged = false
    private var qaSearchBenched = false
    private var qaCIDFetched = false
    private var qaLastInboxCount = -1
    private var qaLastProgressLog = Date.distantPast
    private var qaPeakFootprint: Int64 = 0
    private var qaAllFoldersCompleteLogged = false
    private var qaLastSizeLog = Date.distantPast
    /// Test-only scripted-session seam. `IMAPClientFactory` is package-access in
    /// MailternalSync — visible only when this file compiles inside the SwiftPM
    /// package (MailternalLive target / MailternalLiveTests), not in the Xcode app
    /// target. Stored type-erased; cast back under SWIFT_PACKAGE at the use site.
    /// The shipping app always passes nil and uses the engine's live factory.
    private let testClientFactory: (any Sendable)?

    init(
        container: MailternalContainer = .default,
        keychain: KeychainStore = KeychainStore(),
        enableNotifications: Bool = true,
        attachmentCacheCapBytes: Int64 = MailStore.defaultAttachmentCacheCapBytes,
        clientFactory: (any Sendable)? = nil
    ) throws {
        QAIMAPTrust.installIfRequested()
        try container.prepare()
        self.container = container
        self.keychain = keychain
        self.testClientFactory = clientFactory
        self.notifications = LiveNotificationService(enabled: enableNotifications)
        self.store = try MailStore(
            databaseURL: container.databaseURL,
            cachesDirectory: container.attachmentsDirectory,
            attachmentCacheCapBytes: attachmentCacheCapBytes
        )

        let account = AsyncStream.makeStream(of: AccountState.self, bufferingPolicy: .bufferingNewest(1))
        let folders = AsyncStream.makeStream(of: [FolderSummary].self, bufferingPolicy: .bufferingNewest(1))
        let sync = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(1))
        accountStateStream = account.stream
        foldersStream = folders.stream
        syncStatusStream = sync.stream
        accountContinuation = account.continuation
        foldersContinuation = folders.continuation
        syncContinuation = sync.continuation
        account.continuation.yield(.none)
        folders.continuation.yield([])
        sync.continuation.yield(SyncStatus(mode: .fullHistory, isOnline: false))
    }

    /// Load a persisted account and start the engine. Safe to call once at launch.
    func restorePersistedAccount() async {
        guard !didRestore else { return }
        didRestore = true
        do {
            if let qa = QALaunch.parse() {
                try await seedQAAccount(qa)
            }
            guard let account = try await store.fetchAccounts().first else { return }
            config = account
            do {
                _ = try keychain.loadPassword(for: account.id)
            } catch {
                setState(.authFailed(message: "The saved password is missing from the Keychain."))
                return
            }
            // Local store reads must be interactive immediately (spec: storage).
            // Start observation before the IMAP session so a cold start does not
            // wait on connect for the first page.
            startFolderObservation(account: account.id)
            setState(.validating)
            await startEngine(for: account)
            startQAMonitorIfNeeded(account: account.id)
        } catch {
            setState(.connectionFailed(message: userPresentable(error, host: config?.imap.host)))
        }
    }

    func reportVisibleFolder(_ id: FolderID?) {
        visibleFolderID = id
    }

    func shutdown() async {
        qaMonitorTask?.cancel()
        qaMonitorTask = nil
        await stopEngine()
    }

    func addAccount(_ config: AccountConfig, password: String) async throws {
        setState(.validating)
        try await validate(config, password: password)

        if let existing = try? await store.fetchAccounts() {
            for account in existing where account.id != config.id {
                try? keychain.deletePassword(for: account.id)
                try? await store.deleteAccount(account.id)
            }
        }
        await stopEngine()

        var storedConfig = config
        if let existing = try await store.fetchAccount(config.id) {
            storedConfig.accountLinkID = existing.accountLinkID
        }

        do {
            try keychain.savePassword(password, for: storedConfig.id)
        } catch {
            let message = error.localizedDescription
            setState(.authFailed(message: message))
            throw LiveMailError(message)
        }
        do {
            try await store.upsertAccount(storedConfig)
        } catch {
            try? keychain.deletePassword(for: storedConfig.id)
            let message = "Could not save the account."
            setState(.connectionFailed(message: message))
            throw LiveMailError(message)
        }

        self.config = storedConfig
        await startEngine(for: storedConfig)
        startFolderObservation(account: storedConfig.id)
    }

    func updateAccount(_ config: AccountConfig, password: String?) async throws {
        guard let existing = self.config else {
            let message = "No account is configured."
            setState(.none)
            throw LiveMailError(message)
        }
        guard existing.id == config.id else {
            let message = "That account is no longer active."
            throw LiveMailError(message)
        }

        var storedConfig = config
        // AccountLinkID is the stable identity used by deep links. Editing
        // settings must never generate a new identity.
        storedConfig.accountLinkID = existing.accountLinkID

        let requiresValidation =
            existing.emailAddress != storedConfig.emailAddress
            || existing.username != storedConfig.username
            || existing.imap != storedConfig.imap
            || password != nil

        guard requiresValidation else {
            do {
                try await store.upsertAccount(storedConfig)
            } catch {
                let message = "Could not save the account."
                setState(.connectionFailed(message: message))
                throw LiveMailError(message)
            }
            self.config = storedConfig
            // Even when only the label changed, observers need a fresh event
            // so titles in the main window update immediately.
            setState(.active)
            return
        }

        let previousPassword = try? keychain.loadPassword(for: existing.id)
        let validationPassword: String
        if let password {
            validationPassword = password
        } else {
            do {
                validationPassword = try keychain.loadPassword(for: existing.id)
            } catch {
                let message = "The saved password is missing from the Keychain."
                setState(.authFailed(message: message))
                throw LiveMailError(message)
            }
        }

        setState(.validating)
        try await validate(storedConfig, password: validationPassword)

        if let password {
            do {
                try keychain.savePassword(password, for: storedConfig.id)
            } catch {
                let message = error.localizedDescription
                setState(.authFailed(message: message))
                throw LiveMailError(message)
            }
        }

        do {
            try await store.upsertAccount(storedConfig)
        } catch {
            if let previousPassword {
                try? keychain.savePassword(previousPassword, for: existing.id)
            }
            let message = "Could not save the account."
            setState(.connectionFailed(message: message))
            throw LiveMailError(message)
        }

        // Persist first, then replace the running engine with one bound to
        // the new endpoint/credentials.
        await stopEngine()
        self.config = storedConfig
        await startEngine(for: storedConfig)
        startFolderObservation(account: storedConfig.id)
        setState(.active)
    }


    func removeAccount() async throws {
        await stopEngine()
        if let id = config?.id {
            try keychain.deletePassword(for: id)
            try? await store.deleteAccount(id)
        }
        // Drop UI-visible account state on the MainActor first so a multi-gig
        // cache wipe cannot freeze an "active" account. Then await the
        // off-main wipe so callers still finish after files are gone.
        let attachments = container
        config = nil
        visibleFolderID = nil
        setState(.none)
        foldersContinuation.yield([])
        syncContinuation.yield(SyncStatus(mode: .fullHistory, isOnline: false))
        notifications.setBadge(0)
        await attachments.wipeAttachmentFiles()
    }

    func page(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) async throws -> MessagePage {
        try await store.page(in: folder, after: cursor, limit: limit)
    }

    func observePage(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) -> AsyncStream<MessagePage> {
        store.observePage(in: folder, after: cursor, limit: limit)
    }

    func detail(_ id: MessageID) async throws -> MessageDetail {
        try await store.detail(id)
    }
    func makeDeepLink(for folder: FolderID) async throws -> MailternalDeepLink? {
        guard let account = activeAccountID else { return nil }
        return try await store.makeDeepLink(account: account, folder: folder)
    }

    func makeDeepLink(for message: MessageID) async throws -> MailternalDeepLink? {
        guard let account = activeAccountID else { return nil }
        return try await store.makeDeepLink(account: account, message: message)
    }

    func resolve(_ link: MailternalDeepLink) async throws -> MailternalDeepLinkResolution? {
        try await store.resolve(link)
    }


    func markRead(_ id: MessageID) async {
        try? await store.enqueueFlag(message: id, flag: .seen, set: true)
    }

    func markUnread(_ id: MessageID) async {
        try? await store.enqueueFlag(message: id, flag: .seen, set: false)
    }

    func trash(_ id: MessageID) async {
        try? await store.enqueueMove(message: id, to: .trash)
    }

    func setFlagged(_ id: MessageID, _ flagged: Bool) async {
        try? await store.enqueueFlag(message: id, flag: .flagged, set: flagged)
    }

    func archive(_ id: MessageID) async {
        try? await store.enqueueMove(message: id, to: .archive)
    }

    func rawSource(_ id: MessageID) async throws -> String {
        guard let engine else {
            throw LiveMailError("Mail is not connected.")
        }
        return try await performOnDemandFetch {
            try await engine.rawSource(message: id)
        }
    }

    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL {
        guard let engine else {
            throw LiveMailError("Mail is not connected.")
        }
        let spec = try await imapSection(for: message, part: part)
        return try await performOnDemandFetch {
            try await engine.fetchPart(message: message, part: spec)
        }
    }

    /// UIDVALIDITY replacement: engine rejects the fetch; kick a delta so the
    /// folder snapshot refreshes, and surface a non-alarming error to the UI.
    private func performOnDemandFetch<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch SyncEngineError.staleMessage {
            await engine?.refreshNow()
            throw LiveMailError(SyncEngineError.staleMessage.localizedDescription)
        }
    }

    /// `cid:` keys from the HTML handler map onto BODYSTRUCTURE part ids.
    private func imapSection(for message: MessageID, part: String) async throws -> String {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cid:") else { return trimmed }
        let cid = Self.normalizedCID(String(trimmed.dropFirst(4)))
        let detail = try await store.detail(message)
        if let match = detail.attachments.first(where: {
            guard let contentID = $0.contentID else { return false }
            return Self.normalizedCID(contentID).caseInsensitiveCompare(cid) == .orderedSame
        }) {
            return match.id
        }
        throw LiveMailError("Could not find that inline part.")
    }

    private static func normalizedCID(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: String, limit: Int) async throws -> [MessageRow] {
        try await store.search(query, limit: limit)
    }

    func refresh() async {
        await engine?.refreshNow()
    }

    func snapshotFolders() async throws -> [FolderSummary] {
        guard let id = config?.id else { return [] }
        return try await store.fetchFolders(account: id)
    }

    func snapshotErrorLog(limit: Int = 20) async throws -> [String] {
        try await store.fetchErrorLog(limit: limit).map { entry in
            let detail = entry.detail.map { " \($0)" } ?? ""
            return "\(entry.kind.rawValue): \(entry.message)\(detail)"
        }
    }

    private func setState(_ state: AccountState) {
        accountState = state
    }

    private func validate(_ config: AccountConfig, password: String) async throws {
        if password.isEmpty {
            let message = "A password is required."
            setState(.authFailed(message: message))
            throw LiveMailError(message)
        }
        let session = IMAPSession(
            endpoint: config.imap,
            username: config.username,
            password: password
        )
        do {
            try await session.connect()
            await session.close()
        } catch let error as IMAPError {
            let mapped = mapIMAPError(error, host: config.imap.host)
            setState(mapped.state)
            throw LiveMailError(mapped.message)
        } catch {
            let message = "Could not connect to \(config.imap.host)."
            setState(.connectionFailed(message: message))
            throw LiveMailError(message)
        }
    }

    private func startEngine(for config: AccountConfig) async {
        let credentials = KeychainCredentialProvider(keychain: keychain)
        let qa = ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1"
            || QALaunch.parse() != nil
        let engine: SyncEngine
        #if SWIFT_PACKAGE
        if let factory = testClientFactory as? any IMAPClientFactory {
            engine = SyncEngine(
                store: store,
                config: config,
                credentials: credentials,
                clientFactory: factory,
                qaAmpleDisk: qa
            )
        } else {
            engine = SyncEngine(
                store: store,
                config: config,
                credentials: credentials,
                qaAmpleDisk: qa
            )
        }
        #else
        engine = SyncEngine(
            store: store,
            config: config,
            credentials: credentials,
            qaAmpleDisk: qa
        )
        #endif
        self.engine = engine
        await engine.start()
        attachEngineStreams(engine)

    }

    private func stopEngine() async {
        foldersTask?.cancel()
        foldersTask = nil
        for task in engineTasks { task.cancel() }
        engineTasks = []
        await engine?.stop()
        engine = nil
    }

    private func attachEngineStreams(_ engine: SyncEngine) {
        for task in engineTasks { task.cancel() }
        let statusTask = Task { [weak self] in
            let stream = await engine.status
            for await status in stream {
                guard let self else { return }
                self.syncContinuation.yield(status)
                if status.isOnline {
                    self.markActiveIfValidating()
                }
            }
        }
        let mailTask = Task { [weak self] in
            let stream = await engine.newMail
            for await event in stream {
                self?.handleNewMail(event)
            }
        }
        let failureTask = Task { [weak self] in
            let stream = await engine.failures
            for await failure in stream {
                self?.applyEngineFailure(failure)
            }
        }
        engineTasks = [statusTask, mailTask, failureTask]
    }

    private func markActiveIfValidating() {
        guard case .validating = accountState else { return }
        setState(.active)
        notifications.requestAuthorizationIfNeeded()
    }

    private func applyEngineFailure(_ failure: SyncFailure) {
        switch accountState {
        case .none:
            return
        default:
            break
        }
        let host = config?.imap.host ?? "the mail server"
        switch failure {
        case .authentication:
            setState(.authFailed(message: "The username or password was rejected."))
        case .tls:
            setState(.connectionFailed(message: "Could not establish a secure connection to \(host)."))
        }
    }

    private func seedQAAccount(_ qa: QALaunch.Config) async throws {
        if let existing = try? await store.fetchAccounts() {
            for account in existing where account.id != qa.accountID {
                try? keychain.deletePassword(for: account.id)
                try? await store.deleteAccount(account.id)
            }
        }
        try keychain.savePassword(qa.password, for: qa.accountID)
        try await store.upsertAccount(qa.accountConfig)
        QALaunch.log(
            "seeded account \(qa.username) \(qa.host):\(qa.port) \(qa.security.rawValue) db=\(container.databaseURL.path)"
        )
    }

    private func startQAMonitorIfNeeded(account: AccountID) {
        guard QALaunch.parse() != nil || ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" else {
            return
        }
        qaMonitorTask?.cancel()
        qaMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.qaTick(account: account)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func qaTick(account: AccountID) async {
        let footprint = QALaunch.footprintBytes()
        if footprint > qaPeakFootprint { qaPeakFootprint = footprint }
        let folders = (try? await store.fetchFolders(account: account)) ?? []
        let inbox = folders.first(where: { $0.role == .inbox })
            ?? folders.first(where: { $0.path.compare("INBOX", options: [.caseInsensitive]) == .orderedSame })
        if let inbox {
            await qaLogInbox(inbox, footprint: footprint)
        }
        let now = Date()
        if now.timeIntervalSince(qaLastSizeLog) >= 30 {
            qaLastSizeLog = now
            QALaunch.log(qaSizeLine(folders: folders, footprint: footprint))
        }
        if !folders.isEmpty, folders.allSatisfy({ $0.backfill == .complete }), !qaAllFoldersCompleteLogged {
            qaAllFoldersCompleteLogged = true
            QALaunch.log(
                "all folders complete n=\(folders.count) total=\(folders.reduce(0) { $0 + $1.totalCount }) elapsed=\(qaElapsed())s peak_footprint=\(qaPeakFootprint) \(qaDiskSizes())"
            )
        }
        if qaFirstPageLogged, let launch = QALaunch.parse() {
            if launch.benchSearch, !qaSearchBenched, let inbox, inbox.backfill == .complete {
                qaSearchBenched = true
                await qaBenchSearch()
            }
            if launch.fetchCID, !qaCIDFetched, engine != nil, let inbox, inbox.totalCount > 0 {
                qaCIDFetched = true
                await qaFetchCIDParts(inbox: inbox)
            }
        }
    }

    private func qaLogInbox(_ inbox: FolderSummary, footprint: Int64) async {
        if !qaFirstPageLogged {
            if let page = try? await store.page(in: inbox.id, after: nil, limit: 80), !page.rows.isEmpty {
                qaFirstPageLogged = true
                QALaunch.log(
                    "first-page ready folder=\(inbox.path) rows=\(page.rows.count) count=\(inbox.totalCount) elapsed=\(qaElapsed())s footprint=\(footprint)"
                )
            }
        }
        if inbox.backfill == .complete, !qaInboxCompleteLogged {
            qaInboxCompleteLogged = true
            QALaunch.log(
                "INBOX complete count=\(inbox.totalCount) elapsed=\(qaElapsed())s peak_footprint=\(qaPeakFootprint) \(qaDiskSizes())"
            )
        }
        let now = Date()
        if inbox.totalCount != qaLastInboxCount || now.timeIntervalSince(qaLastProgressLog) >= 15 {
            qaLastInboxCount = inbox.totalCount
            qaLastProgressLog = now
            QALaunch.log(
                "inbox count=\(inbox.totalCount) backfill=\(inbox.backfill) elapsed=\(qaElapsed())s footprint=\(footprint) peak=\(qaPeakFootprint)"
            )
        }
    }

    private func qaSizeLine(folders: [FolderSummary], footprint: Int64) -> String {
        let parts = folders
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { "\($0.path)=\($0.totalCount)/\(String(describing: $0.backfill))" }
            .joined(separator: ",")
        return "folders elapsed=\(qaElapsed())s footprint=\(footprint) peak=\(qaPeakFootprint) \(qaDiskSizes()) [\(parts)]"
    }

    private func qaDiskSizes() -> String {
        let fm = FileManager.default
        func size(_ url: URL) -> Int64 {
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        }
        let db = container.databaseURL
        let wal = URL(fileURLWithPath: db.path + "-wal")
        let shm = URL(fileURLWithPath: db.path + "-shm")
        return "db=\(size(db)) wal=\(size(wal)) shm=\(size(shm))"
    }

    private func qaBenchSearch() async {
        let terms = ["thread", "message", "zxqwvnotatoken"]
        for term in terms {
            var samples: [Double] = []
            samples.reserveCapacity(21)
            for i in 0..<21 {
                let started = Date()
                let hits = (try? await search(term, limit: 25)) ?? []
                let ms = Date().timeIntervalSince(started) * 1000
                if i > 0 { samples.append(ms) }
                if i == 0 {
                    QALaunch.log("search warmup term=\(term) hits=\(hits.count) \(String(format: "%.2f", ms))ms")
                }
            }
            samples.sort()
            let p50 = samples[samples.count / 2]
            let p95 = samples[(samples.count * 95) / 100]
            QALaunch.log(
                "search term=\(term) n=\(samples.count) p50=\(String(format: "%.2f", p50))ms p95=\(String(format: "%.2f", p95))ms"
            )
        }
    }

    private func qaFetchCIDParts(inbox: FolderSummary) async {
        var fetched = 0
        var cursor: MessagePageCursor?
        var urls: [URL] = []
        do {
            repeat {
                let page = try await store.page(in: inbox.id, after: cursor, limit: 40)
                for row in page.rows where row.hasAttachments {
                    let detail = try await store.detail(row.id)
                    guard let part = detail.attachments.first(where: { $0.contentID != nil }) else {
                        continue
                    }
                    let url = try await fetchAttachment(row.id, part: part.id)
                    urls.append(url)
                    fetched += 1
                    let size = (try? await store.attachmentCacheSize()) ?? -1
                    QALaunch.log(
                        "fetchPart cid=\(part.contentID ?? "") part=\(part.id) bytes=\(part.sizeEstimate ?? -1) cache=\(size) url=\(url.lastPathComponent)"
                    )
                    if fetched >= 8 { break }
                }
                cursor = page.next
                if page.rows.isEmpty { break }
            } while fetched < 8 && cursor != nil
            let size = try await store.attachmentCacheSize()
            let cap = storeCacheCap()
            QALaunch.log("attachment cache after cid fetch size=\(size) cap=\(cap) files=\(urls.count)")
            if cap < MailStore.defaultAttachmentCacheCapBytes, size > cap {
                QALaunch.log("BUG attachment cache over cap size=\(size) cap=\(cap)")
            }
        } catch {
            QALaunch.log("fetchPart cid failed: \(error)")
        }
    }

    private func storeCacheCap() -> Int64 {
        QALaunch.parse()?.cacheCap ?? MailStore.defaultAttachmentCacheCapBytes
    }

    private func qaElapsed() -> String {
        String(format: "%.3f", Date().timeIntervalSince(qaStartedAt))
    }

    private func startFolderObservation(account: AccountID) {
        foldersTask?.cancel()
        foldersTask = Task { [weak self] in
            guard let self else { return }
            for await folders in self.store.observeFolders(account: account) {
                guard !Task.isCancelled else { return }
                self.foldersContinuation.yield(folders)
                let unread = folders.first(where: { $0.role == .inbox })?.unreadCount ?? 0
                self.notifications.setBadge(unread)
            }
        }
    }

    private func handleNewMail(_ event: NewMailEvent) {
        let visible = visibleFolderID == event.folder
        notifications.postNewMail(event, folderVisible: visible)
    }

    private func mapIMAPError(_ error: IMAPError, host: String) -> (state: AccountState, message: String) {
        switch error {
        case .auth:
            let message = "The username or password was rejected."
            return (.authFailed(message: message), message)
        case .tls:
            let message = "Could not establish a secure connection to \(host)."
            return (.connectionFailed(message: message), message)
        case .transport:
            let message = "Could not connect to \(host)."
            return (.connectionFailed(message: message), message)
        case .taggedNO(_, let message, _):
            let text = message.isEmpty ? "The username or password was rejected." : message
            return (.authFailed(message: text), text)
        case .taggedBAD(_, let message, _):
            let text = message.isEmpty ? "The server rejected the login." : message
            return (.connectionFailed(message: text), text)
        case .parse:
            let message = "Could not talk to \(host)."
            return (.connectionFailed(message: message), message)
        }
    }

    private func userPresentable(_ error: Error, host: String?) -> String {
        if let imap = error as? IMAPError {
            return mapIMAPError(imap, host: host ?? "the mail server").message
        }
        return error.localizedDescription
    }
}
