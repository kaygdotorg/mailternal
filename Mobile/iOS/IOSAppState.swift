import Foundation
import Observation
import SwiftUI
import MailternalInterfaces
import MailternalWorkspace

/// Serializable navigation and reading preferences owned by the iOS shell.
/// Mail content and credentials are deliberately absent from this document.
struct IOSPersistedState: Codable, Sendable {
    var selectedFolderRawValue: Int64?
    /// Canonical `mailternal://open/v1/...` identity; local message row IDs
    /// never cross the app/phone/watch seam.
    var selectedMessageLink: String?
    var readingMode: IOSReadingMode
    var showSenderIcons: Bool
    var remoteImagesAllowed: Set<Int64>
    /// Absent in older state files; nil restores the section-based settings view.
    var settingsFlatView: Bool? = nil

    static let empty = IOSPersistedState(
        selectedFolderRawValue: nil,
        selectedMessageLink: nil,
        readingMode: .original,
        showSenderIcons: true,
        remoteImagesAllowed: []
    )
}

enum IOSReadingMode: String, Codable, CaseIterable, Sendable {
    case original
    case dark

    var title: String {
        switch self {
        case .original: "Original"
        case .dark: "Dark"
        }
    }
}
enum IOSListSettingsScope: String, CaseIterable, Hashable, Sendable {
    case global
    case currentFolder

    var title: String {
        switch self {
        case .global: "All folders"
        case .currentFolder: "This folder"
        }
    }
}

extension MailListSort.Field {
    var title: String {
        switch self {
        case .date: "Date"
        case .sender: "Sender"
        case .subject: "Subject"
        case .read: "Read status"
        case .flagged: "Flagged"
        case .attachments: "Attachments"
        }
    }
}

extension MailListSort.Direction {
    var title: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }
}

extension MailListSort {
    var title: String {
        "\(field.title), \(direction.title)"
    }
}

extension MailListScope {
    /// The shared store's canonical sort field. Keeping reset field-scoped
    /// avoids deleting desktop columns or pane values from this workspace.
    fileprivate var sortKey: String {
        "\(MailListLayoutStore.keyPrefix)\(MailListLayoutStore.scopeToken(for: self)).sort"
    }
}

 

@MainActor
@Observable
final class IOSAppState {
    enum LaunchPhase: Equatable {
        case opening
        case restoring
        case ready
        case failed(String)
    }

    @ObservationIgnored let facade: any MailFacade
    @ObservationIgnored let dispatcher: IOSCommandDispatcher
    let actions: ActionSettings
    let workspace: WorkspaceSyncController
    let listLayout: MailListLayoutStore
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var pageObservationTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var pageGeneration = 0
    @ObservationIgnored private var detailGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var rowOpenGeneration: UInt64 = 0
    @ObservationIgnored private var listLayoutObservationGeneration: UInt64 = 0
    @ObservationIgnored private var activeListSort: MailListSort = .newest
    @ObservationIgnored private var applyingRemoteHandoff = false
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var companion: PhoneCompanionSession?

    var launchPhase: LaunchPhase = .opening
    var accounts: [AccountConfig] = []
    var accountStates: [AccountID: AccountState] = [:]
    var folders: [FolderSummary] = []
    var syncStatus = SyncStatus(mode: .fullHistory, isOnline: false)
    var selectedFolderID: FolderID?
    var listSettingsScope: IOSListSettingsScope = .currentFolder
    var rows: [MessageRow] = []
    var searchResults: [MessageRow] = []
    var nextPageCursor: MessagePageCursor?
    var hasMorePages = false
    var isLoadingPage = false
    var selectedMessageIDs: Set<MessageID> = []
    var selectedMessageID: MessageID?
    /// Preserves the resolved row's optimistic flag while a deep link
    /// switches folders and the containing row is outside the first page.
    var selectedMessageFlagState: Bool?
    var selectedMessageLink: String?
    var detail: MessageDetail?
    var isLoadingDetail = false
    var query = ""
    var isSettingsPresented = false
    var isApplyingRemoteNavigation = false
    var isSearching = false
    var searchErrorMessage: String?
    var errorMessage: String?
    var noticeMessage: String?
    var commandRevision = 0
    var isSelecting = false
    var readingMode: IOSReadingMode = .original
    var showSenderIcons = true
    var settingsFlatView = false
    var remoteImagesAllowed: Set<MessageID> = []

    init(facade: any MailFacade, commandURL: URL, stateURL: URL) {
        self.facade = facade
        self.stateURL = stateURL
        self.dispatcher = IOSCommandDispatcher(facade: facade, fileURL: commandURL)
        let workspace = WorkspaceSyncController(
            storageURL: stateURL.deletingLastPathComponent().appendingPathComponent("workspace.json"),
            containerIdentifier: "iCloud.org.kayg.mailternal"
        )
        self.workspace = workspace
        self.listLayout = MailListLayoutStore(controller: workspace)
        self.actions = ActionSettings()
        restoreUIState()
    }

    deinit {
        streamTasks.forEach { $0.cancel() }
        pageTask?.cancel()
        detailTask?.cancel()
        pageObservationTask?.cancel()
        searchTask?.cancel()
    }

