import AppKit
import Observation
import SwiftUI
import MailternalInterfaces
import os

private let appModelSignpostLog = OSLog(
    subsystem: "org.kayg.mailternal",
    category: "ReaderTabs"
)

private enum MailModelRouteError: LocalizedError {
    case messageUnavailable
    case linkUnavailable

    var errorDescription: String? {
        switch self {
        case .messageUnavailable:
            "That message is no longer available."
        case .linkUnavailable:
            "That item is no longer available."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private struct MessageDetailCache {
        private static let capacity = ReaderSurfacePool.defaultCapacity
        private var values: [MessageID: MessageDetail] = [:]
        private var mruIDs: [MessageID] = []

        mutating func value(for id: MessageID) -> MessageDetail? {
            guard let value = values[id] else { return nil }
            touch(id)
            return value
        }

        mutating func insert(
            _ value: MessageDetail,
            for id: MessageID,
            protectedIDs: Set<MessageID> = []
        ) {
            values[id] = value
            touch(id)
            trim(protectedIDs: protectedIDs)
        }

        mutating func removeValue(for id: MessageID) {
            values.removeValue(forKey: id)
            mruIDs.removeAll { $0 == id }
        }

        mutating func removeValues(notIn retainedIDs: Set<MessageID>) {
            let obsoleteIDs = values.keys.filter { !retainedIDs.contains($0) }
            for id in obsoleteIDs {
                removeValue(for: id)
            }
        }

        mutating func removeAll(keepingCapacity: Bool) {
            values.removeAll(keepingCapacity: keepingCapacity)
            mruIDs.removeAll(keepingCapacity: keepingCapacity)
        }

        private mutating func trim(protectedIDs: Set<MessageID>) {
            while mruIDs.count > Self.capacity,
                  let evictedIndex = mruIDs.lastIndex(where: { !protectedIDs.contains($0) }) {
                let evictedID = mruIDs.remove(at: evictedIndex)
                values.removeValue(forKey: evictedID)
            }
        }

        private mutating func touch(_ id: MessageID) {
            mruIDs.removeAll { $0 == id }
            mruIDs.insert(id, at: 0)
        }
    }

    /// Detail entries for tabs whose native surfaces are still retained are
    /// protected from message-list/transient browsing churn. The surface pool
    /// has the same bound, so this cannot make the detail cache grow.
    private var retainedDetailMessageIDs: Set<MessageID> {
        let retainedTabIDs = readerSurfacePool.retainedTabIDs
        return Set(
            tabs.tabs.compactMap { tab in
                retainedTabIDs.contains(tab.id) ? tab.message : nil
            }
        )
    }

    /// Retains fetched content while a reader tab is inactive, so activating
    /// a loaded tab does not issue another facade.detail request.
    @ObservationIgnored private var detailCache = MessageDetailCache()
    let facade: any MailFacade
    let appearance: AppearanceSettings
    let actions: ActionSettings
    let toasts = ToastPresenter()
    @ObservationIgnored private let faviconStore: FaviconStore
    private var faviconImages: [String: NSImage] = [:]
    /// Changes whenever a newly warmed favicon becomes available to AppKit
    /// rows. The cached image lookup itself remains synchronous.
    var faviconRevision: UInt64 = 0


    var accountState: AccountState = .none
    var accountStates: [AccountID: AccountState] = [:]
    var selectedFolderID: FolderID?
    var folders: [FolderSummary] = []
    var listScrollOffsets: [FolderID: CGFloat] = [:]
    var tabs: ReaderTabs
    /// Retained HTML and plain-text surfaces keyed by reader-tab identity. The
    /// pool is shared by the main reader (or one detached reader window) and
    /// bounds native reader memory independently from persisted tab metadata.
    let readerSurfacePool: ReaderSurfacePool
    /// The list's full selection. `selectedMessageID` remains the reader
    /// anchor so a single-message reader survives ordinary list updates.
    var selectedMessageIDs: Set<MessageID> = []
    var selectedMessageID: MessageID?
    var detail: MessageDetail? {
        didSet {
            guard EmailReadingOverridePolicy.resetsOverride(
                oldID: oldValue?.id,
                newID: detail?.id
            ) else { return }
            emailReadingOverride = nil
        }
    }
    var emailReadingOverride: EmailReadingMode?
    var rawSource: String?
    var isShowingRawSource = false
    var syncStatus = SyncStatus(mode: .fullHistory, isOnline: true)
    var isSearchPresented = false
    var isFindPresented = false
    var findQuery = ""
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// The last visible arrangement is restored after the sidebar is hidden.
    var lastVisibleColumnVisibility: NavigationSplitViewVisibility = .all
    var listRows: [MessageRow] = []
    var listCursor: MessagePageCursor?
    var isPaging = false
    var isLoadingList = false
    var listEpoch: UInt64 = 0
    var isLoadingDetail = false
    var allowRemoteImages = false
    /// Links are prepared while rows are loaded so AppKit's synchronous drag
    /// source can place canonical deep-link strings on its pasteboard.
    var messageDeepLinks: [MessageID: String] = [:]

    /// The effective reading mode for the current message. A per-message
    /// override never changes the persisted appearance setting.
    var effectiveEmailReadingMode: EmailReadingMode {
        emailReadingOverride ?? appearance.emailReadingMode
    }

    /// Whether the sanitized message contains an app-controlled remote-image
    /// token. The sanitizer computes this once when the detail is ingested.
    var hasRemoteImageReferences: Bool {
        detail?.hasRemoteImageReferences ?? false
    }
    /// Returns a previously warmed sender icon without starting synchronous
    /// work on the main actor. Reader-tab views trigger the async warmup.
    func favicon(forSenderDomain rawDomain: String) -> NSImage? {
        guard let domain = FaviconStore.normalizedDomain(rawDomain) else { return nil }
        return faviconImages[domain]
    }
    /// Fetches sender icons off the main actor and publishes positive results
    /// for the synchronous lookup used while rendering each tab and row.
    func warmupFavicons(forSenderDomains domains: [String]) async {
        let loaded = await faviconStore.warmup(domains: domains)
        guard !Task.isCancelled else { return }
        var changed = false
        for (domain, data) in loaded {
            guard let image = NSImage(data: data) else { continue }
            if faviconImages[domain] == nil {
                faviconImages[domain] = image
                changed = true
            }
        }
        if changed {
            faviconRevision &+= 1
        }
    }



    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var deepLinkQueue = DeepLinkRouteQueue()
    @ObservationIgnored private var foldersSnapshotReady = false
    @ObservationIgnored private var qaLaunchFoldersLogged = false
    @ObservationIgnored private var streamsStarted = false
    @ObservationIgnored private var markedRead: Set<MessageID> = []
    @ObservationIgnored private var qaSelectionSequence: UInt64 = 0
    @ObservationIgnored private var tabSaveTask: Task<Void, Never>?
    @ObservationIgnored private var tabRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var tabExistenceTask: Task<Void, Never>?
    @ObservationIgnored private var tabsRestored = false
    @ObservationIgnored private var isSyncingTabSelection = false
#if DEBUG
    @ObservationIgnored private var qaContextMenuDumped = false
#endif

    var selectedFolder: FolderSummary? {
        folders.first { $0.id == selectedFolderID }
    }

    /// Display name shown by the message-list title when it is flipped to the
    /// owning account.
    /// Display name shown by the message-list title when it is flipped to the
    /// owning account. Folder identity, not a global active-account pointer,
    /// determines which title is shown.
    var listTitleAccountName: String {
        let config = selectedFolder.flatMap { folder in
            accountConfigs.first(where: { $0.id == folder.accountID })
        } ?? accountConfig
        if let accountTitle = AccountTitlePolicy.title(for: config) {
            return accountTitle
        }
        return "Account"
    }

    /// The persisted non-secret values used to populate account editors.
    var accountConfig: AccountConfig? {
        accountConfigs.first
    }

    var accountConfigs: [AccountConfig] = []

    var hasAccount: Bool {
        !accountConfigs.isEmpty
    }

    var isAccountActive: Bool {
        accountStates.values.contains(.active) || accountState == .active
    }

    init(
        facade: any MailFacade,
        appearance: AppearanceSettings,
        actions: ActionSettings,
        faviconStore: FaviconStore = FaviconStore()
    ) {
        self.facade = facade
        self.appearance = appearance
        self.actions = actions
        self.faviconStore = faviconStore
        let pool = ReaderSurfacePool()
        self.readerSurfacePool = pool
        self.tabs = ReaderTabs()
        accountState = facade.accountState
        accountStates = facade.accountStates
        accountConfigs = facade.accounts
        tabs.onChange = { [weak self] in
            self?.scheduleTabsPersistence()
        }
        pool.onEvict = { [weak self] _ in
            guard let self else { return }
            self.detailCache.removeValues(notIn: self.retainedDetailMessageIDs)
        }
        tabs.onClose = { [weak self, weak pool] id in
            pool?.drop(id)
            guard let self else { return }
            self.detailCache.removeValues(notIn: self.retainedDetailMessageIDs)
        }
    }
    /// malformed URLs can never reach account or folder selection.
    func openURL(_ url: URL) {
        guard let link = MailternalDeepLink(url: url) else {
            toasts.post(
                title: "Couldn’t open link",
                detail: "That link is malformed or unsupported.",
                severity: .error
            )
            return
        }
        deepLinkQueue.enqueue(
            link,
            isReady: { [weak self] in
                guard let self else { return false }
                return self.isAccountActive && self.foldersSnapshotReady
            },
            route: { [weak self] link in
                await self?.route(link)
            }
        )
    }

    private func route(_ link: MailternalDeepLink) async {
        do {
            guard !Task.isCancelled else { return }
            guard let resolution = try await facade.resolve(link) else {
                toasts.post(
                    title: "Couldn’t open link",
                    detail: "That account, folder, or message is no longer available.",
                    severity: .error
                )
                return
            }
            guard !Task.isCancelled else { return }
            switch resolution {
            case .folder(let folderID):
                prepareFolderForRoute(folderID)
            case .message(let folderID, let messageID, _):
                try await routeMessage(
                    folderID: folderID,
                    messageID: messageID
                )
            }
            guard !Task.isCancelled else { return }
            MainWindowController.shared.show(model: self, appearance: appearance, actions: actions)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            toasts.post(
                title: "Couldn’t open link",
                detail: error.localizedDescription,
                severity: .error
            )
        }
    }

    /// Renames an account from any surface (settings row, sidebar title). The
    /// stored value comes back through `accountsStream`, so callers never
    /// patch `accountConfigs` themselves. Returns false when nothing changed.
    @discardableResult
    func renameAccount(_ id: AccountID, to input: String) async -> Bool {
        guard let account = accountConfigs.first(where: { $0.id == id }) else { return false }
        let committed = AccountTitlePolicy.committedName(input: input, email: account.emailAddress)
        guard account.displayName != committed else { return false }
        var updated = account
        updated.displayName = committed
        do {
            try await facade.updateAccount(updated, password: nil)
            return true
        } catch {
            toasts.post(
                title: "Couldn’t rename account",
                detail: error.localizedDescription,
                severity: .error
            )
            return false
        }
    }

    /// Trims and validates a folder rename before handing it to the facade.
    /// Facades own persistence and server mutation; this model only surfaces
    /// failures to the transient toast presenter.
    @discardableResult
    func renameFolder(_ id: FolderID, to input: String) async -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let folder = folders.first(where: { $0.id == id }),
              folder.name != name
        else {
            return false
        }
        do {
            try await facade.renameFolder(id, to: name)
            return true
        } catch {
            toasts.post(
                title: "Couldn’t rename folder",
                detail: error.localizedDescription,
                severity: .error
            )
            return false
        }
    }

    private func prepareFolderForRoute(_ folderID: FolderID) {
        if selectedFolderID == folderID {
            pageTask?.cancel()
            selectedMessageIDs.removeAll()
            selectedMessageID = nil
            detail = nil
            rawSource = nil
            isShowingRawSource = false
            listRows = []
            listCursor = nil
            messageDeepLinks.removeAll()
            listEpoch += 1
            return
        }
        selectFolder(folderID)
    }

    private func routeMessage(
        folderID: FolderID,
        messageID: MessageID
    ) async throws {
        var cursor: MessagePageCursor?
        var loaded: [MessageRow] = []
        repeat {
            let page = try await facade.page(
                in: folderID,
                after: cursor,
                limit: MessageListPrefetch.pageSize
            )
            guard !Task.isCancelled else { return }
            loaded.append(contentsOf: page.rows)
            if page.rows.contains(where: { $0.id == messageID }) {
                guard !Task.isCancelled else { return }
                prepareFolderForRoute(folderID)
                listRows = loaded
                listCursor = page.next
                openMessage(messageID, permanent: false)
                return
            }
            cursor = page.next
        } while cursor != nil

        // A concurrent expunge or generation replacement can invalidate a
        // resolved row before paging reaches it; do not select a substitute.
        throw MailModelRouteError.messageUnavailable
    }

    func start() {
        guard !streamsStarted else { return }
        streamsStarted = true
        Task { [weak self] in
            guard let self else { return }
            if let live = facade as? LiveMailFacade {
                await live.waitUntilStoreReady()
                await live.restorePersistedAccounts()
            }
            accountConfigs = facade.accounts
            accountStates = facade.accountStates
            applyAccountState(facade.accountState)
            Task { [weak self] in
                guard let self else { return }
                for await accounts in facade.accountsStream {
                    self.accountConfigs = accounts
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await states in facade.accountStatesStream {
                    self.applyAccountStates(states)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await folders in facade.foldersStream {
                    self.folders = folders
                    if !qaLaunchFoldersLogged && !folders.isEmpty {
                        qaLaunchFoldersLogged = true
                        QALaunch.launchPhase("folders-snapshot")
                        MainWindowController.noteLaunchDataPhase("folders-snapshot")
                    }
                    self.foldersSnapshotReady = true
                    if selectedFolderID == nil, let inbox = folders.first(where: { $0.role == .inbox }) {
                        selectFolder(inbox.id)
                    } else if let selectedFolderID, folders.contains(where: { $0.id == selectedFolderID }) {
                        // keep
                    } else if let first = folders.first {
                        selectFolder(first.id)
                    } else if selectedFolderID != nil {
                        selectFolder(nil)
                    }
                    self.restoreTabsIfNeeded()
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await status in facade.syncStatusStream {
                    syncStatus = status
                }
            }
            startTabExistenceObservation()
            if accountConfigs.isEmpty {
                #if DEBUG
                if QALaunch.parse() != nil { return }
                #endif
                SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
            }
        }
    }

    func applyAccountStates(_ states: [AccountID: AccountState]) {
        accountStates = states
        let aggregate: AccountState
        if accountConfigs.isEmpty {
            aggregate = .none
        } else {
            let values = accountConfigs.map { states[$0.id] ?? .none }
            aggregate = values.contains(.active) ? .active
                : values.contains(.validating) ? .validating
                : values.first ?? .none
        }
        applyAccountState(aggregate)
    }

    func applyAccountState(_ state: AccountState) {
        let previous = accountState
        accountState = state
        switch state {
        case .none:
            foldersSnapshotReady = false
            folders = []
            selectedFolderID = nil
            selectedMessageIDs.removeAll()
            selectedMessageID = nil
            detailCache.removeAll(keepingCapacity: false)
            detail = nil
            listRows = []
            messageDeepLinks.removeAll()
            SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
        case .authFailed(let message):
            foldersSnapshotReady = false
            toasts.post(title: "Couldn’t sign in", detail: message, severity: .error)
            SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
        case .connectionFailed(let message):
            foldersSnapshotReady = false
            toasts.post(title: "Couldn’t connect", detail: message, severity: .error)
            SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
        case .active:
            if case .active = previous { break }
            else { /* folders stream will populate */ }
        case .validating:
            foldersSnapshotReady = false
        }
    }

    func selectFolder(_ id: FolderID?) {
        guard selectedFolderID != id else { return }
        selectedFolderID = id
        (facade as? LiveMailFacade)?.reportVisibleFolder(id)
        selectedMessageIDs.removeAll()
        selectedMessageID = nil
        if tabs.active == nil {
            clearReaderSelection()
        }
        listRows = []
        listCursor = nil
        messageDeepLinks.removeAll()
        isLoadingList = id != nil
        listEpoch += 1
        observeTask?.cancel()
        pageTask?.cancel()
        guard let id else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            for await page in facade.observePage(in: id, after: nil, limit: MessageListPrefetch.pageSize) {
                guard !Task.isCancelled, selectedFolderID == id else { return }
                applyFirstPage(page)
                isLoadingList = false
            }
            if selectedFolderID == id {
                isLoadingList = false
            }
        }
    }

    func loadMoreIfNeeded(near row: Int) {
        guard MessageListPrefetch.shouldLoadMore(
            near: row,
            loadedCount: listRows.count,
            hasMore: listCursor != nil,
            isPaging: isPaging
        ), let folder = selectedFolderID else { return }
        isPaging = true
        pageTask?.cancel()
        let cursor = listCursor
        pageTask = Task { [weak self] in
            guard let self else { return }
            defer { isPaging = false }
            do {
                let page = try await facade.page(in: folder, after: cursor, limit: MessageListPrefetch.pageSize)
                guard !Task.isCancelled, selectedFolderID == folder else { return }
                appendPage(page)
            } catch {
                isLoadingList = false
                toasts.post(title: "Couldn’t load messages", detail: error.localizedDescription)
            }
        }
    }

    /// Updates list selection without disturbing the active reader tab when
    /// several rows are selected. The reader remains a single-message surface;
    /// list actions continue to consume the complete selectedMessageIDs set.
    func selectMessages(_ ids: Set<MessageID>, anchor: MessageID? = nil) {
        guard !ids.isEmpty else {
            selectMessage(nil)
            return
        }
        selectedMessageIDs = ids
        guard ids.count == 1 else { return }
        let retainedAnchor = selectedMessageID.flatMap { ids.contains($0) ? $0 : nil }
        selectedMessageID = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? retainedAnchor ?? ids.first
        guard let selectedMessageID else { return }
        loadMessageDetail(selectedMessageID)
    }

    /// Selects the complete current live generation, rather than only the
    /// page currently materialized by the virtualized table.
    func selectAllMessages() {
        guard let folder = selectedFolderID else { return }
        let epoch = listEpoch
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await facade.messageIDs(in: folder)
                guard !Task.isCancelled, selectedFolderID == folder, listEpoch == epoch else { return }
                selectMessages(Set(ids), anchor: selectedMessageID)
            } catch {
                guard !Task.isCancelled, selectedFolderID == folder, listEpoch == epoch else { return }
                toasts.post(title: "Couldn’t select messages", detail: error.localizedDescription)
            }
        }
    }

    func selectMessage(_ id: MessageID?) {
        selectedMessageIDs = id.map { [$0] } ?? []
        selectedMessageID = id
        guard let id else {
            clearReaderSelection()
            return
        }
        loadMessageDetail(id)
    }

    private func loadMessageDetail(_ id: MessageID) {
        qaSelectionSequence &+= 1
        let qaSelection = qaSelectionSequence
        let signpostID = OSSignpostID(log: appModelSignpostLog)
        os_signpost(
            .begin,
            log: appModelSignpostLog,
            name: "loadMessageDetail",
            signpostID: signpostID,
            "message=%{public}s",
            String(id.rawValue)
        )
        #if DEBUG
        if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
            QALaunch.log(
                "selection-perf event=select serial=\(qaSelection) t=\(DispatchTime.now().uptimeNanoseconds)"
            )
        }
        #endif
        isShowingRawSource = false
        rawSource = nil
        isFindPresented = false
        findQuery = ""
        let retainedRemoteImages = tabs.activeID.flatMap { tabID -> Bool? in
            guard tabs.active?.message == id else { return nil }
            return readerSurfacePool.remoteImagesAllowed(for: tabID)
        } ?? false
        allowRemoteImages = retainedRemoteImages
        isLoadingDetail = true
        if let cached = detailCache.value(for: id) {
            presentDetail(
                cached,
                id: id,
                selection: qaSelection,
                source: "cache",
                signpostID: signpostID
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await facade.detail(id)
                presentDetail(
                    loaded,
                    id: id,
                    selection: qaSelection,
                    source: "facade",
                    signpostID: signpostID
                )
            } catch {
                os_signpost(
                    .end,
                    log: appModelSignpostLog,
                    name: "loadMessageDetail",
                    signpostID: signpostID,
                    "result=error"
                )
                guard !Task.isCancelled,
                      isReaderRequestCurrent(id) else { return }
                closeUnavailableTab(messageID: id)
            }
        }
    }

