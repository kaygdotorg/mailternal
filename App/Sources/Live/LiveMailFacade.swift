import Foundation
import Observation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import MailternalSync

/// Progress for the detached SQLite open and migration operation.
///
/// `.opening` keeps the normal empty/loading shell visible. `.migrating`
/// drives the in-window migration card until the store becomes `.ready`.
enum StoreLoadState: Sendable, Equatable {
    case opening
    case migrating(completed: Int, total: Int, identifier: String)
    case ready
    case failed(message: String)
}

private struct StoreMigrationProgress: Sendable {
    let completed: Int
    let total: Int
    let identifier: String
}

private final class StoreOpenProgress: @unchecked Sendable {
    let stream: AsyncStream<StoreMigrationProgress>
    let continuation: AsyncStream<StoreMigrationProgress>.Continuation

    init() {
        let values = AsyncStream.makeStream(
            of: StoreMigrationProgress.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        stream = values.stream
        continuation = values.continuation
    }
}

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
@Observable
final class LiveMailFacade: MailFacade {
    private(set) var accounts: [AccountConfig] = [] {
        didSet { accountsContinuation.yield(accounts) }
    }
    private(set) var accountStates: [AccountID: AccountState] = [:] {
        didSet {
            accountStatesContinuation.yield(accountStates)
            accountContinuation.yield(aggregateState)
        }
    }
    private(set) var accountState: AccountState = .none
    var activeAccountID: AccountID? { accounts.first?.id }
    var accountConfig: AccountConfig? { accounts.first }
    var accountDisplayName: String? {
        guard let config = accounts.first else { return nil }
        let displayName = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? config.emailAddress : displayName
    }

    let accountsStream: AsyncStream<[AccountConfig]>
    let accountStatesStream: AsyncStream<[AccountID: AccountState]>
    let accountStateStream: AsyncStream<AccountState>
    let foldersStream: AsyncStream<[FolderSummary]>
    let syncStatusStream: AsyncStream<SyncStatus>

    private let accountsContinuation: AsyncStream<[AccountConfig]>.Continuation
    private let accountStatesContinuation: AsyncStream<[AccountID: AccountState]>.Continuation
    private let accountContinuation: AsyncStream<AccountState>.Continuation
    private let foldersContinuation: AsyncStream<[FolderSummary]>.Continuation
    private let syncContinuation: AsyncStream<SyncStatus>.Continuation

    private let container: MailternalContainer
    private let keychain: KeychainStore
    private let notifications: LiveNotificationService
    private var store: MailStore!
    private let storeTask: Task<MailStore, Error>
    private let storeProgress: StoreOpenProgress
    @ObservationIgnored private var storeProgressTask: Task<Void, Never>?
    /// Observable store-opening state used by the launch shell.
    var storeLoadState: StoreLoadState = .opening
    private var engines: [AccountID: SyncEngine] = [:]
    /// One process-wide permit pool keeps account engines from multiplying
    /// their backfill connections and gives queued accounts a fair turn.
    private let backfillBudget = BackfillConnectionBudget.shared
    private var configsByID: [AccountID: AccountConfig] = [:]
    private var observedFolders: [AccountID: [FolderSummary]] = [:]
    private var engineTasks: [AccountID: [Task<Void, Never>]] = [:]
    private var foldersTasks: [AccountID: Task<Void, Never>] = [:]
    private var visibleFolderID: FolderID?
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

    private var aggregateState: AccountState {
        guard !accounts.isEmpty else { return .none }
        let states = accounts.map { accountStates[$0.id] ?? .none }
        if states.contains(.active) { return .active }
        if states.contains(.validating) { return .validating }
        return states.first ?? .none
    }

    func accountState(for account: AccountID) -> AccountState {
        accountStates[account] ?? .none
    }

