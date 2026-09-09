import AppKit
import Observation
import SwiftUI
import MailternalAutomation
import MailternalInterfaces
import MailternalWorkspace
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

    /// A single not-yet-started transient preview occupies one FIFO slot.
    /// Newer app-origin previews replace its command before execution; once
    /// execution starts, later previews queue normally behind the same tail.
    final class PendingAutomationPreview {
        // Keep the fixed-layout handle before the dynamically laid-out command.
        // Release optimization can otherwise cache its field offset before
        // first-instance metadata initialization and overwrite the object header.
        var operation: Task<CommandResult, Error>?
        var command: Command
        var origin: CommandOrigin
        var grant: AutomationGrant
        var secret: String?

        init(
            command: Command,
            origin: CommandOrigin,
            grant: AutomationGrant,
            secret: String?
        ) {
            self.command = command
            self.origin = origin
            self.grant = grant
            self.secret = secret
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
    @ObservationIgnored private let detailLoader: MessageDetailLoader
    let facade: any MailFacade
    let appearance: AppearanceSettings
    let actions: ActionSettings
    let workspaceSync: MacWorkspaceCoordinator
    let toasts = ToastPresenter()
    let commandJournal: CommandJournal
    let automationStateHub: AppStateHub
    let searchPresentation = SearchPresentation()
    var searchFieldFocused = false
    let pairingAutomation = PairingAutomationBridge()
    @ObservationIgnored var pendingAutomationPreview: PendingAutomationPreview?
    /// Native list input stays authoritative until its newest queued selection
    /// finishes. Intermediate command snapshots must not rewind arrow navigation.
    var isListSelectionPending = false
    @ObservationIgnored var listSelectionIntentGeneration: UInt64 = 0

    var isPairingPresented = false
    @ObservationIgnored var automationSetupTask: Task<Bool, Never>?
    @ObservationIgnored var automationDispatchTail: Task<Void, Never>?
    @ObservationIgnored var automationPublicationTask: Task<Void, Never>?
    @ObservationIgnored var automationPublicationGeneration: UInt64 = 0
    @ObservationIgnored var suppressAutomationStatePublication = false
    @ObservationIgnored var automationGrants: [String: AutomationGrant] = [:]
    @ObservationIgnored var automationRuntimeLease: AutomationRuntimeLease?
    @ObservationIgnored var automationServer: AutomationSocketServer?
    @ObservationIgnored var automationTokenStore: AutomationTokenStore?
    @ObservationIgnored var automationHandler: AutomationSocketServer.Handler?
    @ObservationIgnored var automationEventsHandler: AutomationSocketServer.Events?
    @ObservationIgnored var automationRemoteListener: AutomationTLSListener?
    @ObservationIgnored var automationPairingStore: AutomationPairingStore?
    @ObservationIgnored let automationTransferRegistry: AutomationTransferRegistry
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
    /// Monotonic context token used by selection-dependent automation commands.
    /// It changes whenever folder or list selection changes.
    var selectionRevision: UInt64 = 0
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
    var listRows: [MessageRow] = [] {
        didSet { listContentRevision &+= 1 }
    }
    var listCursor: MessagePageCursor?
    /// Changes whenever visible row content or membership changes. Consumers
    /// can gate expensive same-ID work without treating scroll as content.
    private(set) var listContentRevision: UInt64 = 0
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
    @ObservationIgnored private var detailLoadTask: Task<Void, Never>?
    @ObservationIgnored private var deepLinkQueue = DeepLinkRouteQueue()
    @ObservationIgnored private var foldersSnapshotReady = false
    @ObservationIgnored private var qaLaunchFoldersLogged = false
    @ObservationIgnored private var streamsStarted = false
    @ObservationIgnored var automationReady = false
    @ObservationIgnored var automationReadinessWaiters: [CheckedContinuation<Bool, Never>] = []
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
    @ObservationIgnored var automationWindowIDs: [ObjectIdentifier: UUID] = [:]
    /// Detached reader ownership is resolved from the target message's current
    /// account link before the window is exposed to automation. The generic
    /// main window intentionally has no entry and therefore no account title.
    @ObservationIgnored private var automationWindowAccountLinks: [ObjectIdentifier: AccountLinkID] = [:]
    @ObservationIgnored private var isSyncingTabSelection = false
#if DEBUG
    @ObservationIgnored private var qaContextMenuDumped = false
#endif
    @ObservationIgnored private var listLayoutObservationGeneration: UInt64 = 0
    @ObservationIgnored var activeListSort: MailListSort = .newest
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
    var outgoingState = OutgoingState()
    @ObservationIgnored lazy var composer: MailComposerController = MailComposerController(
        facade: facade
    ) { [weak self] command, secret in
        guard let self else { throw AutomationCommandError.appUnavailable }
        return try await self.dispatch(command, secret: secret)
    }

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
        let journalRoot = MailternalLaunchOptions.containerURL
            ?? QALaunch.parse()?.containerRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Mailternal", isDirectory: true)
        self.commandJournal = CommandJournal(
            fileURL: journalRoot.appendingPathComponent("command-journal.json")
        )
        self.automationTransferRegistry = AutomationTransferRegistry()
        self.automationStateHub = AppStateHub()
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
        searchPresentation.onChange = { [weak self] in
            self?.scheduleAutomationStatePublication()
        }
        pairingAutomation.onStateChange = { [weak self] in
            self?.scheduleAutomationStatePublication()
        }
        tabs.onChange = { [weak self] in
            self?.scheduleTabsPersistence()
            self?.scheduleAutomationStatePublication()
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

    /// Changes the scope used by native table edits through a GUI command.
    func setListCustomizationTarget(_ target: MailListCustomizationTarget) {
        dispatchFromUI(.setListCustomizationTarget(target == .global ? .global : .currentFolder))
    }

    func setListCustomizationTargetDirect(_ target: MailListCustomizationTarget) async throws {
        guard target != .currentFolder || canCustomizeCurrentFolder else {
            listCustomizationTarget = .global
            return
        }
        listCustomizationTarget = target
    }
    func setPaneLayout(_ layout: MailPaneLayout) {
        dispatchFromUI(.setListPaneLayout(layout))
    }

    func setPaneLayoutDirect(_ layout: MailPaneLayout) async throws {
        try await persistListChangeDirect { [store = workspaceSync.listLayout] scope in
            try await store.setPaneLayout(layout, for: scope)
        }
    }

    func setGlobalPaneLayout(_ layout: MailPaneLayout) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setPaneLayout(layout, for: scope)
        }
    }

    func setListPresentation(_ presentation: MailListPresentation) {
        dispatchFromUI(.setListPresentation(presentation))
    }

    func setListPresentationDirect(_ presentation: MailListPresentation) async throws {
        try await persistListChangeDirect { [store = workspaceSync.listLayout] scope in
            try await store.setPresentation(presentation, for: scope)
        }
    }

    func setGlobalListPresentation(_ presentation: MailListPresentation) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setPresentation(presentation, for: scope)
        }
    }

    func setListColumnOrder(_ order: [MailListColumn]) {
        dispatchFromUI(.setListColumnOrder(order))
    }

    func setListColumnOrderDirect(_ order: [MailListColumn]) async throws {
        try await persistListChangeDirect { [store = workspaceSync.listLayout] scope in
            try await store.setColumnOrder(order, for: scope)
        }
    }

    func setGlobalListColumnOrder(_ order: [MailListColumn]) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setColumnOrder(order, for: scope)
        }
    }

    func setListColumnVisible(_ column: MailListColumn, visible: Bool) {
        dispatchFromUI(.setListColumnVisible(column, visible))
    }

    func setListColumnVisibleDirect(_ column: MailListColumn, visible: Bool) async throws {
        try await persistListChangeDirect { [store = workspaceSync.listLayout] scope in
            try await store.setColumnVisible(column, visible: visible, for: scope)
        }
    }

    func setGlobalListColumnVisible(_ column: MailListColumn, visible: Bool) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setColumnVisible(column, visible: visible, for: scope)
        }
    }

    func setListColumnWidth(_ column: MailListColumn, width: Double) {
        dispatchFromUI(.setListColumnWidth(column, width))
    }

    func setListColumnWidthDirect(_ column: MailListColumn, width: Double) async throws {
        guard width.isFinite, width > 0 else {
            throw MailListLayoutError.invalidColumnWidth
        }
        try await persistListChangeDirect { [store = workspaceSync.listLayout] scope in
            try await store.setColumnWidth(column, width: width, for: scope)
        }
    }

    func setGlobalListColumnWidth(_ column: MailListColumn, width: Double) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setColumnWidth(column, width: width, for: scope)
        }
    }

    func setListSort(_ sort: MailListSort) {
        dispatchFromUI(.setListSort(sort))
    }

    func setListSortDirect(_ sort: MailListSort) async throws {
        try await persistListChangeDirect { [store = workspaceSync.listLayout] scope in
            try await store.setSort(sort, for: scope)
        }
    }

    func setGlobalListSort(_ sort: MailListSort) {
        persistListChange(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.setSort(sort, for: scope)
        }
    }

    func resetListOverrides() {
        dispatchFromUI(.resetListSettings)
    }

    func resetListOverridesDirect() async throws {
        guard case .folder = effectiveListScope else { return }
        try await persistListChangeDirect(in: effectiveListScope) { [store = workspaceSync.listLayout] scope in
            try await store.resetOverrides(for: scope)
        }
    }

    func resetGlobalListSettings() {
        dispatchFromUI(.resetGlobalListSettings)
    }

    func resetGlobalListSettingsDirect() async throws {
        try await persistListChangeDirect(in: .global) { [store = workspaceSync.listLayout] scope in
            try await store.resetOverrides(for: scope)
        }
    }

    private func persistListChangeDirect(
        in scope: MailListScope? = nil,
        _ operation: @escaping @MainActor (MailListScope) async throws -> Void
    ) async throws {
        try await operation(scope ?? listMutationScope)
        scheduleAutomationStatePublication()
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
                scheduleAutomationStatePublication()
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
    /// Routes account renames through the same command journal used by
    /// automation clients. The command executor calls the direct adapter below
    /// to avoid recursively dispatching itself.
    @discardableResult
    func renameAccount(_ id: AccountID, to input: String) async -> Bool {
        guard let account = accountConfigs.first(where: { $0.id == id }) else { return false }
        let committed = AccountTitlePolicy.committedName(input: input, email: account.emailAddress)
        guard account.displayName != committed else { return false }
        do {
            try await dispatch(.renameAccount(id, committed), origin: .app, grant: .local)
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

    func renameAccountDirect(_ id: AccountID, to input: String) async -> Bool {
        guard let account = accountConfigs.first(where: { $0.id == id }) else { return false }
        let committed = AccountTitlePolicy.committedName(input: input, email: account.emailAddress)
        guard account.displayName != committed else { return false }
        var updated = account
        updated.displayName = committed
        do {
            try await facade.updateAccount(updated, password: nil)
            return true
        } catch {
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
            try await dispatch(.renameFolder(id, name), origin: .app, grant: .local)
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

    func renameFolderDirect(_ id: FolderID, to input: String) async -> Bool {
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
                openMessagesDirect([messageID], permanent: false)


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
                self.scheduleAutomationStatePublication()
            }
        }
    }

    private func restartList(for sort: MailListSort) {
        activeListSort = sort
        scheduleAutomationStatePublication()
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
                scheduleRetainedTabReconciliation()
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
        setAutomationReady(false)
        // Ownership is resolved before any persisted account can start an
        // engine. The listener setup itself performs filesystem/socket work
        // off the main actor.
        startAutomation()
        Task { [weak self] in
            guard let self else { return }
            if let live = facade as? LiveMailFacade {
                guard await waitForAutomationOwnership() else {
                    streamsStarted = false
                    setAutomationReady(false)
                    toasts.post(title: "Mailternal is already running elsewhere", severity: .warning)
                    return
                }
                await live.waitUntilStoreReady()
                await live.restorePersistedAccounts()
            } else {
                guard await waitForAutomationOwnership() else {
                    streamsStarted = false
                    setAutomationReady(false)
                    return
                }
            }
            do {
                try await recoverPairedAccountLinks()
            } catch {
                streamsStarted = false
                setAutomationReady(false)
                toasts.post(
                    title: "Couldn’t restore paired account links",
                    detail: error.localizedDescription,
                    severity: .error
                )
                return
            }
            Task { [weak self] in
                guard let self else { return }
                for await outgoing in facade.observeOutgoing(
                    accounts: nil, limit: AutomationProtocol.maximumQueryLimit
                ) {
                    guard !Task.isCancelled else { return }
                    self.outgoingState = outgoing
                    self.scheduleAutomationStatePublication()
                }
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
                    self.scheduleAutomationStatePublication()
                    guard selectedFolderID != nil, previousScope != effectiveListScope else { continue }
                    let sort = effectiveListConfiguration.sort
                    if sort != activeListSort {
                        restartList(for: sort)
                    } else {
                        observeListLayout()
                    }
                    self.scheduleAutomationStatePublication()
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await states in facade.accountStatesStream {
                    self.applyAccountStates(states)
                    self.scheduleAutomationStatePublication()
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await folders in facade.foldersStream {
                    let previousScope = effectiveListScope
                    self.folders = folders
                    self.foldersSnapshotReady = true
                    let scopeChanged = selectedFolderID != nil && previousScope != effectiveListScope
                    if !qaLaunchFoldersLogged && !folders.isEmpty {
                        qaLaunchFoldersLogged = true
                        QALaunch.launchPhase("folders-snapshot")
                        MainWindowController.noteLaunchDataPhase("folders-snapshot")
                    }
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
                    self.scheduleAutomationStatePublication()
                    self.scheduleRetainedTabReconciliation()
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await status in facade.syncStatusStream {
                    syncStatus = status
                    self.scheduleAutomationStatePublication()
                }
            }
            startTabExistenceObservation()
            setAutomationReady(true)
            if accountConfigs.isEmpty, !MailternalLaunchOptions.isHeadlessEngine {
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
        case .authFailed(let message):
            foldersSnapshotReady = false
            toasts.post(title: "Couldn’t sign in", detail: message, severity: .error)
        case .connectionFailed(let message):
            foldersSnapshotReady = false
            toasts.post(title: "Couldn’t connect", detail: message, severity: .error)
        case .active:
            restoreTabsIfNeeded()
        case .validating:
            foldersSnapshotReady = false
        }
        scheduleAutomationStatePublication()
    }

    func selectFolder(_ id: FolderID?, userInitiated: Bool = false) {
        if userInitiated { noteListInteraction() }
        dispatchFromUI(.selectFolder(id))
    }

    func selectFolderDirect(_ id: FolderID?) {
        guard selectedFolderID != id else { return }
        selectionRevision &+= 1
        detailPrefetchAnchor = nil
        let destinationSort = id.map { listConfiguration(for: $0).sort }
        selectedFolderID = id
        if let destinationSort {
            activeListSort = destinationSort
        }
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
        scheduleAutomationStatePublication()
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
                scheduleAutomationStatePublication()
            } catch {
                guard !Task.isCancelled,
                      selectedFolderID == folder,
                      listEpoch == epoch,
                      activeListSort == sort
                else { return }
                isLoadingList = false
                scheduleAutomationStatePublication()
            }
        }
    }

    /// Selection changes from table/reader events are dispatched so they
    /// participate in the same revisioned state stream as automation calls.
    func selectMessages(_ ids: Set<MessageID>, anchor: MessageID? = nil) {
        guard !ids.isEmpty else {
            dispatchFromUI(.clearSelection)
            return
        }
        dispatchFromUI(
            .selectMessages(
                .explicit(ids.sorted { $0.rawValue < $1.rawValue }),
                anchor: anchor.map(MessageReference.local)
            )
        )
    }

    func selectMessagesDirect(_ ids: Set<MessageID>, anchor: MessageID? = nil) {
        guard !ids.isEmpty else {
            selectMessage(nil)
            return
        }
        selectionRevision &+= 1
        selectedMessageIDs = ids
        guard ids.count == 1 else {
            scheduleAutomationStatePublication()
            return
        }
        let retainedAnchor = selectedMessageID.flatMap { ids.contains($0) ? $0 : nil }
        selectedMessageID = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? retainedAnchor ?? ids.first
        guard let selectedMessageID else {
            scheduleAutomationStatePublication()
            return
        }
        loadMessageDetail(selectedMessageID)
        scheduleAutomationStatePublication()
    }

    func selectAllMessages() {
        dispatchFromUI(.selectAll)
    }

    /// Selects the complete captured folder generation, not only materialized
    /// virtualized rows. The result is discarded if navigation changed while
    /// the facade query was suspended.
    func selectAllMessagesDirect() async throws {
        guard let folder = selectedFolderID else {
            selectMessage(nil)
            return
        }
        let epoch = listEpoch
        let sort = activeListSort
        let ids = try await facade.messageIDs(in: folder, sort: sort)
        guard !Task.isCancelled,
              selectedFolderID == folder,
              listEpoch == epoch,
              activeListSort == sort
        else {
            return
        }
        let selectedIDs = Set(ids)
        guard !selectedIDs.isEmpty else {
            selectMessage(nil)
            return
        }
        selectionRevision &+= 1
        selectedMessageIDs = selectedIDs
        selectedMessageID = nil
        scheduleAutomationStatePublication()
    }

    func selectMessage(_ id: MessageID?) {
        guard selectedMessageIDs != (id.map { [$0] } ?? [])
            || selectedMessageID != id else { return }
        selectionRevision &+= 1
        selectedMessageIDs = id.map { [$0] } ?? []
        selectedMessageID = id
        guard let id else {
            clearReaderSelection()
            scheduleAutomationStatePublication()
            return
        }
        loadMessageDetail(id)
        scheduleAutomationStatePublication()
    }

    private func loadMessageDetail(_ id: MessageID) {
        detailLoadTask?.cancel()
        detailLoadTask = nil
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
        scheduleAutomationStatePublication()
        detailLoadTask = Task { @MainActor [weak self] in
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
        scheduleAutomationStatePublication()
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


    /// Routes a UI read gesture through the durable command boundary.
    func markRead(_ id: MessageID) {
        dispatchFromUI(.markRead(.explicit([id])))
    }


    func perform(_ kind: SwipeActionKind, on id: MessageID) {
        perform(kind, on: [id])
    }

    /// Converts native gesture actions into the same structured commands used
    /// by the CLI. The command executor remains the only facade mutation path.
    func perform(_ kind: SwipeActionKind, on ids: Set<MessageID>) {
        guard !ids.isEmpty else { return }
        let target = MessageTarget.explicit(ids.sorted { $0.rawValue < $1.rawValue })
        switch kind {
        case .archive:
            dispatchFromUI(.archive(target))
        case .trash:
            dispatchFromUI(.trash(target))
        case .toggleRead:
            let shouldRead = ids.contains { id in
                !(listRows.first(where: { $0.id == id })?.isRead ?? false)
            }
            dispatchFromUI(shouldRead ? .markRead(target) : .markUnread(target))
        case .toggleFlag:
            let shouldFlag = ids.contains { id in
                !(listRows.first(where: { $0.id == id })?.isFlagged ?? false)
            }
            dispatchFromUI(.setFlagged(target, shouldFlag))
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


    func move(ids: Set<MessageID>, to folder: FolderID) {
        guard !ids.isEmpty else { return }
        dispatchFromUI(
            .move(
                .explicit(ids.sorted { $0.rawValue < $1.rawValue }),
                folder
            )
        )
    }

    func moveDirect(ids: Set<MessageID>, to folder: FolderID) async throws -> MoveOutcome {
        guard !ids.isEmpty else {
            return MoveOutcome(movedCount: 0, skippedCrossAccountCount: 0)
        }
        let orderedIDs = ids.sorted { $0.rawValue < $1.rawValue }
        let rollbackRows = listRows.filter { ids.contains($0.id) }
        let rollbackSelection = selectedMessageIDs
        let rollbackAnchor = selectedMessageID
        removeListRows(ids)
        do {
            let outcome = try await facade.move(orderedIDs, to: folder)
            let acceptedIDs = outcome.acceptedIDs.isEmpty && outcome.movedCount == ids.count
                ? ids
                : outcome.acceptedIDs
            let skippedIDs = ids.subtracting(acceptedIDs)
            if !acceptedIDs.isEmpty {
                await reconcileRetainedTabs(for: acceptedIDs)
            }
            scheduleTabsPersistence()
            if !skippedIDs.isEmpty {
                restoreMovedRows(
                    rollbackRows.filter { skippedIDs.contains($0.id) },
                    selectedIDs: rollbackSelection.intersection(skippedIDs),
                    anchor: rollbackAnchor.flatMap { skippedIDs.contains($0) ? $0 : nil }
                )
            }
            scheduleAutomationStatePublication()
            return outcome
        } catch {
            restoreMovedRows(
                rollbackRows,
                selectedIDs: rollbackSelection,
                anchor: rollbackAnchor
            )
            scheduleAutomationStatePublication()
            throw error
        }
    }

    /// Refreshes durable reader-tab identity from the facade after a move or
    /// ordinary page observation. The facade supplies the current folder,
    /// generation-scoped link, and any exact local alias's canonical row ID;
    /// no destination UID is inferred in this module.
    private func reconcileRetainedTabs(
        for requestedIDs: Set<MessageID>? = nil,
        removeMissing: Bool = false
    ) async {
        let candidates = tabs.tabs.filter { tab in
            requestedIDs == nil || requestedIDs!.contains(tab.message)
        }
        guard !candidates.isEmpty else { return }
        let states: [MessageMutationState]
        do {
            states = try await facade.messageMutationStates(candidates.map(\.message))
        } catch {
            return
        }
        let statesByID = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) })
        var changedLinks = false
        for tab in candidates {
            guard let state = statesByID[tab.message] else {
                continue
            }
            if let link = state.link,
               let value = link.formattedString {
                if messageDeepLinks[tab.message] != value
                    || messageDeepLinks[state.canonicalID] != value {
                    changedLinks = true
                }
                messageDeepLinks[tab.message] = value
                messageDeepLinks[state.canonicalID] = value
            }
            _ = tabs.updateIdentity(
                tab.id,
                folderID: state.folderID,
                canonicalID: state.canonicalID,
                link: state.link
            )
        }
        if removeMissing {
            let missing = candidates
                .filter { statesByID[$0.message] == nil }
                .map(\.message)
            for id in missing {
                messageRemoved(id)
            }
        }
        if changedLinks {
            scheduleTabsPersistence()
            scheduleAutomationStatePublication()
        }
    }

    private func scheduleRetainedTabReconciliation() {
        Task { @MainActor [weak self] in
            await self?.reconcileRetainedTabs()
        }
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
        guard !links.isEmpty else { return }
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
        dispatchFromUI(.nextTab)
    }

    func activateNextTabDirect() {
        activateAdjacentTab(forward: true)
    }

    /// See ``activateNextTab()``.
    func activatePreviousTab() {
        dispatchFromUI(.previousTab)
    }

    func activatePreviousTabDirect() {
        activateAdjacentTab(forward: false)
    }

    func closeOtherTabs(_ id: UUID) {
        dispatchFromUI(.closeOthers(id))
    }

    func closeTabsToRight(_ id: UUID) {
        dispatchFromUI(.closeToRight(id))
    }

    func keepTab(_ id: UUID) {
        dispatchFromUI(.keepTab(id))
    }

    func moveTab(_ id: UUID, to index: Int) {
        dispatchFromUI(.moveTab(id, index))
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
        activateTabDirect(id)
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
        dispatchFromUI(.openMessage(.local(id), permanent: permanent))
    }
    /// Opens one or more messages through the command FIFO. Transient
    /// previews are coalesced only while still pending at that boundary.
    func openMessages(_ ids: [MessageID], permanent: Bool) {
        guard let finalID = ids.last else { return }
        if !permanent {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
                QALaunch.log(
                    "selection-perf event=preview-queue message=\(finalID.rawValue) t=\(DispatchTime.now().uptimeNanoseconds)"
                )
            }
            #endif
            dispatchFromUI(.openMessage(.local(finalID), permanent: false))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
                QALaunch.log(
                    "selection-perf event=preview-final-queue message=\(finalID.rawValue) t=\(DispatchTime.now().uptimeNanoseconds)"
                )
            }
            #endif
            do {
                if ids.count > 1 {
                    _ = try await dispatch(
                        .selectMessages(
                            .explicit(ids),
                            anchor: MessageReference.local(finalID)
                        ),
                        origin: .app,
                        grant: .local
                    )
                }
                _ = try await dispatch(
                    .openMessage(.local(finalID), permanent: true),
                    origin: .app,
                    grant: .local
                )
                #if DEBUG
                if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
                    QALaunch.log(
                        "selection-perf event=preview-final-applied message=\(finalID.rawValue) t=\(DispatchTime.now().uptimeNanoseconds)"
                    )
                }
                #endif
            } catch {
                toasts.post(title: "Couldn’t open message", detail: error.localizedDescription, severity: .error)
            }
        }
    }

    /// Direct tab transition used by the command executor and internal route
    /// restoration. All user-facing callers use `openMessages` above.
    func openMessagesDirect(_ ids: [MessageID], permanent: Bool) {
        let preservedSelection = ids.count > 1 ? Set(ids) : nil
        guard let finalID = ids.last else { return }
        let existingTabID = tabs.tabs.first(where: {
            $0.message == finalID || $0.canonicalID == finalID
        })?.id
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
            selectFolderDirect(folder)
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
                guard self.tabs.activeID == activeTabID,
                      self.tabs.active?.message == activeMessageID else { return }
                if self.selectedFolderID != folder {
                    self.selectFolderDirect(folder)
                }
                if !self.listRows.contains(where: { $0.id == activeMessageID }) {
                    self.listRows.insert(row, at: 0)
                }
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
        dispatchFromUI(.activateTab(id))
    }

    func activateTabDirect(_ id: UUID) {
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
        // A retained tab already knows its resolved folder even when its row
        // is outside the current list page. Keep cached activation synchronous
        // instead of tearing down the reader while resolving the same link.
        if let folder = folderContaining(tab.message),
           (tab.folderID != nil || listRows.contains(where: { $0.id == tab.message })),
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
            selectFolderDirect(nil)
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
        scheduleAutomationStatePublication()
    }

    /// Retained links preserve account ownership after disabled folders leave
    /// the visible folder snapshot.
    private func canSync(folder: FolderID) -> Bool {
        if let summary = folders.first(where: { $0.id == folder }),
           let account = accountConfigs.first(where: { $0.id == summary.accountID }) {
            return account.isEnabled
        }
        if let link = tabs.tabs.first(where: { $0.folderID == folder && $0.link != nil })?.link,
           let account = accountConfigs.first(where: { $0.accountLinkID == link.accountLinkID }) {
            return account.isEnabled
        }
        return true
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
        guard readerHasFocus(in: window) else {
            window.performClose(nil)
            return
        }
        closeActiveReaderTab()
    }

    /// Uses the same logical pane marker and native responder precedence for
    /// window commands and automation's focused-surface snapshot.
    func readerHasFocus(in window: NSWindow) -> Bool {
        if window.firstResponder === interactionResponder {
            return readerInteractionActive
        }
        return MainWindowController.shared.isReaderFocused(in: window)
    }


    /// Records a click in the reader pane for focus-sensitive window commands.
    func noteReaderInteraction() {
        readerInteractionActive = true
        interactionResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        scheduleAutomationStatePublication()
    }

    /// Records a click in the list for focus-sensitive window commands.
    func noteListInteraction() {
        readerInteractionActive = false
        interactionResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        scheduleAutomationStatePublication()
    }

    /// Closes a tab from an explicit reader-tab close affordance. This path
    /// must not depend on first-responder focus because the close button lives
    /// in the toolbar rather than in the reader pane.
    func closeReaderTab(_ id: UUID) {
        dispatchFromUI(.closeTab(id))
    }

    func closeReaderTabDirect(_ id: UUID) {
        let wasActive = tabs.activeID == id
        tabs.close(id)
        guard wasActive else { return }
        if let active = tabs.active {
            activateTabDirect(active.id)
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
                activateTabDirect(active.id)
            } else {
                clearReaderSelection()
                selectedMessageIDs.removeAll()
                selectedMessageID = nil
            }
        }
        scheduleAutomationStatePublication()
        return true
    }

    /// Detail/route failures mean the message is gone, not a reader loading
    /// state. Remove its tab without a toast and leave the reader empty when
    /// no other tab remains.
    private func closeUnavailableTab(messageID: MessageID) {
        detailLoader.invalidate(messageID)
        guard let tabID = tabs.tabs.first(where: {
            $0.message == messageID || $0.canonicalID == messageID
        })?.id else {
            return
        }
        let wasActive = tabs.activeID == tabID
        tabs.close(tabID)
        guard wasActive else { return }
        if let active = tabs.active {
            activateTabDirect(active.id)
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
            selectFolderDirect(folder)
        }
        let selectionChanged = selectedMessageIDs != [id]
            || selectedMessageID != id
        let alreadySelected = !selectionChanged
            && detail?.id == id
            && !isLoadingDetail
        if selectionChanged {
            selectionRevision &+= 1
        }
        selectedMessageIDs = [id]
        selectedMessageID = id
        scheduleAutomationStatePublication()
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
        if let root = MailternalLaunchOptions.containerURL ?? QALaunch.parse()?.containerRoot {
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

    private func scheduleTabsPersistence() {
        tabSaveTask?.cancel()
        tabSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            var links: [UUID: String] = [:]
            for tab in self.tabs.tabs {
                guard !Task.isCancelled else { return }
                if let link = try? await self.facade.makeDeepLink(for: tab.message),
                   let value = link.formattedString {
                    links[tab.id] = value
                } else if let value = self.messageDeepLinks[tab.message] {
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
                self.activateTabDirect(activeID)
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
                await self.reconcileRetainedTabs(removeMissing: true)
            }
        }
    }
    func openSearchResult(_ id: MessageID) {
        dispatchFromUI(.openSearchResult(.local(id)))
    }

    func openSearchResult(_ row: MessageRow) {
        openSearchResult(row.id)
    }

    func openSearchResultDirect(_ id: MessageID) {
        searchPresentation.cancel()
        isSearchPresented = false
        searchFieldFocused = false
        toasts.isSuppressed = false
        openMessagesDirect([id], permanent: false)
    }


    func refresh() async {
        do {
            _ = try await dispatch(.refresh, origin: .app, grant: .local)
        } catch {
            toasts.post(title: "Couldn’t refresh mail", detail: error.localizedDescription, severity: .error)
        }
    }

    func refreshDirect() async {
        if !syncStatus.isOnline {
            toasts.post(title: "You’re offline", detail: "Mail will refresh when the connection returns.", severity: .warning)
        }
        await facade.refresh()
    }

    /// Routes search presentation changes through the serialized command lane.
    /// The executor owns query work and cancellation so native and automation
    /// callers cannot race a facade search.
    func setSearchQuery(_ query: String) {
        dispatchFromUI(.setSearchQuery(query))
    }

    func selectSearchResult(_ id: MessageID?) {
        dispatchFromUI(.selectSearchResult(id.map(MessageReference.local)))
    }

    func setSearchFieldFocused(_ focused: Bool) {
        dispatchFromUI(.setSearchFieldFocused(focused))
    }

    func cancelSearch() {
        dispatchFromUI(.cancelSearch)
    }

    func setPairingPresented(_ presented: Bool) {
        dispatchFromUI(.setPairingPresented(presented))
    }
    func performPairingAction(_ action: PairingUIAction) {
        dispatchFromUI(.pairingUI(action))
    }

    func toggleSearch() {
        dispatchFromUI(.toggleSearch)
    }

    func toggleSearchDirect() {
        guard isAccountActive else { return }
        isSearchPresented.toggle()
        toasts.isSuppressed = isSearchPresented
        if isSearchPresented {
            isFindPresented = false
        } else {
            searchFieldFocused = false
        }
    }
    /// state event includes the same transition seen by automation clients.
    func toggleEmailReadingOverride() {
        let next = EmailReadingOverridePolicy.next(effective: effectiveEmailReadingMode)
        guard let mode = AutomationReadingMode(rawValue: next.rawValue) else { return }
        dispatchFromUI(.setReadingMode(mode))
    }

    func setReadingModeDirect(_ mode: AutomationReadingMode) {
        emailReadingOverride = EmailReadingMode(rawValue: mode.rawValue)
        if let readingMode = emailReadingOverride {
            readerSurfacePool.updateReadingMode(readingMode)
        }
    }

    /// Toggles raw source through the explicit GUI command boundary.
    func toggleRawSource() {
        dispatchFromUI(.toggleRawSource)
    }

    func toggleRawSourceDirect() {
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
        dispatchFromUI(.toggleFind)
    }

    func toggleFindDirect() {
        guard detail != nil else { return }
        isFindPresented.toggle()
        if !isFindPresented { findQuery = "" }
    }

    func setFindPresentedDirect(_ presented: Bool) {
        guard !presented || detail != nil else { return }
        isFindPresented = presented
        if !presented {
            findQuery = ""
        }
    }

    func toggleSidebar() {
        dispatchFromUI(.toggleSidebar)
    }

    func toggleSidebarDirect() {
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

    /// Settings edits use the structured account command so journal/state
    /// publication stays identical to CLI and paired clients.
    func setRemoteImagesAllowed(_ allowed: Bool) {
        dispatchFromUI(.setRemoteImages(allowed))
    }
    func setFindQuery(_ query: String) {
        dispatchFromUI(.setFindQuery(query))
    }
    func updateAccount(_ config: AccountConfig, password: String?) async throws {
        let hasPassword = password?.isEmpty == false
        _ = try await dispatch(
            .saveAccount(config, hasPassword: hasPassword),
            origin: .app,
            grant: .local,
            secret: password
        )
    }

    func setAccountEnabled(_ id: AccountID, _ enabled: Bool) async {
        do {
            _ = try await dispatch(.setAccountEnabled(id, enabled), origin: .app, grant: .local)
        } catch {
            toasts.post(
                title: "Couldn’t update account",
                detail: error.localizedDescription,
                severity: .error
            )
        }
    }
    func removeAccount(_ id: AccountID) async throws {
        _ = try await dispatch(.removeAccount(id), origin: .app, grant: .local)
    }
    func setKeepLocally(_ id: FolderID, _ keep: Bool) async throws {
        _ = try await dispatch(.setRetention(id, keep), origin: .app, grant: .local)
    }

    func showSettings() {
        dispatchFromUI(.showSettings)
    }

    func showSettingsDirect() {
        SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
    }

    /// Opens a message in its own reader window. The detail fetch supplies
    /// the AppKit window title while the window's reader performs its own
    func openMessageWindow(_ id: MessageID) {
        dispatchFromUI(.openWindow(.local(id)))
    }

    func openMessageWindowDirect(_ id: MessageID) {
        Task { [weak self] in
            guard let self else { return }
            var subject: String?
            var accountLinkID: AccountLinkID?
            do {
                let detail = try await facade.detail(id)
                subject = detail.envelope.subject
            } catch {
                subject = nil
            }
            if let states = try? await facade.messageMutationStates([id]) {
                accountLinkID = states.first?.accountLinkID
            }
            guard !Task.isCancelled else { return }
            MessageWindowController.shared.show(
                messageID: id,
                model: self,
                title: subject,
                accountLinkID: accountLinkID
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
            scheduleAutomationStatePublication()
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
        scheduleAutomationStatePublication()
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
            scheduleAutomationStatePublication()
            scheduleRetainedTabReconciliation()
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
            scheduleAutomationStatePublication()
            scheduleRetainedTabReconciliation()
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
        scheduleAutomationStatePublication()
        scheduleRetainedTabReconciliation()
    }

    private func appendPage(_ page: MessagePage) {
        let existing = Set(listRows.map(\.id))
        let appended = page.rows.filter { !existing.contains($0.id) }
        listRows.append(contentsOf: appended)
        listCursor = page.next
        if !appended.isEmpty {
            scheduleAdjacentDetailPrefetch()
        }
        scheduleAutomationStatePublication()
        scheduleRetainedTabReconciliation()
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
            self.scheduleAutomationStatePublication()
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
        if let tab = tabs.tabs.first(where: {
            $0.message == id || $0.canonicalID == id
        }), let folder = tab.folderID {
            return folder
        }
        if let mock = facade as? MockMailFacade {

            return mock.folderID(for: id)
        }
        return selectedFolderID
    }
    /// Registers detached-window ownership from the target's current
    /// mutation metadata. The main window deliberately remains unregistered.
    func registerAutomationWindow(
        _ window: NSWindow,
        accountLinkID: AccountLinkID?
    ) {
        let objectID = ObjectIdentifier(window)
        if let accountLinkID {
            automationWindowAccountLinks[objectID] = accountLinkID
        } else {
            automationWindowAccountLinks.removeValue(forKey: objectID)
        }
    }

    func unregisterAutomationWindow(_ window: NSWindow) {
        automationWindowAccountLinks.removeValue(forKey: ObjectIdentifier(window))
    }

    /// Internal runtime projection seam. Ownership is never inferred from the
    /// ambient main-window folder or account.
    func automationWindowAccountLinkID(for window: NSWindow) -> AccountLinkID? {
        automationWindowAccountLinks[ObjectIdentifier(window)]
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