    private func presentDetail(
        _ loaded: MessageDetail,
        id: MessageID,
        selection: UInt64,
        source: String,
        signpostID: OSSignpostID
    ) {
        detailCache.insert(
            loaded,
            for: id,
            protectedIDs: retainedDetailMessageIDs
        )
        os_signpost(
            .end,
            log: appModelSignpostLog,
            name: "loadMessageDetail",
            signpostID: signpostID,
            "result=%{public}s",
            source
        )
        guard isReaderRequestCurrent(id) else { return }
        detail = loaded
        isLoadingDetail = false
        let senderDomains = loaded.envelope.from.compactMap { address in
            address.address.split(separator: "@", omittingEmptySubsequences: true).last.map(String.init)
        }
        if !senderDomains.isEmpty {
            Task { [weak self] in
                await self?.warmupFavicons(forSenderDomains: senderDomains)
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
            QALaunch.log(
                "selection-perf event=detail serial=\(selection) source=\(source) t=\(DispatchTime.now().uptimeNanoseconds)"
            )
        }
        #endif
        markRead(id)
    }


    /// Folder navigation clears list selection, not the independently owned
    /// active reader tab. Detached readers still use the direct selection path.
    private func isReaderRequestCurrent(_ id: MessageID) -> Bool {
        tabs.active?.message == id
            || (selectedMessageID == id && selectedMessageIDs == Set([id]))
    }

    private func clearReaderSelection() {
        detail = nil
        isLoadingDetail = false
        rawSource = nil
        isShowingRawSource = false
        isFindPresented = false
        findQuery = ""
        allowRemoteImages = false
    }
    #if DEBUG
    /// QA-only selection benchmark. It exercises the same model path used by
    /// list selection without requiring an AppKit window or synthetic events.
    func runQABenchSelect(count: Int) {
        guard count > 0 else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let waitDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while (!foldersSnapshotReady || listRows.isEmpty), ContinuousClock.now < waitDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let folder = selectedFolderID else {
                QALaunch.log("selection-perf bench unavailable reason=no-folder")
                return
            }
            do {
                let page = try await facade.page(
                    in: folder,
                    after: nil,
                    limit: count
                )
                let ids = page.rows.prefix(count).map(\.id)
                guard !ids.isEmpty else {
                    QALaunch.log("selection-perf bench unavailable reason=no-messages")
                    return
                }
                let clock = ContinuousClock()
                var samples: [Double] = []
                samples.reserveCapacity(ids.count)
                for (offset, id) in ids.enumerated() {
                    let started = clock.now
                    selectMessage(id)
                    while detail?.id != id {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                    _ = hasRemoteImageReferences
                    let elapsed = started.duration(to: clock.now)
                    let components = elapsed.components
                    let milliseconds = Double(components.seconds) * 1_000
                        + Double(components.attoseconds) / 1_000_000_000_000_000
                    samples.append(milliseconds)
                    QALaunch.log(
                        "selection-perf bench event=rendered serial=\(offset + 1) ms=\(String(format: "%.3f", milliseconds))"
                    )
                }
                samples.sort()
                let p50 = samples[(samples.count - 1) / 2]
                let p95 = samples[min(samples.count - 1, (samples.count * 95) / 100)]
                QALaunch.log(
                    "selection-perf bench n=\(samples.count) p50=\(String(format: "%.3f", p50))ms p95=\(String(format: "%.3f", p95))ms"
                )
            } catch {
                QALaunch.log("selection-perf bench unavailable reason=\(error.localizedDescription)")
            }
        }
    }
    #endif


    /// Marks a visible message read immediately and lets the sync engine
    /// persist the operation through its write queue.
    func markRead(_ id: MessageID) {
        guard let index = listRows.firstIndex(where: { $0.id == id }),
              !listRows[index].isRead else { return }
        var row = listRows[index]
        row.isRead = true
        listRows[index] = row
        markedRead.insert(id)
        Task { [weak self] in
            await self?.facade.markRead(id)
        }
    }

    func perform(_ kind: SwipeActionKind, on id: MessageID) {
        perform(kind, on: [id])
    }

    /// Performs one gesture/menu operation as a single persisted batch.
    func perform(_ kind: SwipeActionKind, on ids: Set<MessageID>) {
        guard !ids.isEmpty else { return }
        let visibleIDs = ids.filter { id in listRows.contains { $0.id == id } }
        let orderedIDs = ids.sorted { $0.rawValue < $1.rawValue }
        switch kind {
        case .archive:
            guard let destination = destinationFolder(for: .archive) else { return }
            move(ids: ids, to: destination)
        case .trash:
            guard let destination = destinationFolder(for: .trash) else { return }
            move(ids: ids, to: destination)
        case .toggleRead:
            let shouldRead = visibleIDs.isEmpty || visibleIDs.contains { id in
                !(listRows.first(where: { $0.id == id })?.isRead ?? false)
            }
            for index in listRows.indices where visibleIDs.contains(listRows[index].id) {
                listRows[index].isRead = shouldRead
            }
            Task { [weak self] in
                if shouldRead {
                    await self?.facade.markRead(orderedIDs)
                } else {
                    await self?.facade.markUnread(orderedIDs)
                }
            }
        case .toggleFlag:
            let shouldFlag = visibleIDs.isEmpty || visibleIDs.contains { id in
                !(listRows.first(where: { $0.id == id })?.isFlagged ?? false)
            }
            for index in listRows.indices where visibleIDs.contains(listRows[index].id) {
                listRows[index].isFlagged = shouldFlag
            }
            Task { [weak self] in
                await self?.facade.setFlagged(orderedIDs, shouldFlag)
            }
        }
    }

    /// Optimistically removes rows while keeping reader content for any
    /// message represented by an open tab. A move/archive is a list
    /// membership change, not a deletion: the tab remains the source of
    /// truth for its cached detail while the facade updates its folder.
    private func removeListRows(_ ids: Set<MessageID>) {
        let previousAnchor = selectedMessageID
        let anchorRemoved = previousAnchor.map(ids.contains) ?? false
        listRows.removeAll { ids.contains($0.id) }
        selectedMessageIDs.subtract(ids)
        if anchorRemoved {
            let openTabMessages = Set(tabs.tabs.map(\.message))
            let nextAnchor = ReaderSelectionPolicy.anchorAfterRemoving(
                selectedMessageID: previousAnchor,
                remainingSelection: selectedMessageIDs,
                removedIDs: ids,
                openTabMessages: openTabMessages
            )
            selectedMessageID = nextAnchor
            let readerAnchorSurvives = nextAnchor == previousAnchor
                && nextAnchor.map(openTabMessages.contains) == true
            if !readerAnchorSurvives {
                clearReaderSelection()
            }
        } else if selectedMessageIDs.isEmpty {
            selectedMessageID = nil
            clearReaderSelection()
        }
    }

    private func destinationFolder(for role: FolderRole) -> FolderID? {
        if let accountID = selectedFolder?.accountID {
            return folders.first {
                $0.accountID == accountID && $0.role == role
            }?.id
        }
        return folders.first { $0.role == role }?.id
    }

    func move(ids: Set<MessageID>, to folder: FolderID) {
        guard !ids.isEmpty, folder != selectedFolderID else { return }
        let orderedIDs = ids.sorted { $0.rawValue < $1.rawValue }
        let rollbackRows = listRows.filter { ids.contains($0.id) }
        let rollbackSelection = selectedMessageIDs
        let rollbackAnchor = selectedMessageID
        removeListRows(ids)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let tabLinkOverrides = await destinationTabLinks(
                for: ids,
                destination: folder
            )
            do {
                let outcome = try await facade.move(orderedIDs, to: folder)
                let acceptedIDs = outcome.acceptedIDs.isEmpty && outcome.movedCount == ids.count
                    ? ids
                    : outcome.acceptedIDs
                let skippedIDs = ids.subtracting(acceptedIDs)
                var acceptedTabLinkOverrides: [UUID: String] = [:]
                for (tabID, link) in tabLinkOverrides {
                    guard let tab = tabs.tabs.first(where: { $0.id == tabID }),
                          acceptedIDs.contains(tab.message)
                    else { continue }
                    acceptedTabLinkOverrides[tabID] = link
                }
                scheduleTabsPersistence(linkOverrides: acceptedTabLinkOverrides)
                guard !skippedIDs.isEmpty else { return }
                restoreMovedRows(
                    rollbackRows.filter { skippedIDs.contains($0.id) },
                    selectedIDs: rollbackSelection.intersection(skippedIDs),
                    anchor: rollbackAnchor.flatMap { skippedIDs.contains($0) ? $0 : nil }
                )
                toasts.post(title: "Messages can only be moved within the same account")
            } catch {
                restoreMovedRows(
                    rollbackRows,
                    selectedIDs: rollbackSelection,
                    anchor: rollbackAnchor
                )
                toasts.post(
                    title: "Couldn't move \(ids.count) messages",
                    detail: error.localizedDescription
                )
            }
        }
    }