    init(
        container: MailternalContainer = .default,
        keychain: KeychainStore = KeychainStore(),
        enableNotifications: Bool = true,
        attachmentCacheCapBytes: Int64 = MailStore.defaultAttachmentCacheCapBytes,
        clientFactory: (any Sendable)? = nil
    ) throws {
        QAIMAPTrust.installIfRequested()
        self.container = container
        self.keychain = keychain
        self.testClientFactory = clientFactory
        self.notifications = LiveNotificationService(enabled: enableNotifications)

        let storeProgress = StoreOpenProgress()
        self.storeProgress = storeProgress
        self.storeTask = Task.detached(priority: .userInitiated) {
            defer { storeProgress.continuation.finish() }
            try container.prepare()
            return try MailStore(
                databaseURL: container.databaseURL,
                cachesDirectory: container.attachmentsDirectory,
                attachmentCacheCapBytes: attachmentCacheCapBytes,
                migrationProgress: { completed, total, identifier in
                    storeProgress.continuation.yield(
                        StoreMigrationProgress(
                            completed: completed,
                            total: total,
                            identifier: identifier
                        )
                    )
                }
            )
        }

        let accountsStreamValue = AsyncStream.makeStream(
            of: [AccountConfig].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let states = AsyncStream.makeStream(
            of: [AccountID: AccountState].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let account = AsyncStream.makeStream(of: AccountState.self, bufferingPolicy: .bufferingNewest(1))
        let folders = AsyncStream.makeStream(of: [FolderSummary].self, bufferingPolicy: .bufferingNewest(1))
        let sync = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(1))
        accountsStream = accountsStreamValue.stream
        accountStatesStream = states.stream
        accountStateStream = account.stream
        foldersStream = folders.stream
        syncStatusStream = sync.stream
        accountsContinuation = accountsStreamValue.continuation
        accountStatesContinuation = states.continuation
        accountContinuation = account.continuation
        foldersContinuation = folders.continuation
        syncContinuation = sync.continuation
        accountsStreamValue.continuation.yield([])
        states.continuation.yield([:])
        account.continuation.yield(.none)
        folders.continuation.yield([])
        sync.continuation.yield(SyncStatus(mode: .fullHistory, isOnline: false))

        self.storeProgressTask = Task { @MainActor [weak self, stream = storeProgress.stream] in
            for await progress in stream {
                guard let self, self.store == nil else { return }
                self.storeLoadState = .migrating(
                    completed: progress.completed,
                    total: progress.total,
                    identifier: progress.identifier
                )
            }
        }
    }
    /// Loads every persisted account and starts each enabled engine independently.
    func restorePersistedAccounts() async {
        guard !didRestore else { return }
        didRestore = true
        do {
            store = try await readyStore()
            if let qa = QALaunch.parse() {
                try await seedQAAccount(qa)
            }
            let persisted = try await store.fetchAccounts()
            accounts = persisted
            configsByID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
            for account in persisted {
                guard account.isEnabled else {
                    setState(.none, for: account.id)
                    continue
                }
                if (try? keychain.loadPassword(for: account.id)) == nil {
                    setState(.authFailed(message: "The saved password is missing from the Keychain."), for: account.id)
                    startFolderObservation(account: account.id)
                    continue
                }
                startFolderObservation(account: account.id)
                setState(.validating, for: account.id)
                await startEngine(for: account)
                startQAMonitorIfNeeded(account: account.id)
            }
            publishAggregateState()
        } catch {
            let id = persistedAccountID ?? AccountID(rawValue: "account")
            setState(.connectionFailed(message: userPresentable(error, host: configsByID[id]?.imap.host)), for: id)
        }
    }

    /// Waits for the detached database open and migration task.
    ///
    /// The launch shell uses this before restoring accounts so account reads
    /// cannot race the migration. Store work remains off the main actor.
    func waitUntilStoreReady() async {
        _ = try? await readyStore()
    }

    private func readyStore() async throws -> MailStore {
        if let store { return store }
        do {
            let opened = try await storeTask.value
            store = opened
            storeProgressTask?.cancel()
            storeLoadState = .ready
            #if DEBUG
            QALaunch.launchPhase("store-open")
            #endif
            return opened
        } catch {
            storeLoadState = .failed(message: error.localizedDescription)
            throw error
        }
    }

    /// Compatibility entry point retained for the QA and launch seams.
    func restorePersistedAccount() async {
        await restorePersistedAccounts()
    }

    private var persistedAccountID: AccountID? { accounts.first?.id }

    func reportVisibleFolder(_ id: FolderID?) {
        visibleFolderID = id
        let accountID = id.flatMap { folderAccountID($0) }
        Task { [weak self] in
            guard let self else { return }
            if let accountID {
                await engines[accountID]?.reportVisibleFolder(id)
            }
        }
    }

    func setKeepLocally(_ keep: Bool, for folder: FolderID) async throws {
        _ = try await readyStore()
        try await store.setKeepLocally(keep, for: folder)
        if let accountID = folderAccountID(folder) {
            await engines[accountID]?.setKeepLocally(keep, for: folder)
        }
    }

    /// Persists a mailbox rename before waking the owning engine. The facade
    /// never reaches into IMAP directly; SyncEngine drains the durable queue.
    func renameFolder(_ id: FolderID, to name: String) async throws {
        _ = try await readyStore()
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            throw LiveMailError("A folder name is required.")
        }
        guard let summary = try await store.fetchFolderSummary(id) else {
            throw LiveMailError("That folder is no longer available.")
        }
        try await store.enqueueFolderRename(folder: id, to: targetName)
        await engines[summary.accountID]?.refreshNow()
    }
    func shutdown() async {
        qaMonitorTask?.cancel()
        qaMonitorTask = nil
        for id in Array(engines.keys) {
            await stopEngine(for: id)
        }
    }

