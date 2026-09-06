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

/// Selects which durable workspace scope receives list customizations made by
/// the native table and View commands.
enum MailListCustomizationTarget: String, CaseIterable, Identifiable, Sendable {
    case currentFolder
    case global

    var id: Self { self }

    var title: String {
        switch self {
        case .currentFolder: "Current Folder"
        case .global: "All Folders"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private struct QATabCommandState {
        let serial: UInt64
        let messageID: MessageID
        var surfaceReady = false
        var scrollOffset: CGFloat?
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
    @ObservationIgnored private let detailLoader: MessageDetailLoader
    let facade: any MailFacade
    let appearance: AppearanceSettings
    let actions: ActionSettings
    let workspaceSync: MacWorkspaceCoordinator
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
    /// AppKit can leave the list table as first responder when a click lands
    /// on a non-focusable SwiftUI reader surface. Keep the user's last pane
    /// interaction separately so ⌘W follows the visible focus contract.
    @ObservationIgnored private var readerInteractionActive = false
    /// The responder present when the last logical pane interaction was
    /// classified. AppKit can retain the same table responder for both a
    /// reader-background click and a later list click, so the marker and this
    /// snapshot must be evaluated as a pair.
    @ObservationIgnored private weak var interactionResponder: NSResponder?

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
    @ObservationIgnored private var qaTabCommandSequence: UInt64 = 0
    @ObservationIgnored private var qaPendingTabCommands: [UUID: QATabCommandState] = [:]
    @ObservationIgnored private var tabSaveTask: Task<Void, Never>?
    @ObservationIgnored private var tabRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var tabExistenceTask: Task<Void, Never>?
    @ObservationIgnored private var deepLinkPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var detailPrefetchAnchor: (id: MessageID, movingBackward: Bool)?
    @ObservationIgnored private var tabsRestored = false
    @ObservationIgnored private var isSyncingTabSelection = false
#if DEBUG
    @ObservationIgnored private var qaContextMenuDumped = false
#endif
    @ObservationIgnored private var listLayoutObservationGeneration: UInt64 = 0
    @ObservationIgnored private var activeListSort: MailListSort = .newest
    /// Native table edits target the current folder by default. Commands can
    /// switch this to global defaults before changing order, widths, or sort.
    var listCustomizationTarget: MailListCustomizationTarget = .currentFolder

    var selectedFolder: FolderSummary? {
        folders.first { $0.id == selectedFolderID }
    }
    /// Complete server folder identity used for durable layout keys. Folder
    /// IDs are intentionally excluded so settings can sync across devices.
    var effectiveListScope: MailListScope {
        listScope(for: selectedFolder)
    }

    /// Effective list presentation, columns, widths, and sort for the visible
    /// folder after global values and its optional override are resolved.
    var effectiveListConfiguration: MailListConfiguration {
        workspaceSync.listLayout.configuration(for: effectiveListScope)
    }

    /// The pane arrangement consumed by the native main-window shell.
    var listPaneLayout: MailPaneLayout {
        effectiveListConfiguration.paneLayout
    }

    var globalListConfiguration: MailListConfiguration {
        workspaceSync.listLayout.configuration(for: .global)
    }

    var canCustomizeCurrentFolder: Bool {
        selectedFolder != nil && effectiveListScope != .global
    }

    private func listScope(for folder: FolderSummary?) -> MailListScope {
        guard let folder,
              let account = accountConfigs.first(where: { $0.id == folder.accountID })
        else {
            return .global
        }
        return .folder(account: account.accountLinkID, path: folder.path)
    }

    private var listMutationScope: MailListScope {
        switch listCustomizationTarget {
        case .global:
            return .global
        case .currentFolder:
            return effectiveListScope
        }
    }
    private func listScope(for folderID: FolderID?) -> MailListScope {
        guard let folderID else { return .global }
        return listScope(for: folders.first { $0.id == folderID })
    }

    private func listConfiguration(for folderID: FolderID?) -> MailListConfiguration {
        workspaceSync.listLayout.configuration(for: listScope(for: folderID))
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
        self.detailLoader = MessageDetailLoader(fetch: { id in
            try await facade.detail(id)
        }, fetchBatch: { ids in
            try await facade.details(ids)
        })
        let pool = ReaderSurfacePool()
        self.readerSurfacePool = pool
        self.tabs = ReaderTabs()
        accountState = facade.accountState
        accountStates = facade.accountStates
        accountConfigs = facade.accounts
        self.workspaceSync = MacWorkspaceCoordinator(
            appearance: appearance,
            actions: actions,
            storageURL: MacWorkspaceCoordinator.defaultStorageURL
        )
        tabs.onChange = { [weak self] in
            self?.scheduleTabsPersistence()
        }
        pool.onEvict = { [weak self] _ in
            guard let self else { return }
            self.detailLoader.setProtectedMessageIDs(self.retainedDetailMessageIDs)
        }
        tabs.onClose = { [weak self, weak pool] id in
            pool?.drop(id)
            guard let self else { return }
            self.detailLoader.setProtectedMessageIDs(self.retainedDetailMessageIDs)
        }
        workspaceSync.bind(to: self)
    }

    /// Changes the scope used by native table edits. The choice itself is
    /// session-local; the resulting settings are durable workspace values.
    func setListCustomizationTarget(_ target: MailListCustomizationTarget) {
        guard target != .currentFolder || canCustomizeCurrentFolder else {
            listCustomizationTarget = .global
            return
        }
        listCustomizationTarget = target
    }

    /// Persists the pane arrangement for the scope currently selected by View
    /// commands. MainWindowController consumes `listPaneLayout` separately.
    func setPaneLayout(_ layout: MailPaneLayout) {
        persistListChange { [store = workspaceSync.listLayout] scope in
            try await store.setPaneLayout(layout, for: scope)
        }
    }

    func setGlobalPaneLayout(_ layout: MailPaneLayout) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setPaneLayout(layout, for: scope)
        }
    }

    func setListPresentation(_ presentation: MailListPresentation) {
        persistListChange { [store = workspaceSync.listLayout] scope in
            try await store.setPresentation(presentation, for: scope)
        }
    }

    func setGlobalListPresentation(_ presentation: MailListPresentation) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setPresentation(presentation, for: scope)
        }
    }

    func setListColumnOrder(_ order: [MailListColumn]) {
        persistListChange { [store = workspaceSync.listLayout] scope in
            try await store.setColumnOrder(order, for: scope)
        }
    }

    func setGlobalListColumnOrder(_ order: [MailListColumn]) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setColumnOrder(order, for: scope)
        }
    }

    func setListColumnVisible(_ column: MailListColumn, visible: Bool) {
        persistListChange { [store = workspaceSync.listLayout] scope in
            try await store.setColumnVisible(column, visible: visible, for: scope)
        }
    }

    func setGlobalListColumnVisible(_ column: MailListColumn, visible: Bool) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setColumnVisible(column, visible: visible, for: scope)
        }
    }

    func setListColumnWidth(_ column: MailListColumn, width: Double) {
        persistListChange { [store = workspaceSync.listLayout] scope in
            try await store.setColumnWidth(column, width: width, for: scope)
        }
    }

    func setGlobalListColumnWidth(_ column: MailListColumn, width: Double) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setColumnWidth(column, width: width, for: scope)
        }
    }

    func setListSort(_ sort: MailListSort) {
        persistListChange { [store = workspaceSync.listLayout] scope in
            try await store.setSort(sort, for: scope)
        }
    }

    func setGlobalListSort(_ sort: MailListSort) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setSort(sort, for: scope)
        }
    }

    func resetListOverrides() {
        guard case .folder = effectiveListScope else { return }
        persistListChange(in: effectiveListScope) { [store = workspaceSync.listLayout] scope in
            try await store.resetOverrides(for: scope)
        }
    }

    func resetGlobalListSettings() {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.resetOverrides(for: scope)
        }
    }

    private func persistListChange(
        _ operation: @escaping @MainActor (MailListScope) async throws -> Void
    ) {
        persistListChange(in: listMutationScope, operation)
    }

    private func persistListChange(
        in scope: MailListScope,
        _ operation: @escaping @MainActor (MailListScope) async throws -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await operation(scope)
            } catch {
                toasts.post(
                    title: "Couldn’t save list layout",
                    detail: error.localizedDescription,
                    severity: .error
                )
            }
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
            deepLinkPrefetchTask?.cancel()
            deepLinkPrefetchTask = nil
            messageDeepLinks.removeAll()
            listRows = []
            listCursor = nil
            listEpoch += 1
            return
        }
        selectFolder(folderID)
    }

    private func routeMessage(
        folderID: FolderID,
        messageID: MessageID
    ) async throws {
        let sort = listConfiguration(for: folderID).sort
        var cursor: MessagePageCursor?
        var loaded: [MessageRow] = []
        repeat {
            let page = try await facade.page(
                in: folderID,
                after: cursor,
                limit: MessageListPrefetch.pageSize,
                sort: sort
            )
            guard !Task.isCancelled,
                  listConfiguration(for: folderID).sort == sort
            else { return }
            loaded.append(contentsOf: page.rows)
            if page.rows.contains(where: { $0.id == messageID }) {
                guard !Task.isCancelled else { return }
                prepareFolderForRoute(folderID)
                listRows = loaded
                listCursor = page.next
                activeListSort = sort
                openMessage(messageID, permanent: false)
                return
            }
            cursor = page.next
        } while cursor != nil

        // A concurrent expunge or generation replacement can invalidate a
        // resolved row before paging reaches it; do not select a substitute.
        throw MailModelRouteError.messageUnavailable
    }
    private func observeListLayout() {
        listLayoutObservationGeneration &+= 1
        let generation = listLayoutObservationGeneration
        let scope = effectiveListScope
        withObservationTracking {
            _ = workspaceSync.listLayout.configuration(for: scope)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.listLayoutObservationGeneration == generation,
                      self.streamsStarted
                else { return }
                let sort = self.effectiveListConfiguration.sort
                if sort != self.activeListSort {
                    self.restartList(for: sort)
                }
                self.observeListLayout()
            }
        }
    }

    private func restartList(for sort: MailListSort) {
        activeListSort = sort
        observeTask?.cancel()
        pageTask?.cancel()
        observeTask = nil
        pageTask = nil
        isPaging = false
        listRows = []
        listCursor = nil
        listEpoch += 1
        guard let folder = selectedFolderID else {
            isLoadingList = false
            return
        }
        isLoadingList = true
        observeListPages(in: folder, sort: sort, epoch: listEpoch)
    }

    private func observeListPages(in folder: FolderID, sort: MailListSort, epoch: UInt64) {
        observeTask = Task { [weak self] in
            guard let self else { return }
            for await page in facade.observePage(
                in: folder,
                after: nil,
                limit: MessageListPrefetch.pageSize,
                sort: sort
            ) {
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
                applyFirstPage(page, sort: sort)
                isLoadingList = false
            }
            if selectedFolderID == folder,
               listEpoch == epoch,
               activeListSort == sort {
                isLoadingList = false
            }
        }
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
            do {
                try await recoverPairedAccountLinks()
            } catch {
                streamsStarted = false
                toasts.post(
                    title: "Couldn’t restore paired account links",
                    detail: error.localizedDescription,
                    severity: .error
                )
                return
            }
            workspaceSync.start()
            observeListLayout()
            accountConfigs = facade.accounts
            accountStates = facade.accountStates
            applyAccountState(facade.accountState)
            Task { [weak self] in
                guard let self else { return }
                for await accounts in facade.accountsStream {
                    let previousScope = effectiveListScope
                    self.accountConfigs = accounts
                    guard selectedFolderID != nil, previousScope != effectiveListScope else { continue }
                    let sort = effectiveListConfiguration.sort
                    if sort != activeListSort {
                        restartList(for: sort)
                    } else {
                        observeListLayout()
                    }
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
                    let previousScope = effectiveListScope
                    self.folders = folders
                    let scopeChanged = selectedFolderID != nil && previousScope != effectiveListScope
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
                    if scopeChanged {
                        let sort = effectiveListConfiguration.sort
                        if sort != activeListSort {
                            restartList(for: sort)
                        } else {
                            observeListLayout()
                        }
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
            detailLoader.invalidateAll()
            detail = nil
            listRows = []
            deepLinkPrefetchTask?.cancel()
            deepLinkPrefetchTask = nil
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
    func selectFolder(_ id: FolderID?, userInitiated: Bool = false) {
        if userInitiated {
            noteListInteraction()
        }
        guard selectedFolderID != id else { return }
        detailPrefetchAnchor = nil
        selectedFolderID = id
        (facade as? LiveMailFacade)?.reportVisibleFolder(id)
        selectedMessageIDs.removeAll()
        selectedMessageID = nil
        if tabs.active == nil {
            clearReaderSelection()
        }
        listRows = []
        listCursor = nil
        detailLoader.cancelPrefetch()
        deepLinkPrefetchTask?.cancel()
        deepLinkPrefetchTask = nil
        messageDeepLinks.removeAll()
        isLoadingList = id != nil
        listEpoch += 1
        activeListSort = effectiveListConfiguration.sort
        observeTask?.cancel()
        pageTask?.cancel()
        observeListLayout()
        guard let id else { return }
        observeListPages(in: id, sort: activeListSort, epoch: listEpoch)
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
        let sort = activeListSort
        let epoch = listEpoch
        pageTask = Task { [weak self] in
            guard let self else { return }
            defer { isPaging = false }
            do {
                let page = try await facade.page(
                    in: folder,
                    after: cursor,
                    limit: MessageListPrefetch.pageSize,
                    sort: sort
                )
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
                appendPage(page)
            } catch {
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
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
        let sort = activeListSort
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await facade.messageIDs(in: folder, sort: sort)
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
                selectMessages(Set(ids), anchor: selectedMessageID)
            } catch {
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
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
        scheduleAdjacentDetailPrefetch()
        if let cached = detailLoader.cachedDetail(for: id) {
            presentDetail(
                cached,
                id: id,
                selection: qaSelection,
                source: "cache",
                signpostID: signpostID
            )
            return
        }
        isLoadingDetail = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.detailLoader.load(id)
                self.presentDetail(
                    loaded,
                    id: id,
                    selection: qaSelection,
                    source: "facade",
                    signpostID: signpostID
                )
            } catch {
                self.endDetailSignpost(
                    signpostID,
                    result: "error"
                )
                guard !Task.isCancelled,
                      self.qaSelectionSequence == qaSelection,
                      self.isReaderRequestCurrent(id) else { return }
                self.closeUnavailableTab(messageID: id)
            }
        }
    }

    private func endDetailSignpost(_ signpostID: OSSignpostID, result: String) {
        os_signpost(
            .end,
            log: appModelSignpostLog,
            name: "loadMessageDetail",
            signpostID: signpostID,
            "result=%{public}s",
            result
        )
    }

    private func presentDetail(
        _ loaded: MessageDetail,
        id: MessageID,
        selection: UInt64,
        source: String,
        signpostID: OSSignpostID
    ) {
        endDetailSignpost(signpostID, result: source)
        guard qaSelectionSequence == selection,
              isReaderRequestCurrent(id) else { return }
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
        detailPrefetchAnchor = nil
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
                let sort = activeListSort
                let epoch = listEpoch
                let page = try await facade.page(
                    in: folder,
                    after: nil,
                    limit: count,
                    sort: sort
                )
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
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
            guard let self else { return }
            do { try await facade.markRead(id) }
            catch { await reportMutationFailure(error, ids: [id]) }
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
                guard let self else { return }
                do {
                    if shouldRead {
                        try await facade.markRead(orderedIDs)
                    } else {
                        try await facade.markUnread(orderedIDs)
                    }
                } catch {
                    await reportMutationFailure(error, ids: ids)
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
                guard let self else { return }
                do { try await facade.setFlagged(orderedIDs, shouldFlag) }
                catch { await reportMutationFailure(error, ids: ids) }
            }
        }
    }

    /// Reconcile failed optimism from the current store, not a stale row copy
    /// that could overwrite a newer user edit.
    private func reportMutationFailure(_ error: Error, ids: Set<MessageID>) async {
        toasts.post(title: "Couldn’t save message changes", detail: error.localizedDescription, severity: .error)
        markedRead.subtract(ids)
        let sort = activeListSort
        guard let folder = selectedFolderID,
              let page = try? await facade.page(
                  in: folder,
                  after: nil,
                  limit: max(1, listRows.count),
                  sort: sort
              ),
              selectedFolderID == folder,
              activeListSort == sort
        else { return }
        let stored = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.id, $0) })
        for index in listRows.indices where ids.contains(listRows[index].id) {
            guard let row = stored[listRows[index].id] else { continue }
            listRows[index].isRead = row.isRead
            listRows[index].isFlagged = row.isFlagged
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
    /// Activates an adjacent tab from a keyboard command without first
    /// publishing an intermediate ``ReaderTabs`` state. The command marker is
    /// emitted before the reader selection changes so QA measures the command
    /// itself, not the later SwiftUI commit.
    func activateNextTab() {
        activateAdjacentTab(forward: true)
    }

    /// See ``activateNextTab()``.
    func activatePreviousTab() {
        activateAdjacentTab(forward: false)
    }

    private func activateAdjacentTab(forward: Bool) {
        guard let id = ReaderTabsPolicy.adjacentID(
            in: tabs.tabs,
            activeID: tabs.activeID,
            forward: forward,
            id: \.id
        ), let tab = tabs.tabs.first(where: { $0.id == id }) else {
            return
        }
        noteQATabCommand(tabID: id, messageID: tab.message)
        activateTab(id)
    }

    /// QA-only command boundary for reader tab switching. A command records
    /// intent before activation; readiness is emitted only after both the
    /// expected native surface and the outer scroll offset report completion.
    func noteQATabCommand(tabID: UUID, messageID: MessageID) {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" else {
            return
        }
        qaTabCommandSequence &+= 1
        let serial = qaTabCommandSequence
        qaPendingTabCommands.removeAll(keepingCapacity: true)
        QALaunch.log(
            "selection-perf event=tab-command serial=\(serial) tab=\(tabID.uuidString) message=\(messageID.rawValue) t=\(DispatchTime.now().uptimeNanoseconds)"
        )
        guard tabs.activeID != tabID else {
            QALaunch.log(
                "selection-perf event=tab-noop serial=\(serial) tab=\(tabID.uuidString) message=\(messageID.rawValue) t=\(DispatchTime.now().uptimeNanoseconds)"
            )
            return
        }
        qaPendingTabCommands[tabID] = QATabCommandState(
            serial: serial,
            messageID: messageID
        )
    }

    /// The HTML/TextKit bridge calls this after the requested tab's native
    /// surface is installed and rendered. It never accepts a stale message.
    func noteQASurfaceReady(tabID: UUID, messageID: MessageID) {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1",
              var pending = qaPendingTabCommands[tabID],
              pending.messageID == messageID else {
            return
        }
        pending.surfaceReady = true
        qaPendingTabCommands[tabID] = pending
        scheduleQAReaderReadyCheck(tabID: tabID, messageID: messageID)
    }

    /// The outer scroll bridge calls this after it has applied the persisted
    /// native offset to the current reader document.
    func noteQAScrollRestored(tabID: UUID, messageID: MessageID, offset: CGFloat) {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1",
              var pending = qaPendingTabCommands[tabID],
              pending.messageID == messageID else {
            return
        }
        pending.scrollOffset = offset
        qaPendingTabCommands[tabID] = pending
        scheduleQAReaderReadyCheck(tabID: tabID, messageID: messageID)
    }

    private func scheduleQAReaderReadyCheck(tabID: UUID, messageID: MessageID) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishQAReaderReadyCheck(tabID: tabID, messageID: messageID)
        }
    }

    private func finishQAReaderReadyCheck(tabID: UUID, messageID: MessageID) {
        guard let pending = qaPendingTabCommands[tabID],
              pending.messageID == messageID,
              pending.surfaceReady,
              let offset = pending.scrollOffset,
              tabs.activeID == tabID,
              tabs.active?.message == messageID,
              detail?.id == messageID else {
            return
        }
        qaPendingTabCommands.removeValue(forKey: tabID)
        let safeOffset = offset.isFinite ? max(offset, 0) : 0
        QALaunch.log(
            "selection-perf event=reader-ready serial=\(pending.serial) tab=\(tabID.uuidString) message=\(messageID.rawValue) offset=\(String(format: "%.1f", safeOffset)) t=\(DispatchTime.now().uptimeNanoseconds)"
        )
    }

    func openMessage(_ id: MessageID, permanent: Bool) {
        openMessages([id], permanent: permanent)
    }

    /// Opens messages in visible-list order as one reader transition. Every
    /// message gets the normal permanent-open deduplication/promotion rules,
    /// while only the final tab is activated, loaded, retained, and persisted.
    func openMessages(_ ids: [MessageID], permanent: Bool) {
        let preservedSelection = ids.count > 1 ? Set(ids) : nil
        guard let finalID = ids.last else { return }
        let existingTabID = tabs.tabs.first(where: { $0.message == finalID })?.id
        tabs.open(ids, permanent: permanent)
        guard let activeTabID = tabs.activeID,
              let activeMessageID = tabs.active?.message else {
            return
        }
        let pooledRemoteImages = readerSurfacePool.remoteImagesAllowed(for: activeTabID)
        let retainedRemoteImages = activeTabID == existingTabID
            ? pooledRemoteImages
            : false
        readerSurfacePool.retain(activeTabID)
        detailLoader.setProtectedMessageIDs(retainedDetailMessageIDs)

        if let folder = folderContaining(activeMessageID), selectedFolderID != folder {
            selectFolder(folder)
        }
        if let folder = folderContaining(activeMessageID),
           listRows.contains(where: { $0.id == activeMessageID }) {
            let selectionMatches = selectedMessageIDs == [activeMessageID]
                && selectedMessageID == activeMessageID
            let detailMatches = detail?.id == activeMessageID
            if !selectionMatches || (!detailMatches && !isLoadingDetail) {
                syncSelection(to: activeMessageID, folder: folder)
            }
            if let preservedSelection {
                selectedMessageIDs = preservedSelection
                selectedMessageID = activeMessageID
            }
            restoreRemoteImagesAllowed(
                retainedRemoteImages,
                tabID: activeTabID,
                messageID: activeMessageID
            )
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let link = try await self.facade.makeDeepLink(for: activeMessageID),
                      let destination = try await self.facade.resolve(link),
                      case .message(let folder, _, let row) = destination else {
                    guard !Task.isCancelled,
                          self.tabs.tabs.contains(where: {
                              $0.id == activeTabID && $0.message == activeMessageID
                          }) else { return }
                    self.closeUnavailableTab(messageID: activeMessageID)
                    return
                }
                guard !Task.isCancelled else { return }
                if self.selectedFolderID != folder {
                    self.selectFolder(folder)
                }
                if !self.listRows.contains(where: { $0.id == activeMessageID }) {
                    self.listRows.insert(row, at: 0)
                }
                guard self.tabs.activeID == activeTabID,
                      self.tabs.active?.message == activeMessageID else { return }
                self.syncSelection(to: activeMessageID, folder: folder)
                if let preservedSelection {
                    self.selectedMessageIDs = preservedSelection
                    self.selectedMessageID = activeMessageID
                }
                self.restoreRemoteImagesAllowed(
                    retainedRemoteImages,
                    tabID: activeTabID,
                    messageID: activeMessageID
                )
            } catch {
                guard !Task.isCancelled,
                      self.tabs.tabs.contains(where: {
                          $0.id == activeTabID && $0.message == activeMessageID
                      }) else { return }
                self.closeUnavailableTab(messageID: activeMessageID)
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
        detailLoader.setProtectedMessageIDs(retainedDetailMessageIDs)
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

    /// ⌘W is focus-sensitive: a focused reader closes its active tab, while
    /// the same command outside the reader delegates to the focused window's
    /// normal close action. The last reader tab leaves the main window open
    /// with an empty reader.
    func closeActiveTabOrWindow() {
        let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? MainWindowController.shared.window
        guard let window,
              window === MainWindowController.shared.window else {
            window?.performClose(nil)
            return
        }
        guard tabs.activeID != nil else {
            window.performClose(nil)
            return
        }
        let currentResponder = window.firstResponder
        let closesReader: Bool
        if currentResponder === interactionResponder {
            // The current responder did not change, so the logical pane
            // marker is authoritative (including a non-focusable reader
            // background that leaves the table first responder).
            closesReader = readerInteractionActive
        } else {
            // A real responder transition is stronger than a stale marker.
            closesReader = MainWindowController.shared.isReaderFocused(in: window)
        }
        guard closesReader else {
            window.performClose(nil)
            return
        }
        closeActiveReaderTab()
    }


    /// Records a click in the reader pane for focus-sensitive window commands.
    func noteReaderInteraction() {
        readerInteractionActive = true
        interactionResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
    }

    /// Records a user interaction in the list/sidebar region. Selection
    /// updates originating from tab activation do not call this hook.
    func noteListInteraction() {
        readerInteractionActive = false
        interactionResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
    }

    /// Closes a tab from an explicit reader-tab close affordance. This path
    /// must not depend on first-responder focus because the close button lives
    /// in the toolbar rather than in the reader pane.
    /// Active-tab closure restores native pane focus even when the strip
    /// disappears at one tab; its SwiftUI lifecycle does not own this step.
    func closeReaderTab(_ id: UUID) {
        let wasActive = tabs.activeID == id
        tabs.close(id)
        guard wasActive else { return }
        if let active = tabs.active {
            activateTab(active.id)
            MainWindowController.shared.focusReader()
        } else {
            clearReaderSelection()
            selectedMessageIDs.removeAll()
            selectedMessageID = nil
            MainWindowController.shared.focusMessageList()
        }
    }

    private func closeActiveReaderTab() {
        guard let activeID = tabs.activeID else { return }
        closeReaderTab(activeID)
    }


    @discardableResult
    func messageRemoved(_ id: MessageID) -> Bool {
        detailLoader.invalidate(id)
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
        detailLoader.invalidate(messageID)
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

    /// Finish an in-flight restore before changing the identities it resolves.
    func preparePairingAccountLinks() async {
        await tabRestoreTask?.value
        tabSaveTask?.cancel()
        await tabSaveTask?.value
    }

    /// Startup runs this before restoring tabs. Import runs it before ACK.
    func recoverPairedAccountLinks() async throws {
        try await finishPairingAccountLinkCommands(
            facade: facade,
            workspace: workspaceSync.controller
        ) { command in
            try self.remapPersistedReaderLinks(from: command.source, to: command.destination)
        }
    }

    private func remapPersistedReaderLinks(
        from source: AccountLinkID,
        to destination: AccountLinkID
    ) throws {
        tabSaveTask?.cancel()
        func remap(_ raw: String) -> String {
            guard let link = MailternalDeepLink(string: raw),
                  link.accountLinkID == source,
                  let value = link.replacingAccountLinkID(with: destination).formattedString else {
                return raw
            }
            return value
        }
        if FileManager.default.fileExists(atPath: tabsPersistenceURL.path) {
            var snapshot: ReaderTabsSnapshot
            do {
                let data = try Data(contentsOf: tabsPersistenceURL)
                snapshot = try JSONDecoder().decode(ReaderTabsSnapshot.self, from: data)
            } catch {
                // Reader restoration is ancillary. Preserve unreadable bytes
                // rather than repeatedly blocking the durable account relink.
                let quarantine = tabsPersistenceURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: tabsPersistenceURL, to: quarantine)
                toasts.post(title: "Couldn’t restore reader tabs", detail: error.localizedDescription)
                messageDeepLinks = messageDeepLinks.mapValues(remap)
                return
            }
            var changed = false
            snapshot.tabs = snapshot.tabs.map { entry in
                let link = remap(entry.link)
                guard link != entry.link else { return entry }
                changed = true
                return ReaderTabsSnapshot.Entry(
                    id: entry.id,
                    link: link,
                    isTransient: entry.isTransient,
                    scrollOffset: entry.scrollOffset
                )
            }
            if changed {
                try JSONEncoder().encode(snapshot).write(to: tabsPersistenceURL, options: .atomic)
            }
        }
        messageDeepLinks = messageDeepLinks.mapValues(remap)
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


    private func applyFirstPage(_ page: MessagePage, sort: MailListSort) {
#if DEBUG
        dumpQAContextMenuIfRequested(firstRow: page.rows.first)
#endif
        guard sort == activeListSort else { return }
        if listRows.isEmpty {
            if !page.rows.isEmpty {
                QALaunch.launchPhase("first-rows n=\(page.rows.count)")
                MainWindowController.noteLaunchDataPhase("first-rows")
            }
            listRows = page.rows
            listCursor = page.next
            scheduleDeepLinkPrefetch()
            scheduleAdjacentDetailPrefetch()
            return
        }
        guard sort == .newest else {
            // For non-newest orders, the observed page is authoritative. A
            // later notification can move rows anywhere in the complete
            // folder, so retaining older materialized rows would create a
            // client-side reorder and an invalid keyset boundary.
            let previousRows = Dictionary(uniqueKeysWithValues: listRows.map { ($0.id, $0) })
            for row in page.rows {
                if let previous = previousRows[row.id],
                   messageRowContentChanged(previous, row) {
                    detailLoader.invalidate(row.id)
                }
            }
            listRows = page.rows
            listCursor = page.next
            scheduleDeepLinkPrefetch()
            scheduleAdjacentDetailPrefetch()
            if let selectedMessageID,
               selectedMessageIDs.count == 1,
               let previous = previousRows[selectedMessageID],
               let current = page.rows.first(where: { $0.id == selectedMessageID }),
               messageRowContentChanged(previous, current) {
                detail = nil
                loadMessageDetail(selectedMessageID)
            }
            return
        }
        let previousRows = Dictionary(uniqueKeysWithValues: listRows.map { ($0.id, $0) })
        let incoming = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.id, $0) })
        let changedIDs = page.rows.compactMap { row -> MessageID? in
            guard let previous = previousRows[row.id],
                  messageRowContentChanged(previous, row) else { return nil }
            detailLoader.invalidate(row.id)
            return row.id
        }
        listRows = listRows.map { incoming[$0.id] ?? $0 }
        let existing = Set(listRows.map(\.id))
        let prepend = page.rows.filter { !existing.contains($0.id) }
        if !prepend.isEmpty {
            listRows.insert(contentsOf: prepend, at: 0)
        }
        if listCursor == nil {
            listCursor = page.next
        }
        if let selectedMessageID,
           selectedMessageIDs.count == 1,
           changedIDs.contains(selectedMessageID) {
            detail = nil
            loadMessageDetail(selectedMessageID)
        } else if !prepend.isEmpty {
            scheduleAdjacentDetailPrefetch()
        }
    }

    private func appendPage(_ page: MessagePage) {
        let existing = Set(listRows.map(\.id))
        let appended = page.rows.filter { !existing.contains($0.id) }
        listRows.append(contentsOf: appended)
        listCursor = page.next
        if !appended.isEmpty {
            scheduleAdjacentDetailPrefetch()
        }
    }

    /// Read/flag changes update list chrome only: MessageDetail contains
    /// neither flag, so invalidating it would reload an unchanged reader and
    /// reapply automatic read marking on every flag reconciliation.
    private func messageRowContentChanged(_ old: MessageRow, _ new: MessageRow) -> Bool {
        old.from != new.from
            || old.senderAddress != new.senderAddress
            || old.subject != new.subject
            || old.preview != new.preview
            || old.date != new.date
            || old.hasAttachments != new.hasAttachments
            || old.folderName != new.folderName
            || old.accountName != new.accountName
            || old.folderID != new.folderID
    }

    private func scheduleAdjacentDetailPrefetch() {
        let anchorIndex: Int
        if let selected = selectedMessageID,
           selectedMessageIDs == [selected],
           let index = listRows.firstIndex(where: { $0.id == selected }) {
            anchorIndex = index
        } else {
            guard !listRows.isEmpty else { return }
            anchorIndex = 0
        }
        let movingBackward: Bool
        if selectedMessageIDs.count == 1,
           let previous = detailPrefetchAnchor,
           let previousIndex = listRows.firstIndex(where: { $0.id == previous.id }) {
            movingBackward = previousIndex == anchorIndex
                ? previous.movingBackward
                : anchorIndex < previousIndex
        } else {
            movingBackward = false
        }
        detailPrefetchAnchor = (listRows[anchorIndex].id, movingBackward)
        // Keep eight messages ahead of travel and four behind, including
        // after a direction reversal; neither the batch nor cache grows.
        let start = max(0, anchorIndex - (movingBackward ? 8 : 4))
        let end = min(listRows.count, anchorIndex + (movingBackward ? 5 : 9))
        let ahead = listRows[(anchorIndex + 1)..<end].map(\.id)
        let behind = listRows[start..<anchorIndex].reversed().map(\.id)
        detailLoader.prefetch(movingBackward ? behind + ahead : ahead + behind)
    }

    /// Canonical links are useful for drag-out and copy, but neither is needed
    /// to paint the first rows. One cancellable, delayed batch avoids creating
    /// a main-actor task per row while retaining the synchronous local-ID drag
    /// fallback until canonical values arrive.
    private func scheduleDeepLinkPrefetch() {
        let epoch = listEpoch
        let ids = listRows.map(\.id).filter { messageDeepLinks[$0] == nil }
        guard !ids.isEmpty else { return }
        deepLinkPrefetchTask?.cancel()
        deepLinkPrefetchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.listEpoch == epoch else {
                return
            }
            var resolved: [MessageID: String] = [:]
            for id in ids {
                guard !Task.isCancelled, self.listEpoch == epoch else { return }
                guard let link = try? await self.facade.makeDeepLink(for: id),
                      let value = link.formattedString else {
                    continue
                }
                resolved[id] = value
            }
            guard !Task.isCancelled, self.listEpoch == epoch else { return }
            self.messageDeepLinks.merge(resolved, uniquingKeysWith: { _, new in new })
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