    /// Builds destination deep links before an optimistic move removes the
    /// source rows from the store. The tab keeps its identity and UID while
    /// only the folder locator changes.
    private func destinationTabLinks(
        for ids: Set<MessageID>,
        destination: FolderID
    ) async -> [UUID: String] {
        guard let destinationSummary = folders.first(where: { $0.id == destination }) else {
            return [:]
        }
        let destinationLocator = FolderLocator(
            kind: .path,
            value: destinationSummary.path
        )
        var overrides: [UUID: String] = [:]
        for tab in tabs.tabs where ids.contains(tab.message) {
            var sourceLink = try? await facade.makeDeepLink(for: tab.message)
            if sourceLink == nil,
               let cached = messageDeepLinks[tab.message] {
                sourceLink = MailternalDeepLink(string: cached)
            }
            guard let sourceLink,
                  let messageLocator = sourceLink.messageLocator else {
                continue
            }
            let destinationLink = MailternalDeepLink.message(
                accountLinkID: sourceLink.accountLinkID,
                folderLocator: destinationLocator,
                uidValidity: messageLocator.uidValidity,
                uid: messageLocator.uid
            )
            guard let value = destinationLink.formattedString else { continue }
            overrides[tab.id] = value
        }
        return overrides
    }

    /// Restores rows rejected by the facade while retaining their original
    /// selection. Live page observations may race this call, so existing IDs
    /// are never inserted twice.
    private func restoreMovedRows(
        _ rows: [MessageRow],
        selectedIDs: Set<MessageID>,
        anchor: MessageID?
    ) {
        let existing = Set(listRows.map(\.id))
        listRows.append(contentsOf: rows.filter { !existing.contains($0.id) })
        listRows.sort {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.rawValue > $1.id.rawValue
        }
        selectedMessageIDs.formUnion(selectedIDs)
        if let anchor, selectedMessageIDs.contains(anchor) {
            selectedMessageID = anchor
        }
    }
    func moveDroppedLinks(_ links: [String], to folder: FolderID) async {
        guard folder != selectedFolderID else { return }
        var ids: Set<MessageID> = []
        for rawLink in links {
            if let messageID = MessageLinkPasteboard.decodeMessageID(rawLink) {
                ids.insert(messageID)
                continue
            }
            guard let link = MailternalDeepLink(string: rawLink),
                  let resolution = try? await facade.resolve(link),
                  case .message(_, let messageID, _) = resolution else { continue }
            ids.insert(messageID)
        }
        move(ids: ids, to: folder)
    }