    func addAccount(_ config: AccountConfig, password: String) async throws {
        _ = try await readyStore()
        if config.isEnabled {
            setState(.validating, for: config.id)
            do {
                try await validate(config, password: password)
            } catch {
                let message = userPresentable(error, host: config.imap.host)
                if let imapError = error as? IMAPError,
                   case .auth = imapError {
                    setState(.authFailed(message: message), for: config.id)
                } else {
                    setState(.connectionFailed(message: message), for: config.id)
                }
                throw error
            }
        }

        var storedConfig = config
        if let existing = try await store.fetchAccount(config.id) {
            storedConfig.accountLinkID = existing.accountLinkID
        }
        do {
            try keychain.savePassword(password, for: storedConfig.id)
            try await store.upsertAccount(storedConfig)
        } catch {
            try? keychain.deletePassword(for: storedConfig.id)
            let message = "Could not save the account."
            setState(.connectionFailed(message: message), for: storedConfig.id)
            throw LiveMailError(message)
        }

        if engines[storedConfig.id] != nil {
            await stopEngine(for: storedConfig.id)
        }
        configsByID[storedConfig.id] = storedConfig
        if let index = accounts.firstIndex(where: { $0.id == storedConfig.id }) {
            accounts[index] = storedConfig
        } else {
            accounts.append(storedConfig)
        }
        guard storedConfig.isEnabled else {
            setState(.none, for: storedConfig.id)
            return
        }
        startFolderObservation(account: storedConfig.id)
        setState(.validating, for: storedConfig.id)
        await startEngine(for: storedConfig)
    }