    var selectedFolder: FolderSummary? {
        guard let selectedFolderID else { return nil }
        return folders.first(where: { $0.id == selectedFolderID })
    }

    /// The complete server-folder identity used by shared workspace keys.
    /// Local FolderID values intentionally never enter a persisted layout key.
    var effectiveListScope: MailListScope {
        listScope(for: selectedFolder)
    }

    var effectiveListConfiguration: MailListConfiguration {
        listLayout.configuration(for: effectiveListScope)
    }

    var effectiveListSort: MailListSort {
        effectiveListConfiguration.sort
    }

    var globalListConfiguration: MailListConfiguration {
        listLayout.configuration(for: .global)
    }

    var listSettingsScopeTitle: String {
        switch listSettingsScope {
        case .global: return "All folders"
        case .currentFolder:
            guard let selectedFolder, canCustomizeCurrentFolder else { return "All folders" }
            return "This folder (\(selectedFolder.name))"
        }
    }

    var listSortForSettings: MailListSort {
        listLayout.configuration(for: listSettingsTargetScope).sort
    }

    var canCustomizeCurrentFolder: Bool {
        if case .folder = effectiveListScope { return true }
        return false
    }

    private var listSettingsTargetScope: MailListScope {
        switch listSettingsScope {
        case .global: return .global
        case .currentFolder: return effectiveListScope
        }
    }

    private func listScope(for folder: FolderSummary?) -> MailListScope {
        guard let folder,
              let account = accounts.first(where: { $0.id == folder.accountID }),
              !folder.path.isEmpty
        else {
            return .global
        }
        return .folder(account: account.accountLinkID, path: folder.path)
    }

    private func listScope(for folderID: FolderID?) -> MailListScope {
        listScope(for: folderID.flatMap { id in folders.first(where: { $0.id == id }) })
    }

    private func listConfiguration(for folderID: FolderID?) -> MailListConfiguration {
        listLayout.configuration(for: listScope(for: folderID))
    }

    var activeAccountState: AccountState {
        if let account = selectedFolder?.accountID { return accountStates[account] ?? .none }
        return facade.accountState
    }