    func openMessage(_ id: MessageID, permanent: Bool) {
        // Explicit opens are never dropped: a transient open reuses the one
        // transient tab, a permanent open promotes or inserts (ReaderTabs.open).
        let existingTabID = tabs.tabs.first(where: { $0.message == id })?.id
        tabs.open(id, permanent: permanent)
        let activeTabID = tabs.activeID
        let pooledRemoteImages = activeTabID.map {
            readerSurfacePool.remoteImagesAllowed(for: $0)
        } ?? false
        let retainedRemoteImages = activeTabID == existingTabID
            ? pooledRemoteImages
            : false
        if let activeID = activeTabID {
            readerSurfacePool.retain(activeID)
        }
        if let folder = folderContaining(id), selectedFolderID != folder {
            selectFolder(folder)
        }
        if let folder = folderContaining(id),
           listRows.contains(where: { $0.id == id }) {
            let selectionMatches = selectedMessageIDs == [id]
                && selectedMessageID == id
            let detailMatches = detail?.id == id
            if !selectionMatches || (!detailMatches && !isLoadingDetail) {
                syncSelection(to: id, folder: folder)
            }
            restoreRemoteImagesAllowed(
                retainedRemoteImages,
                tabID: activeTabID,
                messageID: id
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let link = try await self.facade.makeDeepLink(for: id),
                      let destination = try await self.facade.resolve(link),
                      case .message(let folder, _, let row) = destination else {
                    guard !Task.isCancelled else { return }
                    self.closeUnavailableTab(messageID: id)
                    return
                }
                guard !Task.isCancelled else { return }
                if self.selectedFolderID != folder {
                    self.selectFolder(folder)
                }
                if !self.listRows.contains(where: { $0.id == id }) {
                    self.listRows.insert(row, at: 0)
                }
                guard self.tabs.activeID == activeTabID,
                      self.tabs.active?.message == id else { return }
                self.syncSelection(to: id, folder: folder)
                self.restoreRemoteImagesAllowed(
                    retainedRemoteImages,
                    tabID: activeTabID,
                    messageID: id
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.closeUnavailableTab(messageID: id)
            }
        }
    }

    func activateTab(_ id: UUID) {
        guard let tab = tabs.tabs.first(where: { $0.id == id }) else { return }
        let signpostID = OSSignpostID(log: appModelSignpostLog)
        os_signpost(
            .begin,
            log: appModelSignpostLog,
            name: "activateTab",
            signpostID: signpostID,
            "tab=%{public}s",
            id.uuidString
        )
        defer {
            os_signpost(
                .end,
                log: appModelSignpostLog,
                name: "activateTab",
                signpostID: signpostID
            )
        }
        tabs.activate(id)
        readerSurfacePool.retain(id)
        let retainedRemoteImages = readerSurfacePool.remoteImagesAllowed(for: id)
        if let folder = folderContaining(tab.message),
           listRows.contains(where: { $0.id == tab.message }),
           canSync(folder: folder) {
            syncSelection(to: tab.message, folder: folder)
            restoreRemoteImagesAllowed(
                retainedRemoteImages,
                tabID: id,
                messageID: tab.message
            )
            return
        }
        guard folderContaining(tab.message) == nil || canSync(folder: folderContaining(tab.message)!) else {
            // A disabled account may retain cached detail, but activating its
            // tab must not force account/folder selection or a network fetch.
            restoreRemoteImagesAllowed(
                retainedRemoteImages,
                tabID: id,
                messageID: tab.message
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let link = try await self.facade.makeDeepLink(for: tab.message),
                      let destination = try await self.facade.resolve(link),
                      case .message(let folder, _, _) = destination,
                      self.canSync(folder: folder) else {
                    guard !Task.isCancelled else { return }
                    self.closeUnavailableTab(messageID: tab.message)
                    return
                }
                guard !Task.isCancelled,
                      self.tabs.activeID == id,
                      self.tabs.active?.message == tab.message else { return }
                self.syncSelection(to: tab.message, folder: folder)
                self.restoreRemoteImagesAllowed(
                    retainedRemoteImages,
                    tabID: id,
                    messageID: tab.message
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.closeUnavailableTab(messageID: tab.message)
            }
        }
    }

    private func restoreRemoteImagesAllowed(
        _ allowed: Bool,
        tabID: UUID?,
        messageID: MessageID
    ) {
        guard let tabID,
              tabs.activeID == tabID,
              tabs.active?.message == messageID else { return }
        allowRemoteImages = allowed
    }

    private func canSync(folder: FolderID) -> Bool {
        guard let summary = folders.first(where: { $0.id == folder }),
              let account = accountConfigs.first(where: { $0.id == summary.accountID }) else {
            return true
        }
        return account.isEnabled
    }

    /// ⌘W closes a reader tab while one exists; otherwise AppKit closes the
    /// main window through its normal close-window action. Closing the final
    /// tab performs both steps during this same invocation.
    func closeActiveTabOrWindow() {
        if let activeID = tabs.activeID {
            tabs.close(activeID)
            if let active = tabs.active {
                activateTab(active.id)
            } else {
                clearReaderSelection()
                selectedMessageIDs.removeAll()
                selectedMessageID = nil
                if ReaderTabsPolicy.shouldCloseWindow(afterClosingTabsRemaining: tabs.tabs.count) {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    @discardableResult
    func messageRemoved(_ id: MessageID) -> Bool {
        detailCache.removeValue(for: id)
        guard tabs.messageRemoved(id) else { return false }
        toasts.post(title: "Message was deleted")
        if selectedMessageID == id {
            if let active = tabs.active {
                activateTab(active.id)
            } else {
                clearReaderSelection()
                selectedMessageIDs.removeAll()
                selectedMessageID = nil
            }
        }
        return true
    }

    /// Detail/route failures mean the message is gone, not a reader loading
    /// state. Remove its tab without a toast and leave the reader empty when
    /// no other tab remains.
    private func closeUnavailableTab(messageID: MessageID) {
        detailCache.removeValue(for: messageID)
        guard let tabID = tabs.tabs.first(where: { $0.message == messageID })?.id else {
            return
        }
        let wasActive = tabs.activeID == tabID
        tabs.close(tabID)
        guard wasActive else { return }
        if let active = tabs.active {
            activateTab(active.id)
        } else {
            clearReaderSelection()
            selectedMessageIDs.removeAll()
            selectedMessageID = nil
        }
    }

    private func syncSelection(to id: MessageID, folder: FolderID?) {
        guard !isSyncingTabSelection else { return }
        isSyncingTabSelection = true
        defer { isSyncingTabSelection = false }
        let signpostID = OSSignpostID(log: appModelSignpostLog)
        os_signpost(
            .begin,
            log: appModelSignpostLog,
            name: "syncSelection",
            signpostID: signpostID,
            "message=%{public}s",
            String(id.rawValue)
        )
        defer {
            os_signpost(
                .end,
                log: appModelSignpostLog,
                name: "syncSelection",
                signpostID: signpostID
            )
        }
        if let folder, selectedFolderID != folder {
            selectFolder(folder)
        }
        let alreadySelected = selectedMessageIDs == [id]
            && selectedMessageID == id
            && detail?.id == id
            && !isLoadingDetail
        selectedMessageIDs = [id]
        selectedMessageID = id
        guard !alreadySelected else { return }
        loadMessageDetail(id)
    }

    private var tabsPersistenceURL: URL {
        if let root = QALaunch.parse()?.containerRoot {
            return root.appendingPathComponent("reader-tabs.json", isDirectory: false)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Mailternal", isDirectory: true)
            .appendingPathComponent("reader-tabs.json", isDirectory: false)
    }

    private func scheduleTabsPersistence(linkOverrides: [UUID: String] = [:]) {
        tabSaveTask?.cancel()
        tabSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            var links: [UUID: String] = [:]
            for tab in self.tabs.tabs {
                if let override = linkOverrides[tab.id] {
                    links[tab.id] = override
                } else if let link = try? await self.facade.makeDeepLink(for: tab.message),
                          let value = link.formattedString {
                    links[tab.id] = value
                }
            }
            guard !Task.isCancelled else { return }
            let snapshot = self.tabs.snapshot(links: links)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: self.tabsPersistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: self.tabsPersistenceURL, options: .atomic)
        }
    }

    private func restoreTabsIfNeeded() {
        guard !tabsRestored, isAccountActive, foldersSnapshotReady else { return }
        tabsRestored = true
        tabRestoreTask?.cancel()
        tabRestoreTask = Task { @MainActor [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: self.tabsPersistenceURL),
                  let snapshot = try? JSONDecoder().decode(ReaderTabsSnapshot.self, from: data)
            else { return }
            var resolved: [UUID: MessageID] = [:]
            for entry in snapshot.tabs {
                guard let link = MailternalDeepLink(string: entry.link),
                      let destination = try? await self.facade.resolve(link),
                      case .message(_, let id, _) = destination else { continue }
                resolved[entry.id] = id
            }
            guard !Task.isCancelled else { return }
            self.tabs.restore(snapshot, messagesByTabID: resolved)
            if let activeID = self.tabs.activeID {
                self.activateTab(activeID)
            }
        }
    }

    /// No facade-wide existence stream exists, so this bounded poll checks only
    /// the small set of open-tab messages every 30 seconds. It catches
    /// expunge/delete events outside the visible folder; a move continues to
    /// resolve normally and therefore keeps its tab.
    private func startTabExistenceObservation() {
        guard tabExistenceTask == nil else { return }
        tabExistenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                for tab in self.tabs.tabs {
                    if let folder = self.folderContaining(tab.message), !self.canSync(folder: folder) {
                        continue
                    }
                    do {
                        guard let link = try await self.facade.makeDeepLink(for: tab.message) else {
                            self.messageRemoved(tab.message)
                            continue
                        }
                        guard let destination = try await self.facade.resolve(link) else {
                            self.messageRemoved(tab.message)
                            continue
                        }
                        guard case .message(_, _, _) = destination else { continue }
                    } catch {
                        // A transient store/network failure is not deletion.
                        continue
                    }
                }
            }
        }
    }

    func openSearchResult(_ row: MessageRow) {
        isSearchPresented = false
        toasts.isSuppressed = false
        if let folder = row.folderID ?? folderContaining(row.id), selectedFolderID != folder {
            selectFolder(folder)
        }
        if !listRows.contains(where: { $0.id == row.id }) {
            listRows.insert(row, at: 0)
        }
        openMessage(row.id, permanent: false)
    }


    func refresh() async {
        if !syncStatus.isOnline {
            toasts.post(title: "You’re offline", detail: "Mail will refresh when the connection returns.", severity: .warning)
        }
        await facade.refresh()
    }

    func toggleSearch() {
        guard isAccountActive else { return }
        isSearchPresented.toggle()
        toasts.isSuppressed = isSearchPresented
        if isSearchPresented {
            isFindPresented = false
        }
    }

    /// Toggles the current message's reading mode without changing Settings.
    func toggleEmailReadingOverride() {
        emailReadingOverride = EmailReadingOverridePolicy.next(
            effective: effectiveEmailReadingMode
        )
    }

    /// Toggles raw source presentation immediately while preserving the reader
    /// island. The source body is fetched after the presentation state changes
    /// so the reader can show its already-loaded envelope without waiting.
    func toggleRawSource() {
        let shouldShow = !isShowingRawSource
        withAnimation(MailMotion.sourceMorph) {
            isShowingRawSource = shouldShow
        }
        guard shouldShow, rawSource == nil else { return }
        Task { [weak self] in
            await self?.loadRawSource()
        }
    }

    func toggleFind() {
        guard detail != nil else { return }
        isFindPresented.toggle()
        if !isFindPresented { findQuery = "" }
    }

    func toggleSidebar() {
        withAnimation(MailMotion.sidebarToggle) {
            columnVisibility = SidebarVisibilityPolicy.toggled(
                current: columnVisibility,
                lastVisible: lastVisibleColumnVisibility
            )
        }
        lastVisibleColumnVisibility = SidebarVisibilityPolicy.remembered(
            columnVisibility,
            lastVisible: lastVisibleColumnVisibility
        )
    }

    /// Saves edited account settings through the facade boundary.
    func updateAccount(_ config: AccountConfig, password: String?) async throws {
        try await facade.updateAccount(config, password: password)
    }
    func setAccountEnabled(_ id: AccountID, _ enabled: Bool) async {
        do {
            try await facade.setAccountEnabled(id, enabled)
        } catch {
            toasts.post(
                title: "Couldn’t update account",
                detail: error.localizedDescription,
                severity: .error
            )
        }
        accountConfigs = facade.accounts
        accountStates = facade.accountStates
        applyAccountStates(accountStates)
    }

    func showSettings() {
        SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
    }

    /// Opens a message in its own reader window. The detail fetch supplies
    /// the AppKit window title while the window's reader performs its own
    /// independent detail load.
    func openMessageWindow(_ id: MessageID) {
        Task { [weak self] in
            guard let self else { return }
            var subject: String?
            do {
                let detail = try await facade.detail(id)
                subject = detail.envelope.subject
            } catch {
                subject = nil
            }
            guard !Task.isCancelled else { return }
            MessageWindowController.shared.show(
                messageID: id,
                model: self,
                title: subject
            )
        }
    }

    func loadRawSource() async {
        guard let id = selectedMessageID else { return }
        do {
            let source = try await facade.rawSource(id)
            guard selectedMessageID == id,
                  selectedMessageIDs == Set([id]) else { return }
            rawSource = source
        } catch {
            guard !Task.isCancelled else { return }
            toasts.post(title: "Couldn’t load source", detail: error.localizedDescription)
        }
    }

    func partProvider(for message: MessageID) -> @Sendable (String) async throws -> (data: Data, mimeType: String) {
        let box = MailFacadePartFetch(facade: facade)
        return { reference in
            try await PartFetchRouting.dispatch(
                reference: reference,
                imap: { part in try await box.fetch(message: message, part: part) },
                remote: { url in try await RemoteImageFetch.load(url) }
            )
        }
    }

    func copySelectedSubject() {
        guard let id = selectedMessageID else { return }
        copySubject(for: id)
    }

    func copySubject(for message: MessageID) {
        guard let subject = listRows.first(where: { $0.id == message })?.subject
            ?? (detail?.id == message ? detail?.envelope.subject : nil) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(subject, forType: .string)
    }
    func copySubjects(for ids: Set<MessageID>) {
        let subjects = ids.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
            listRows.first(where: { $0.id == id })?.subject
                ?? (detail?.id == id ? detail?.envelope.subject : nil)
        }
        guard !subjects.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(subjects.joined(separator: "\n"), forType: .string)
    }

    func copyDeepLinks(for ids: Set<MessageID>) async {
        var values: [String] = []
        for id in ids.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let cached = messageDeepLinks[id] {
                values.append(cached)
                continue
            }
            if let link = try? await facade.makeDeepLink(for: id),
               let value = link.formattedString {
                messageDeepLinks[id] = value
                values.append(value)
            }
        }
        guard !values.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    /// Synchronous view-side lookup used by the AppKit drag source. Rows are
    /// prefetched as they enter the model; an incomplete cache simply omits
    /// unavailable links rather than emitting a non-canonical identity.
    func messageLinks(for ids: Set<MessageID>) -> [String] {
        ids.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { messageDeepLinks[$0] }
    }

    func copyDeepLink(for folder: FolderID) async {
        do {
            guard let link = try await facade.makeDeepLink(for: folder),
                  let value = link.formattedString else {
                throw MailModelRouteError.linkUnavailable
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch {
            toasts.post(
                title: "Couldn’t copy link",
                detail: "That folder is no longer available.",
                severity: .error
            )
        }
    }

    func copyDeepLink(for message: MessageID) async {
        do {
            guard let link = try await facade.makeDeepLink(for: message),
                  let value = link.formattedString else {
                throw MailModelRouteError.linkUnavailable
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch {
            toasts.post(
                title: "Couldn’t copy link",
                detail: "That message is no longer available.",
                severity: .error
            )
        }
    }


    private func applyFirstPage(_ page: MessagePage) {
        prefetchDeepLinks(for: page.rows)
#if DEBUG
        dumpQAContextMenuIfRequested(firstRow: page.rows.first)
#endif
        if listRows.isEmpty {
            if !page.rows.isEmpty {
                QALaunch.launchPhase("first-rows n=\(page.rows.count)")
                MainWindowController.noteLaunchDataPhase("first-rows")
            }
            listRows = page.rows
            listCursor = page.next
            return
        }
        let incoming = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.id, $0) })
        listRows = listRows.map { incoming[$0.id] ?? $0 }
        let existing = Set(listRows.map(\.id))
        let prepend = page.rows.filter { !existing.contains($0.id) }
        if !prepend.isEmpty {
            listRows.insert(contentsOf: prepend, at: 0)

        }
        if listCursor == nil {
            listCursor = page.next
        }
    }

    private func appendPage(_ page: MessagePage) {
        prefetchDeepLinks(for: page.rows)
        let existing = Set(listRows.map(\.id))
        listRows.append(contentsOf: page.rows.filter { !existing.contains($0.id) })
        listCursor = page.next
    }

    private func prefetchDeepLinks(for rows: [MessageRow]) {
        for row in rows where messageDeepLinks[row.id] == nil {
            let id = row.id
            Task { [weak self] in
                guard let self else { return }
                guard let link = try? await facade.makeDeepLink(for: id),
                      let value = link.formattedString else { return }
                messageDeepLinks[id] = value
            }
        }
    }
#if DEBUG
    private func dumpQAContextMenuIfRequested(firstRow: MessageRow?) {
        guard !qaContextMenuDumped,
              ProcessInfo.processInfo.environment["MAILTERNAL_QA_MENU"] == "1",
              let firstRow else { return }
        qaContextMenuDumped = true
        let readStates = [firstRow.id: firstRow.isRead]
        let flagStates = [firstRow.id: firstRow.isFlagged]
        let policyItems = MessageContextMenuPolicy.items(
            selection: [firstRow.id],
            isReadStates: readStates,
            flagStates: flagStates,
            folders: folders,
            current: selectedFolderID,
            accounts: accountConfigs
        )
        let titles = policyItems.flatMap { item in
            [item.title] + item.children.map(\.title)
        }
        QALaunch.log("context-menu titles=\(titles.joined(separator: " | "))")
    }
#endif

    private func folderContaining(_ id: MessageID) -> FolderID? {
        if let row = listRows.first(where: { $0.id == id }), let folder = row.folderID {
            return folder
        }
        if let mock = facade as? MockMailFacade {
            return mock.folderID(for: id)
        }
        return selectedFolderID
    }

}

private struct MailFacadePartFetch: @unchecked Sendable {
    let facade: any MailFacade

    func fetch(message: MessageID, part: String) async throws -> (data: Data, mimeType: String) {
        let url = try await facade.fetchAttachment(message, part: part)
        let data = try Data(contentsOf: url)
        // Hash cache files have no extension; MIME comes from attachment metadata.
        let attachments = (try? await facade.detail(message))?.attachments ?? []
        let mime = AttachmentMIME.declared(
            for: part,
            attachments: attachments.map { ($0.id, $0.mimeType, $0.contentID) }
        ) ?? "application/octet-stream"
        return (data, mime)
    }
}