    func updateAccount(_ config: AccountConfig, password: String?) async throws {
        _ = try await readyStore()
        guard let existing = configsByID[config.id] ?? accounts.first(where: { $0.id == config.id }) else {
            throw LiveMailError("That account is no longer available.")
        }
        var storedConfig = config
        storedConfig.accountLinkID = existing.accountLinkID
        storedConfig.isEnabled = existing.isEnabled
        let requiresValidation =
            existing.emailAddress != storedConfig.emailAddress
            || existing.username != storedConfig.username
            || existing.imap != storedConfig.imap
            || password != nil

        if requiresValidation {
            let validationPassword: String
            do {
                validationPassword = try password ?? keychain.loadPassword(for: existing.id)
            } catch {
                let message = "The saved password is missing from the Keychain."
                setState(.authFailed(message: message), for: existing.id)
                throw LiveMailError(message)
            }
            setState(.validating, for: existing.id)
            do {
                try await validate(storedConfig, password: validationPassword)
            } catch {
                let message = userPresentable(error, host: storedConfig.imap.host)
                setState(.connectionFailed(message: message), for: existing.id)
                throw error
            }
            if let password {
                try keychain.savePassword(password, for: existing.id)
            }
        }

        do {
            try await store.upsertAccount(storedConfig)
        } catch {
            setState(.connectionFailed(message: "Could not save the account."), for: existing.id)
            throw LiveMailError("Could not save the account.")
        }
        configsByID[storedConfig.id] = storedConfig
        if let index = accounts.firstIndex(where: { $0.id == storedConfig.id }) {
            accounts[index] = storedConfig
        }
        if !storedConfig.isEnabled {
            await stopEngine(for: existing.id)
            setState(.none, for: existing.id)
            return
        }
        guard requiresValidation else {
            setState(.active, for: existing.id)
            return
        }
        await stopEngine(for: existing.id)
        startFolderObservation(account: existing.id)
        await startEngine(for: storedConfig)
    }