    var enabledAccounts: [AccountConfig] { accounts.filter(\.isEnabled) }
    var pendingMutationCount: Int { dispatcher.pendingCount }
    var reviewMutationCount: Int { dispatcher.needsReviewCount }
    var workspaceStorageURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("workspace.json")
    }

    func attachCompanion(_ companion: PhoneCompanionSession) {
        self.companion = companion
        companion.attachListLayout(listLayout)
    }

    /// Starts the one-consumer observations and restores persisted accounts.
    /// The app scene calls this from a task, keeping the first SwiftUI frame
    /// independent of SQLite migration or network authentication.
    func start() async {
        guard !didStart else { return }
        didStart = true
        launchPhase = .restoring
        do {
            if let live = facade as? LiveMailFacade {
                await live.restorePersistedAccounts()
                switch live.storeLoadState {
                case .failed(let message):
                    launchPhase = .failed(message)
                    errorMessage = message
                    didStart = false
                    return
                default:
                    launchPhase = .ready
                }
            } else {
                await restoreAccountsIfSupported()
                launchPhase = .ready
            }
            try await finishPairingAccountLinkCommands(facade: facade, workspace: workspace)
            // The journal is the handoff between UI intent and the facade's
            // durable queues. Resume only after account restoration so the
            // restored engines can accept pending work; interrupted records
            // are moved to Settings → Pending Actions by the dispatcher.
            await dispatcher.resumeSafeCommands()
            if let journalError = dispatcher.loadError {
                launchPhase = .failed(journalError)
                errorMessage = journalError
                return
            }
        } catch {
            didStart = false
            launchPhase = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            return
        }
        observeFacadeStreams()
        await workspace.synchronize()
        let persistedLink = selectedMessageLink
        let previousHandoffState = applyingRemoteHandoff
        applyingRemoteHandoff = true
        if selectedFolderID == nil, let first = folders.first(where: { $0.keepLocally }) {
            await selectFolder(first.id)
        } else if let selectedFolderID, folders.contains(where: { $0.id == selectedFolderID }) {
            await selectFolder(selectedFolderID)
        }
        applyingRemoteHandoff = previousHandoffState
        if let persistedLink {
            selectedMessageLink = persistedLink
        }
        applyWorkspaceValues()
        observeListLayout()
        await publishLocalWorkspaceValues()
        if let selectedMessageLink {
            _ = await openDeepLink(selectedMessageLink)
        } else if let selectedMessageID {
            _ = await open(messageID: selectedMessageID)
        }
        companion?.activate()
    }

    private func restoreAccountsIfSupported() async {
        // The production facade is LiveMailFacade. Keeping this narrow branch
        // allows an integration host to inject another MailFacade without
        // creating a second mail engine or a test-only UI path.
        if let restorer = facade as? IOSAccountRestorer {
            await restorer.restorePersistedAccounts()
        }
    }

    private func observeFacadeStreams() {
        streamTasks.append(Task { @MainActor [weak self, stream = facade.accountsStream] in
            for await accounts in stream {
                guard let self else { return }
                let previousSort = self.effectiveListSort
                self.accounts = accounts
                if self.effectiveListSort != previousSort {
                    await self.restartList(for: self.effectiveListSort)
                }
                self.observeListLayout()
                await self.companion?.update(folders: self.folders)
            }
        })
        streamTasks.append(Task { @MainActor [weak self, stream = facade.accountStatesStream] in
            for await states in stream {
                guard let self else { return }
                self.accountStates = states
            }
        })
        streamTasks.append(Task { @MainActor [weak self, stream = facade.foldersStream] in
            for await folders in stream {
                guard let self else { return }
                let previousScope = self.effectiveListScope
                self.folders = folders.sorted { lhs, rhs in
                    if lhs.accountID != rhs.accountID { return lhs.accountID.rawValue < rhs.accountID.rawValue }
                    return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
                let scopeChanged = previousScope != self.effectiveListScope
                var replacementFolder: FolderID?
                if let selected = self.selectedFolderID, !self.folders.contains(where: { $0.id == selected }) {
                    replacementFolder = self.folders.first(where: { $0.keepLocally })?.id
                    self.selectedFolderID = nil
                    self.selectedMessageIDs.removeAll()
                    self.selectedMessageID = nil
                    self.selectedMessageFlagState = nil
                    self.selectedMessageLink = nil
                    self.detailTask?.cancel()
                    self.detailGeneration &+= 1
                    self.detail = nil
                    self.invalidatePaging(clearRows: true)
                    self.persistUIState()
                    Task { await self.publishWorkspaceReadingLink() }
                }
                if let replacementFolder {
                    await self.selectFolder(replacementFolder)
                } else if self.selectedFolderID == nil, let first = self.folders.first(where: { $0.keepLocally }) {
                    await self.selectFolder(first.id)
                } else if scopeChanged, let selected = self.selectedFolderID {
                    await self.selectFolder(selected)
                } else if let selected = self.selectedFolderID,
                          self.rows.isEmpty,
                          !self.isLoadingPage,
                          !self.hasMorePages {
                    await self.selectFolder(selected)
                }
                self.observeListLayout()
                await self.companion?.update(folders: self.folders)
            }
        })
        streamTasks.append(Task { @MainActor [weak self, stream = facade.syncStatusStream] in
            for await status in stream {
                guard let self else { return }
                self.syncStatus = status
            }
        })
    }

    func selectFolder(_ folderID: FolderID) async {
        guard let summary = folders.first(where: { $0.id == folderID }) else { return }
        selectedFolderID = folderID
        invalidatePaging(clearRows: true)
        let selectionGeneration = pageGeneration
        activeListSort = listConfiguration(for: folderID).sort
        selectedMessageIDs.removeAll()
        selectedMessageID = nil
        selectedMessageFlagState = nil
        selectedMessageLink = nil
        detailTask?.cancel()
        detailGeneration &+= 1
        detail = nil
        isLoadingDetail = false
        isSelecting = false
        facade.reportVisibleFolderIfSupported(folderID)
        observeListLayout()

        if summary.keepLocally {
            await loadNextPage(reset: true)
            guard pageGeneration == selectionGeneration,
                  selectedFolderID == folderID,
                  activeListSort == effectiveListSort else { return }
            startPageObservation(
                in: folderID,
                generation: selectionGeneration,
                sort: activeListSort
            )
        }
        persistUIState()
        await publishWorkspaceReadingLink()
    }

    private func invalidatePaging(clearRows: Bool) {
        pageGeneration &+= 1
        pageTask?.cancel()
        pageTask = nil
        pageObservationTask?.cancel()
        pageObservationTask = nil
        isLoadingPage = false
        if clearRows {
            rows.removeAll()
            nextPageCursor = nil
        }
        hasMorePages = selectedFolder?.keepLocally == true
    }

    private func observeListLayout() {
        listLayoutObservationGeneration &+= 1
        let generation = listLayoutObservationGeneration
        let scope = effectiveListScope
        withObservationTracking {
            _ = listLayout.configuration(for: scope)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.listLayoutObservationGeneration == generation,
                      self.didStart
                else { return }
                let sort = self.effectiveListSort
                if sort != self.activeListSort {
                    await self.restartList(for: sort)
                }
                self.observeListLayout()
            }
        }
    }

    private func restartList(for sort: MailListSort) async {
        activeListSort = sort
        invalidatePaging(clearRows: true)
        guard let folderID = selectedFolderID,
              selectedFolder?.keepLocally == true else {
            await companion?.update(folders: folders)
            return
        }
        let generation = pageGeneration
        await loadNextPage(reset: true)
        guard pageGeneration == generation,
              selectedFolderID == folderID,
              activeListSort == sort,
              effectiveListSort == sort else { return }
        startPageObservation(in: folderID, generation: generation, sort: sort)
        await companion?.update(folders: folders)
    }

    private func startPageObservation(
        in folderID: FolderID,
        generation: Int,
        sort: MailListSort
    ) {
        pageObservationTask?.cancel()
        let observedFacade = facade
        pageObservationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await page in observedFacade.observePage(
                in: folderID,
                after: nil,
                limit: 60,
                sort: sort
            ) {
                guard !Task.isCancelled,
                      self.pageGeneration == generation,
                      self.selectedFolderID == folderID,
                      self.activeListSort == sort,
                      self.effectiveListSort == sort else { return }
                self.applyObservedFirstPage(page)
            }
        }
    }

    /// The facade's observed page is the live first window. For the default
    /// newest-first order, merge it into materialized pages so paging never
    /// discards rows fetched after the first window. Other sort orders keep
    /// the authoritative observed page, matching the keyset contract.
    private func applyObservedFirstPage(_ page: MessagePage) {
        guard !rows.isEmpty else {
            rows = page.rows
            nextPageCursor = page.next
            hasMorePages = page.next != nil
            return
        }
        guard activeListSort == .newest else {
            rows = page.rows
            nextPageCursor = page.next
            hasMorePages = page.next != nil
            return
        }
        let incoming = Dictionary(uniqueKeysWithValues: page.rows.map { ($0.id, $0) })
        rows = rows.map { incoming[$0.id] ?? $0 }
        let existing = Set(rows.map(\.id))
        let prepend = page.rows.filter { !existing.contains($0.id) }
        if !prepend.isEmpty {
            rows.insert(contentsOf: prepend, at: 0)
        }
    }

    func setListSettingsScope(_ scope: IOSListSettingsScope) {
        guard scope != .currentFolder || canCustomizeCurrentFolder else {
            listSettingsScope = .global
            return
        }
        listSettingsScope = scope
    }

    func setListSort(_ sort: MailListSort) async {
        let scope = listSettingsTargetScope
        let previousSort = effectiveListSort
        do {
            try await listLayout.setSort(sort, for: scope)
            let updatedSort = effectiveListSort
            if updatedSort != previousSort {
                await restartList(for: updatedSort)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Removes only the selected scope's sort value, preserving desktop pane
    /// and column customizations that share the same workspace document.
    func resetListSort() async {
        let scope = listSettingsTargetScope
        let previousSort = effectiveListSort
        do {
            try await workspace.setValue(nil, for: scope.sortKey, category: .workspace)
            let updatedSort = effectiveListSort
            if updatedSort != previousSort {
                await restartList(for: updatedSort)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches a later keyset page while the first-window observation remains
    /// active, so live changes continue after the initial 60 rows are loaded.
    func loadNextPage(reset: Bool = false) async {
        guard let folderID = selectedFolderID,
              selectedFolder?.keepLocally == true,
              !isLoadingPage else { return }
        if reset {
            pageObservationTask?.cancel()
            pageObservationTask = nil
            rows.removeAll()
            nextPageCursor = nil
            hasMorePages = true
        }
        guard hasMorePages else { return }
        isLoadingPage = true
        pageTask?.cancel()
        let cursor = nextPageCursor
        let generation = pageGeneration
        let sort = activeListSort
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pageGeneration == generation,
                   self.selectedFolderID == folderID,
                   self.activeListSort == sort {
                    self.isLoadingPage = false
                    self.pageTask = nil
                }
            }
            guard !Task.isCancelled else { return }
            do {
                let page = try await self.facade.page(
                    in: folderID,
                    after: cursor,
                    limit: 60,
                    sort: sort
                )
                guard !Task.isCancelled,
                      self.pageGeneration == generation,
                      self.selectedFolderID == folderID,
                      self.activeListSort == sort,
                      self.effectiveListSort == sort else { return }
                var existing = Set(self.rows.map(\.id))
                self.rows.append(contentsOf: page.rows.filter { existing.insert($0.id).inserted })
                self.nextPageCursor = page.next
                self.hasMorePages = page.next != nil
            } catch is CancellationError {
                return
            } catch {
                guard self.pageGeneration == generation,
                      self.selectedFolderID == folderID,
                      self.activeListSort == sort,
                      self.effectiveListSort == sort else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        pageTask = task
        await task.value
    }

    func refresh() async {
        noticeMessage = "Refreshing mail…"
        await facade.refresh()
        if let selectedFolderID { await selectFolder(selectedFolderID) }
        await companion?.update(folders: folders)
        noticeMessage = "Mail is up to date."
    }

    @discardableResult
    func open(row: MessageRow) async -> Bool {
        rowOpenGeneration &+= 1
        let generation = rowOpenGeneration
        let initialPageGeneration = pageGeneration
        // Search rows can originate outside the currently selected folder.
        // Resolve a missing folder identity through the existing deep-link
        // contract rather than opening detail in a stale list context.
        let folderID = await folderID(for: row)
        guard !Task.isCancelled,
              rowOpenGeneration == generation,
              pageGeneration == initialPageGeneration else { return false }
        if let folderID, selectedFolderID != folderID {
            await selectFolder(folderID)
            guard !Task.isCancelled,
                  rowOpenGeneration == generation,
                  selectedFolderID == folderID else { return false }
        }
        selectedMessageFlagState = row.isFlagged
        selectedMessageIDs = [row.id]
        selectedMessageID = row.id
        return await open(messageID: row.id)
    }

    private func folderID(for row: MessageRow) async -> FolderID? {
        if let folderID = row.folderID { return folderID }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let link = try? await facade.makeDeepLink(for: row.id),
              let resolution = try? await facade.resolve(link) else {
            return nil
        }
        guard case .message(let folderID, _, _) = resolution else { return nil }
        return folderID
    }

    @discardableResult
    func open(messageID: MessageID) async -> Bool {
        rowOpenGeneration &+= 1
        detailTask?.cancel()
        detailGeneration &+= 1
        let generation = detailGeneration
        let shouldMarkRead = activeNavigationRows.first(where: { $0.id == messageID }).map { !$0.isRead } ?? false
        selectedMessageID = messageID
        isLoadingDetail = true
        detail = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.detailGeneration == generation,
                   self.selectedMessageID == messageID {
                    self.isLoadingDetail = false
                    self.detailTask = nil
                    self.persistUIState()
                }
            }
            do {
                let loaded = try await self.facade.detail(messageID)
                guard !Task.isCancelled,
                      self.detailGeneration == generation,
                      self.selectedMessageID == messageID else { return }
                self.detail = loaded

                let deepLink = try? await self.facade.makeDeepLink(for: messageID)
                guard !Task.isCancelled,
                      self.detailGeneration == generation,
                      self.selectedMessageID == messageID else { return }
                if let deepLink {
                    self.selectedMessageLink = deepLink.formattedString
                    await self.publishWorkspaceReadingLink()
                }

                if shouldMarkRead {
                    do {
                        try await self.dispatcher.submit(.markRead([messageID]))
                        await self.refreshSearchResultsIfNeeded()
                    } catch {
                        guard self.detailGeneration == generation,
                              self.selectedMessageID == messageID else { return }
                        self.errorMessage = error.localizedDescription
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.detailGeneration == generation,
                      self.selectedMessageID == messageID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        detailTask = task
        await task.value
        return detailGeneration == generation && selectedMessageID == messageID && detail?.id == messageID
    }

    private var activeNavigationRows: [MessageRow] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rows : searchResults
    }

    /// The flag state shown by the current reader selection, including the
    var selectedMessageIsFlagged: Bool {
        guard let selectedMessageID else { return false }
        return activeNavigationRows.first(where: { $0.id == selectedMessageID })?.isFlagged
            ?? selectedMessageFlagState
            ?? false
    }

    /// A selection can be unflagged only when every selected row is known and
    /// currently flagged; otherwise the safe action is to flag the selection.
    var selectedMessagesAreAllFlagged: Bool {
        guard !selectedMessageIDs.isEmpty else { return false }
        let selectedRows = activeNavigationRows.filter { selectedMessageIDs.contains($0.id) }
        guard selectedRows.count == selectedMessageIDs.count else { return false }
        return selectedRows.allSatisfy(\.isFlagged)
    }

    var canNavigatePrevious: Bool {
        guard let selectedMessageID,
              let index = activeNavigationRows.firstIndex(where: { $0.id == selectedMessageID }) else { return false }
        return index > 0
    }

    var canNavigateNext: Bool {
        guard let selectedMessageID,
              let index = activeNavigationRows.firstIndex(where: { $0.id == selectedMessageID }) else { return false }
        return index + 1 < activeNavigationRows.count
            || (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasMorePages)
    }

    func openAdjacent(delta: Int) async {
        guard let selectedMessageID,
              let index = activeNavigationRows.firstIndex(where: { $0.id == selectedMessageID }) else { return }
        let currentRows = activeNavigationRows
        let target = index + delta
        if currentRows.indices.contains(target) {
            _ = await open(row: currentRows[target])
        } else if delta > 0,
                  query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  hasMorePages {
            let oldCount = rows.count
            await loadNextPage()
            guard selectedFolderID != nil, rows.count > oldCount else { return }
            _ = await open(row: rows[oldCount])
        }
    }

    func toggleSelection(_ row: MessageRow) {
        if selectedMessageIDs.contains(row.id) { selectedMessageIDs.remove(row.id) }
        else { selectedMessageIDs.insert(row.id) }
        isSelecting = !selectedMessageIDs.isEmpty
    }

    func selectAllVisible() {
        selectedMessageIDs = Set(activeNavigationRows.map(\.id))
        isSelecting = !selectedMessageIDs.isEmpty
    }

    func clearSelection() { selectedMessageIDs.removeAll(); isSelecting = false }

    func markSelected(read: Bool) async {
        let ids = Array(selectedMessageIDs)
        guard !ids.isEmpty else { return }
        do {
            try await dispatcher.submit(read ? .markRead(ids) : .markUnread(ids))
            await selectFolderIfNeeded()
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func setFlagged(_ flagged: Bool, ids: Set<MessageID> = []) async {
        let ids = ids.isEmpty ? selectedMessageIDs : ids
        guard !ids.isEmpty else { return }
        do {
            try await dispatcher.submit(.setFlagged(Array(ids), flagged))
            await selectFolderIfNeeded()
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func archiveSelected(_ ids: Set<MessageID>? = nil) async {
        let ids = ids ?? selectedMessageIDs
        await submitTriage(.archive(Array(ids)), ids: ids)
    }

    func trashSelected(_ ids: Set<MessageID>? = nil) async {
        let ids = ids ?? selectedMessageIDs
        await submitTriage(.trash(Array(ids)), ids: ids)
    }

    func moveSelected(to folder: FolderID) async {
        let ids = selectedMessageIDs
        await submitTriage(.move(Array(ids), folder), ids: ids)
    }

    private func submitTriage(
        _ command: IOSCommandDispatcher.Command,
        ids: Set<MessageID>
    ) async {
        guard !ids.isEmpty else { return }
        do {
            let outcome = try await dispatcher.submit(command)
            if case .move = command,
               let outcome,
               outcome.skippedCrossAccountCount > 0 {
                let rejected = ids.subtracting(outcome.acceptedIDs)
                await selectFolderIfNeeded()
                selectedMessageIDs = rejected
                isSelecting = !rejected.isEmpty
                noticeMessage = rejected.isEmpty
                    ? "Move queued."
                    : "\(outcome.movedCount) moved; \(rejected.count) could not move across accounts."
            } else {
                clearSelection()
                await selectFolderIfNeeded()
            }
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    private func selectFolderIfNeeded() async {
        if let folder = selectedFolderID { await selectFolder(folder) }
        await refreshSearchResultsIfNeeded()
        await companion?.update(folders: folders)
    }

    func renameFolder(_ folder: FolderSummary, name: String) async {
        do {
            try await dispatcher.submit(.renameFolder(folder.id, name))
            noticeMessage = "Folder rename queued."
            await companion?.update(folders: folders)
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func setRetention(_ folder: FolderSummary, keep: Bool) async {
        do {
            try await dispatcher.submit(.setRetention(folder.id, keep))
            await companion?.update(folders: folders)
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func search(_ text: String) async {
        let previousQuery = query
        query = text
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults.removeAll()
            searchErrorMessage = nil
            isSearching = false
            return
        }
        if previousQuery != text {
            searchResults.removeAll()
        }
        searchErrorMessage = nil
        isSearching = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let results = try await self.facade.search(text, limit: 80)
                guard !Task.isCancelled,
                      self.searchGeneration == generation,
                      self.query == text else { return }
                self.searchResults = results
                self.searchErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.searchGeneration == generation,
                      self.query == text else { return }
                let message = error.localizedDescription
                self.searchErrorMessage = message
                self.errorMessage = message
                self.searchResults.removeAll()
            }
            if self.searchGeneration == generation, self.query == text {
                self.isSearching = false
                self.searchTask = nil
            }
        }
        searchTask = task
        await task.value
    }

    /// Re-runs the global search after a durable triage enqueue so optimistic
    /// read/flag/move state and removed rows are reflected immediately.
    private func refreshSearchResultsIfNeeded() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await search(query)
    }

    /// Loads the existing capped, on-demand raw-source path. The facade
    /// returns escaped source for plain-text display and this state method
    /// rejects cancellation or results for a no-longer-selected message.
    func rawSource() async -> String? {
        guard let selectedMessageID else { return nil }
        return await rawSource(for: selectedMessageID)
    }

    func rawSource(for messageID: MessageID) async -> String? {
        do {
            let source = try await facade.rawSource(messageID)
            guard !Task.isCancelled, selectedMessageID == messageID else { return nil }
            return source
        } catch is CancellationError {
            return nil
        } catch {
            guard selectedMessageID == messageID else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func fetchAttachment(_ attachment: AttachmentInfo, for messageID: MessageID? = nil) async -> URL? {
        guard let messageID = messageID ?? selectedMessageID else { return nil }
        do {
            let url = try await facade.fetchAttachment(messageID, part: attachment.id)
            guard !Task.isCancelled, selectedMessageID == messageID else { return nil }
            return url
        } catch is CancellationError {
            return nil
        } catch {
            guard selectedMessageID == messageID else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Sanitized HTML already contains self-describing `mailternal-part://`
    /// tokens. The WebKit scheme handler fetches those parts on demand.
    func renderedHTML(for detail: MessageDetail) async -> String? {
        guard !Task.isCancelled,
              selectedMessageID == detail.id,
              let html = detail.sanitizedHTML,
              !html.isEmpty else { return nil }
        return html
    }

    func setRemoteImagesAllowed(_ allowed: Bool) {
        guard let id = selectedMessageID else { return }
        if allowed { remoteImagesAllowed.insert(id) } else { remoteImagesAllowed.remove(id) }
        persistUIState()
    }
    func mark(_ row: MessageRow, read: Bool) async {
        do {
            try await dispatcher.submit(read ? .markRead([row.id]) : .markUnread([row.id]))
            await selectFolderIfNeeded()
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func toggleFlag(_ row: MessageRow) async {
        do {
            try await dispatcher.submit(.setFlagged([row.id], !row.isFlagged))
            await selectFolderIfNeeded()
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func archive(_ row: MessageRow) async {
        do {
            try await dispatcher.submit(.archive([row.id]))
            await selectFolderIfNeeded()
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func trash(_ row: MessageRow) async {
        do {
            try await dispatcher.submit(.trash([row.id]))
            await selectFolderIfNeeded()
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    var reviewRecords: [IOSCommandDispatcher.Record] {
        dispatcher.records.filter { $0.status == .failed || $0.status == .needsReview }
    }

    func retry(_ record: IOSCommandDispatcher.Record, password: String?) async {
        do {
            _ = try await dispatcher.retry(record.id, secret: password)
            commandRevision &+= 1
            noticeMessage = "\(record.command.title) queued."
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func discard(_ record: IOSCommandDispatcher.Record) {
        do {
            try dispatcher.discard(record.id)
            commandRevision &+= 1
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func updateAccount(_ config: AccountConfig, password: String?, isNew: Bool) async -> Bool {
        do {
            try await dispatcher.submit(
                .saveAccount(config, requiresPassword: isNew || password != nil),
                secret: password
            )
            noticeMessage = isNew ? "Account added." : "Account updated."
            return true
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setAccountEnabled(_ account: AccountConfig, enabled: Bool) async {
        do {
            try await dispatcher.submit(.setAccountEnabled(account.id, enabled))
            noticeMessage = enabled ? "Account enabled." : "Account disabled."
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func removeAccount(_ account: AccountConfig) async {
        do {
            try await dispatcher.submit(.removeAccount(account.id))
            noticeMessage = "Account removed."
        } catch {
            commandRevision &+= 1
            errorMessage = error.localizedDescription
        }
    }

    func setWorkspaceParticipation(_ enabled: Bool) async throws {
        try await workspace.setEnabled(enabled)
    }

    func applyWorkspaceValues() {
        if case .string(let raw) = workspace.values[WorkspaceKeys.readingMode],
           let mode = IOSReadingMode(rawValue: raw),
           mode != readingMode {
            readingMode = mode
            persistUIState()
        }
        if case .bool(let show) = workspace.values[WorkspaceKeys.senderIcons],
           show != showSenderIcons {
            showSenderIcons = show
            persistUIState()
        }
        if case .bool(let flat) = workspace.values[WorkspaceKeys.settingsFlatView],
           flat != settingsFlatView {
            settingsFlatView = flat
            persistUIState()
        }
        if case .string(let raw) = workspace.values[WorkspaceKeys.leadingSwipe],
           let data = raw.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            let decoded = values.compactMap(SwipeActionKind.init(rawValue:))
            if decoded != actions.swipeActions(for: .leading) {
                actions.setSwipeActions(decoded, for: .leading)
            }
        }
        if case .string(let raw) = workspace.values[WorkspaceKeys.trailingSwipe],
           let data = raw.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            let decoded = values.compactMap(SwipeActionKind.init(rawValue:))
            if decoded != actions.swipeActions(for: .trailing) {
                actions.setSwipeActions(decoded, for: .trailing)
            }
        }
        if case .string(let link) = workspace.values[WorkspaceKeys.readingLink],
           !link.isEmpty,
           link != selectedMessageLink {
            selectedMessageLink = link
            persistUIState()
        }
        guard didStart, effectiveListSort != activeListSort else { return }
        let sort = effectiveListSort
        Task { @MainActor [weak self] in
            guard let self,
                  self.didStart,
                  self.activeListSort != sort,
                  self.effectiveListSort == sort else { return }
            await self.restartList(for: sort)
            self.observeListLayout()
        }
    }

    func publishLocalWorkspaceValues() async {
        await publishLocalAppearance()
        await publishLocalActions()
        await publishWorkspaceReadingLink()
    }

    func publishLocalAppearance() async {
        guard !applyingRemoteHandoff else { return }
        do {
            try await workspace.setValue(
                .string(readingMode.rawValue),
                for: WorkspaceKeys.readingMode,
                category: .appearance
            )
            try await workspace.setValue(
                .bool(showSenderIcons),
                for: WorkspaceKeys.senderIcons,
                category: .appearance
            )
            try await workspace.setValue(
                .bool(settingsFlatView),
                for: WorkspaceKeys.settingsFlatView,
                category: .appearance
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func publishLocalActions() async {
        guard !applyingRemoteHandoff else { return }
        do {
            try await workspace.setValue(
                .string(actions.encodedSwipeActions(for: .leading)),
                for: WorkspaceKeys.leadingSwipe,
                category: .actions
            )
            try await workspace.setValue(
                .string(actions.encodedSwipeActions(for: .trailing)),
                for: WorkspaceKeys.trailingSwipe,
                category: .actions
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }


    private func publishWorkspaceReadingLink(force: Bool = false) async {
        guard force || !applyingRemoteHandoff else { return }
        do {
            try await workspace.setValue(
                selectedMessageLink.map(WorkspaceSyncValue.string),
                for: WorkspaceKeys.readingLink,
                category: .workspace
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adopts workspace settings after an inactive scene resumes. Mail handoff
    /// is intentionally the only value that can trigger navigation here.
    func resumeFromInactive() async {
        guard didStart else { return }
        isApplyingRemoteNavigation = true
        defer { isApplyingRemoteNavigation = false }
        let previousLink = selectedMessageLink
        await workspace.synchronize()
        applyWorkspaceValues()
        guard let link = selectedMessageLink, link != previousLink else { return }
        let previousHandoffState = applyingRemoteHandoff
        applyingRemoteHandoff = true
        defer { applyingRemoteHandoff = previousHandoffState }
        _ = await openDeepLink(link)
    }

    func accountStateDescription(_ account: AccountConfig) -> String? {
        switch accountStates[account.id] ?? .none {
        case .none: return account.isEnabled ? "Configured — waiting to connect" : "Disabled"
        case .validating: return "Connecting…"
        case .active: return "Connected"
        case .authFailed(let message), .connectionFailed(let message): return message
        }
    }

    func persistUIState() {
        let persisted = IOSPersistedState(
            selectedFolderRawValue: selectedFolderID?.rawValue,
            selectedMessageLink: selectedMessageLink,
            readingMode: readingMode,
            showSenderIcons: showSenderIcons,
            remoteImagesAllowed: Set(remoteImagesAllowed.map(\.rawValue)),
            settingsFlatView: settingsFlatView
        )
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.mailternal.encode(persisted)
            try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            // Navigation state is a convenience; never block mail work on it.
        }
    }

    private func restoreUIState() {
        guard let data = try? Data(contentsOf: stateURL),
              let persisted = try? JSONDecoder.mailternal.decode(IOSPersistedState.self, from: data) else { return }
        selectedFolderID = persisted.selectedFolderRawValue.map(FolderID.init(rawValue:))
        selectedMessageLink = persisted.selectedMessageLink
        readingMode = persisted.readingMode
        showSenderIcons = persisted.showSenderIcons
        remoteImagesAllowed = Set(persisted.remoteImagesAllowed.map(MessageID.init(rawValue:)))
        settingsFlatView = persisted.settingsFlatView ?? false
    }
    @discardableResult
    func openDeepLink(_ rawValue: String) async -> Bool {
        let suppressIntermediateHandoff = applyingRemoteHandoff
        guard let link = MailternalDeepLink(string: rawValue) else {
            selectedMessageLink = nil
            persistUIState()
            if !suppressIntermediateHandoff {
                await publishWorkspaceReadingLink(force: true)
            }
            errorMessage = "That Mailternal link is malformed or unsupported."
            return false
        }
        applyingRemoteHandoff = true
        defer { applyingRemoteHandoff = suppressIntermediateHandoff }
        do {
            guard let resolution = try await facade.resolve(link) else {
                selectedMessageLink = nil
                persistUIState()
                errorMessage = "That message is no longer available."
                if !suppressIntermediateHandoff {
                    await publishWorkspaceReadingLink(force: true)
                }
                return false
            }
            switch resolution {
            case .folder(let folderID):
                await selectFolder(folderID)
                let succeeded = selectedFolderID == folderID
                if succeeded {
                    persistUIState()
                    await publishWorkspaceReadingLink(force: !suppressIntermediateHandoff)
                }
                return succeeded
            case .message(let folderID, let messageID, let row):
                await selectFolder(folderID)
                guard await open(row: row),
                      selectedMessageID == messageID else { return false }
                selectedMessageLink = link.formattedString
                persistUIState()
                await publishWorkspaceReadingLink(force: !suppressIntermediateHandoff)
                return true
            }
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    enum WorkspaceKeys {
        static let readingMode = "mailternal.appearance.email-reading"
        static let senderIcons = "mailternal.appearance.showsSenderIcons"
        static let settingsFlatView = "mailternal.appearance.settingsFlatView"
        static let leadingSwipe = "mailternal.actions.swipe.leading"
        static let trailingSwipe = "mailternal.actions.swipe.trailing"
        static let readingLink = "mailternal.workspace.reading-link"

        static let categories: [String: WorkspaceSyncCategory] = [
            readingMode: .appearance,
            senderIcons: .appearance,
            settingsFlatView: .appearance,
            leadingSwipe: .actions,
            trailingSwipe: .actions,
            readingLink: .workspace,
        ]

        static func category(for key: String) -> WorkspaceSyncCategory? {
            categories[key] ?? (
                MailListLayoutStore.isSupportedKey(key) ? .workspace : nil
            )
        }
    }
}

/// Internal runtime seam implemented by the production facade without creating
/// another IMAP client.  LiveMailFacade is the concrete shipping adapter.
@MainActor
protocol IOSAccountRestorer {
    func restorePersistedAccounts() async
}

extension LiveMailFacade: IOSAccountRestorer {}

private extension JSONEncoder {
    static var mailternal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var mailternal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension MailFacade {
    func reportVisibleFolderIfSupported(_ folder: FolderID) {
        (self as? LiveMailFacade)?.reportVisibleFolder(folder)
    }
}
