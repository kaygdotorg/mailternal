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

    init(
        container: MailternalContainer = .default,
        keychain: KeychainStore = KeychainStore(),
        enableNotifications: Bool = true
    ) throws {
        QAIMAPTrust.installIfRequested()
        try container.prepare()
        self.container = container
        self.keychain = keychain
        self.notifications = LiveNotificationService(enabled: enableNotifications)
        self.store = try MailStore(
            databaseURL: container.databaseURL,
            cachesDirectory: container.attachmentsDirectory
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
            guard let account = try await store.fetchAccounts().first else { return }
            config = account
            do {
                _ = try keychain.loadPassword(for: account.id)
            } catch {
                setState(.authFailed(message: "The saved password is missing from the Keychain."))
                return
            }
            setState(.validating)
            await startEngine(for: account)
            setState(.active)
            notifications.requestAuthorizationIfNeeded()
            startFolderObservation(account: account.id)
        } catch {
            setState(.connectionFailed(message: userPresentable(error, host: config?.imap.host)))
        }
    }

    func reportVisibleFolder(_ id: FolderID?) {
        visibleFolderID = id
    }

    func shutdown() async {
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

        do {
            try keychain.savePassword(password, for: config.id)
        } catch {
            let message = error.localizedDescription
            setState(.authFailed(message: message))
            throw LiveMailError(message)
        }
        do {
            try await store.upsertAccount(config)
        } catch {
            try? keychain.deletePassword(for: config.id)
            let message = "Could not save the account."
            setState(.connectionFailed(message: message))
            throw LiveMailError(message)
        }

        self.config = config
        await startEngine(for: config)
        setState(.active)
        notifications.requestAuthorizationIfNeeded()
        startFolderObservation(account: config.id)
    }

    func removeAccount() async throws {
        await stopEngine()
        if let id = config?.id {
            try keychain.deletePassword(for: id)
            try? await store.deleteAccount(id)
        }
        container.wipeAttachmentFiles()
        config = nil
        visibleFolderID = nil
        setState(.none)
        foldersContinuation.yield([])
        syncContinuation.yield(SyncStatus(mode: .fullHistory, isOnline: false))
        notifications.setBadge(0)
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

    func markRead(_ id: MessageID) async {
        try? await store.enqueueSeen(message: id)
    }

    func rawSource(_ id: MessageID) async throws -> String {
        guard let engine else {
            throw LiveMailError("Mail is not connected.")
        }
        return try await engine.rawSource(message: id)
    }

    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL {
        guard let engine else {
            throw LiveMailError("Mail is not connected.")
        }
        return try await engine.fetchPart(message: message, part: part)
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
        let engine = SyncEngine(
            store: store,
            config: config,
            credentials: credentials,
            qaAmpleDisk: qa
        )
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
            }
        }
        let mailTask = Task { [weak self] in
            let stream = await engine.newMail
            for await event in stream {
                self?.handleNewMail(event)
            }
        }
        engineTasks = [statusTask, mailTask]
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