    func setAccountEnabled(_ id: AccountID, _ enabled: Bool) async throws {
        _ = try await readyStore()
        guard var config = configsByID[id] ?? accounts.first(where: { $0.id == id }) else {
            throw LiveMailError("That account is no longer available.")
        }
        guard config.isEnabled != enabled else { return }
        config.isEnabled = enabled
        do {
            try await store.upsertAccount(config)
        } catch {
            throw LiveMailError("Could not save the account.")
        }
        configsByID[id] = config
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index] = config
        }
        if !enabled {
            await stopEngine(for: id)
            setState(.none, for: id)
            return
        }
        if (try? keychain.loadPassword(for: id)) == nil {
            setState(.authFailed(message: "The saved password is missing from the Keychain."), for: id)
            startFolderObservation(account: id)
            return
        }
        startFolderObservation(account: id)
        setState(.validating, for: id)
        await startEngine(for: config)
        startQAMonitorIfNeeded(account: id)
    }

    func removeAccount(_ id: AccountID) async throws {
        _ = try await readyStore()
        await stopEngine(for: id)
        try keychain.deletePassword(for: id)
        try await store.deleteAccount(id)
        configsByID[id] = nil
        accounts.removeAll { $0.id == id }
        observedFolders[id] = nil
        accountStates[id] = nil
        publishFolders()
        if accounts.isEmpty {
            visibleFolderID = nil
            syncContinuation.yield(SyncStatus(mode: .fullHistory, isOnline: false))
            notifications.setBadge(0)
            await container.wipeAttachmentFiles()
        }
        publishAggregateState()
    }

    func page(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) async throws -> MessagePage {
        _ = try await readyStore()
        return try await store.page(in: folder, after: cursor, limit: limit)
    }

    func messageIDs(in folder: FolderID) async throws -> [MessageID] {
        _ = try await readyStore()
        return try await store.messageIDs(in: folder)
    }

    func observePage(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) -> AsyncStream<MessagePage> {
        AsyncStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let store = try await self.readyStore()
                    for await page in store.observePage(in: folder, after: cursor, limit: limit) {
                        guard !Task.isCancelled else { break }
                        continuation.yield(page)
                    }
                } catch {
                    // Store failures are surfaced through storeLoadState.
                }
                continuation.finish()
            }
        }
    }

    func detail(_ id: MessageID) async throws -> MessageDetail {
        _ = try await readyStore()
        return try await store.detail(id)
    }
    func makeDeepLink(for folder: FolderID) async throws -> MailternalDeepLink? {
        _ = try await readyStore()
        guard let account = try await store.accountID(for: folder) else { return nil }
        return try await store.makeDeepLink(account: account, folder: folder)
    }

    func makeDeepLink(for message: MessageID) async throws -> MailternalDeepLink? {
        _ = try await readyStore()
        guard let account = try await store.accountID(for: message) else { return nil }
        return try await store.makeDeepLink(account: account, message: message)
    }

    func resolve(_ link: MailternalDeepLink) async throws -> MailternalDeepLinkResolution? {
        _ = try await readyStore()
        return try await store.resolve(link)
    }

    func markRead(_ ids: [MessageID]) async {
        guard let store = try? await readyStore() else { return }
        try? await store.enqueueFlag(messages: ids, flag: .seen, set: true)
    }

    func markUnread(_ ids: [MessageID]) async {
        guard let store = try? await readyStore() else { return }
        try? await store.enqueueFlag(messages: ids, flag: .seen, set: false)
    }

    func trash(_ ids: [MessageID]) async {
        await moveToRole(.trash, ids: ids)
    }

    func setFlagged(_ ids: [MessageID], _ flagged: Bool) async {
        guard let store = try? await readyStore() else { return }
        try? await store.enqueueFlag(messages: ids, flag: .flagged, set: flagged)
    }

    func archive(_ ids: [MessageID]) async {
        await moveToRole(.archive, ids: ids)
    }
    private func moveToRole(_ role: FolderRole, ids: [MessageID]) async {
        guard let store = try? await readyStore() else { return }
        let destinations = await roleDestinations(role)
        var grouped: [FolderID: [MessageID]] = [:]
        for id in ids {
            do {
                guard let accountID = try await store.accountID(for: id),
                      let destination = destinations[accountID] else { continue }
                grouped[destination, default: []].append(id)
            } catch {
                await logMoveError(error)
            }
        }
        for (destination, messageIDs) in grouped {
            do {
                try await store.enqueueMove(messages: messageIDs, to: destination)
                if let accountID = destinations.first(where: { $0.value == destination })?.key {
                    await engines[accountID]?.refreshNow()
                }
            } catch {
                await logMoveError(error, folder: destination)
            }
        }
    }

    func move(_ ids: [MessageID], to folder: FolderID) async throws -> MoveOutcome {
        _ = try await readyStore()
        let destinationAccount: AccountID
        do {
            guard let account = try await store.accountID(for: folder) else {
                throw LiveMailError("That destination folder is no longer available.")
            }
            destinationAccount = account
        } catch {
            throw await loggedMoveError(error, folder: folder)
        }

        var eligible: [MessageID] = []
        var skippedCrossAccount = 0
        for id in ids {
            do {
                guard let messageAccount = try await store.accountID(for: id) else {
                    throw LiveMailError("That message is no longer available.")
                }
                if messageAccount == destinationAccount {
                    eligible.append(id)
                } else {
                    skippedCrossAccount += 1
                }
            } catch {
                throw await loggedMoveError(error, account: destinationAccount, folder: folder)
            }
        }

        if skippedCrossAccount > 0 {
            try await store.recordError(
                StoreLogEntry(
                    kind: .archive,
                    account: destinationAccount,
                    folder: folder,
                    message: "Messages can only be moved within the same account",
                    detail: "\(skippedCrossAccount) message(s) skipped"
                )
            )
        }
        guard !eligible.isEmpty else {
            return MoveOutcome(
                movedCount: 0,
                skippedCrossAccountCount: skippedCrossAccount
            )
        }

        do {
            try await store.enqueueMove(messages: eligible, to: folder)
        } catch {
            throw await loggedMoveError(error, account: destinationAccount, folder: folder)
        }
        await engines[destinationAccount]?.refreshNow()
        return MoveOutcome(
            movedCount: eligible.count,
            skippedCrossAccountCount: skippedCrossAccount,
            acceptedIDs: Set(eligible)
        )
    }

    private func logMoveError(
        _ error: Error,
        account: AccountID? = nil,
        folder: FolderID? = nil
    ) async {
        guard let store = try? await readyStore() else { return }
        do {
            try await store.recordError(
                StoreLogEntry(
                    kind: .archive,
                    account: account,
                    folder: folder,
                    message: "move failed",
                    detail: String(describing: error)
                )
            )
        } catch {
            QALaunch.log("move error log failed: \(error)")
        }
    }

    private func loggedMoveError(
        _ error: Error,
        account: AccountID? = nil,
        folder: FolderID? = nil
    ) async -> Error {
        await logMoveError(error, account: account, folder: folder)
        return error
    }

    private func roleDestinations(_ role: FolderRole) async -> [AccountID: FolderID] {
        guard let store = try? await readyStore() else { return [:] }
        var result: [AccountID: FolderID] = [:]
        for account in accounts {
            do {
                guard let folder = try await store.fetchFolders(account: account.id)
                    .first(where: { $0.role == role }) else { continue }
                result[account.id] = folder.id
            } catch {
                await logMoveError(error, account: account.id)
            }
        }
        return result
    }
    private func folderAccountID(_ folder: FolderID) -> AccountID? {
        observedFolders.values.lazy.flatMap { $0 }.first(where: { $0.id == folder })?.accountID
    }
    func rawSource(_ id: MessageID) async throws -> String {
        _ = try await readyStore()
        guard let accountID = try await store.accountID(for: id),
              let engine = engines[accountID] else {
            throw LiveMailError("Mail is not connected.")
        }
        return try await performOnDemandFetch(accountID: accountID) {
            try await engine.rawSource(message: id)
        }
    }

    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL {
        _ = try await readyStore()
        guard let accountID = try await store.accountID(for: message),
              let engine = engines[accountID] else {
            throw LiveMailError("Mail is not connected.")
        }
        let spec = try await imapSection(for: message, part: part)
        return try await performOnDemandFetch(accountID: accountID) {
            try await engine.fetchPart(message: message, part: spec)
        }
    }

    /// UIDVALIDITY replacement: engine rejects the fetch; kick a delta so the
    /// folder snapshot refreshes, and surface a non-alarming error to the UI.
    private func performOnDemandFetch<T>(
        accountID: AccountID,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch SyncEngineError.staleMessage {
            await engines[accountID]?.refreshNow()
            throw LiveMailError(SyncEngineError.staleMessage.localizedDescription)
        }
    }

    /// `cid:` keys from the HTML handler map onto BODYSTRUCTURE part ids.
    private func imapSection(for message: MessageID, part: String) async throws -> String {
        _ = try await readyStore()
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
        _ = try await readyStore()
        return try await store.search(query, limit: limit)
    }

    func refresh() async {
        for engine in engines.values {
            await engine.refreshNow()
        }
    }

    func snapshotFolders() async throws -> [FolderSummary] {
        _ = try await readyStore()
        let persisted = try await store.fetchAccounts()
        var result: [FolderSummary] = []
        for account in persisted {
            result.append(contentsOf: try await store.fetchFolders(account: account.id))
        }
        return result
    }

    func snapshotErrorLog(limit: Int = 20) async throws -> [String] {
        _ = try await readyStore()
        return try await store.fetchErrorLog(limit: limit).map { entry in
            let detail = entry.detail.map { " \($0)" } ?? ""
            return "\(entry.kind.rawValue): \(entry.message)\(detail)"
        }
    }

    private func setState(_ state: AccountState, for account: AccountID) {
        accountStates[account] = state
        publishAggregateState()
    }

    private func publishAggregateState() {
        accountState = aggregateState
    }

    private func validate(_ config: AccountConfig, password: String) async throws {
        if password.isEmpty {
            throw LiveMailError("A password is required.")
        }
        let session = IMAPSession(
            endpoint: config.imap,
            username: config.username,
            password: password
        )
        do {
            try await session.connect()
            await session.close()
        } catch {
            throw error
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
                qaAmpleDisk: qa,
                backfillBudget: backfillBudget
            )
        } else {
            engine = SyncEngine(
                store: store,
                config: config,
                credentials: credentials,
                qaAmpleDisk: qa,
                backfillBudget: backfillBudget
            )
        }
        #else
        engine = SyncEngine(
            store: store,
            config: config,
            credentials: credentials,
            qaAmpleDisk: qa,
            backfillBudget: backfillBudget
        )
        #endif
        engines[config.id] = engine
        await engine.start()
        attachEngineStreams(engine, accountID: config.id)
    }
    private func stopEngine(for accountID: AccountID) async {
        foldersTasks[accountID]?.cancel()
        foldersTasks[accountID] = nil
        for task in engineTasks.removeValue(forKey: accountID) ?? [] {
            task.cancel()
        }
        if let engine = engines.removeValue(forKey: accountID) {
            await engine.stop()
        }
        observedFolders[accountID] = nil
        publishFolders()
    }

    private func attachEngineStreams(_ engine: SyncEngine, accountID: AccountID) {
        for task in engineTasks[accountID] ?? [] { task.cancel() }
        let statusTask = Task { [weak self] in
            let stream = await engine.status
            for await status in stream {
                guard let self else { return }
                self.syncContinuation.yield(status)
                if status.isOnline {
                    self.markActiveIfValidating(accountID)
                }
            }
        }
        let activityTask = Task { [weak self] in
            let stream = await engine.activity
            for await update in stream {
                self?.applyFolderActivity(update, accountID: accountID)
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
                self?.applyEngineFailure(failure, accountID: accountID)
            }
        }
        engineTasks[accountID] = [statusTask, activityTask, mailTask, failureTask]
    }
    private func applyFolderActivity(_ update: FolderActivityUpdate, accountID: AccountID) {
        guard var folders = observedFolders[accountID],
              let index = folders.firstIndex(where: { $0.id == update.folder })
        else { return }
        folders[index].activity = update.activity
        observedFolders[accountID] = folders
        publishFolders()
    }


    private func markActiveIfValidating(_ accountID: AccountID) {
        guard case .validating = accountState(for: accountID) else { return }
        setState(.active, for: accountID)
        notifications.requestAuthorizationIfNeeded()
    }

    private func applyEngineFailure(_ failure: SyncFailure, accountID: AccountID) {
        let host = configsByID[accountID]?.imap.host ?? "the mail server"
        switch failure {
        case .authentication:
            setState(.authFailed(message: "The username or password was rejected."), for: accountID)
        case .tls:
            setState(.connectionFailed(message: "Could not establish a secure connection to \(host)."), for: accountID)
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
            if launch.fetchCID, !qaCIDFetched, engines[account] != nil, let inbox, inbox.totalCount > 0 {
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
        foldersTasks[account]?.cancel()
        foldersTasks[account] = Task { [weak self] in
            guard let self else { return }
            for await folders in self.store.observeFolders(account: account) {
                guard !Task.isCancelled else { return }
                let prior = Dictionary(
                    uniqueKeysWithValues: (self.observedFolders[account] ?? []).map { ($0.id, $0.activity) }
                )
                let refreshed = folders.map { folder -> FolderSummary in
                    var folder = folder
                    if let activity = prior[folder.id] {
                        folder.activity = activity
                    }
                    return folder
                }
                self.observedFolders[account] = refreshed
                self.publishFolders()
                let unread = folders.first(where: { $0.role == .inbox })?.unreadCount ?? 0
                if self.accounts.count == 1 {
                    self.notifications.setBadge(unread)
                } else {
                    let totalUnread = self.observedFolders.values
                        .flatMap { $0 }
                        .filter { $0.role == .inbox }
                        .reduce(0) { $0 + $1.unreadCount }
                    self.notifications.setBadge(totalUnread)
                }
            }
        }
    }

    private func publishFolders() {
        let ordered = accounts
            .filter { $0.isEnabled }
            .flatMap { observedFolders[$0.id] ?? [] }
        foldersContinuation.yield(ordered)
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
