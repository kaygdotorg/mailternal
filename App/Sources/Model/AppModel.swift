import AppKit
import Observation
import SwiftUI
import MailternalInterfaces

@MainActor
@Observable
final class AppModel {
    let facade: any MailFacade
    let appearance: AppearanceSettings
    let toasts = ToastPresenter()

    var accountState: AccountState = .none
    var folders: [FolderSummary] = []
    var selectedFolderID: FolderID?
    var selectedMessageID: MessageID?
    var detail: MessageDetail?
    var rawSource: String?
    var isShowingRawSource = false
    var syncStatus = SyncStatus(mode: .fullHistory, isOnline: true)
    var isSearchPresented = false
    var isFindPresented = false
    var findQuery = ""
    var columnVisibility: NavigationSplitViewVisibility = .all
    var listRows: [MessageRow] = []
    var listCursor: MessagePageCursor?
    var isPaging = false
    var isLoadingList = false
    var listEpoch: UInt64 = 0
    var isLoadingDetail = false
    var allowRemoteImages = false

    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var streamsStarted = false
    @ObservationIgnored private var markedRead: Set<MessageID> = []

    var selectedFolder: FolderSummary? {
        folders.first { $0.id == selectedFolderID }
    }

    var specialFolders: [FolderSummary] {
        folders.filter { $0.role != .none }.sorted {
            if $0.role.sortRank != $1.role.sortRank { return $0.role.sortRank < $1.role.sortRank }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var customFolders: [FolderSummary] {
        folders.filter { $0.role == .none }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var hasAccount: Bool {
        if case .none = accountState { return false }
        return true
    }

    var isAccountActive: Bool {
        if case .active = accountState { return true }
        return false
    }

    init(facade: any MailFacade, appearance: AppearanceSettings) {
        self.facade = facade
        self.appearance = appearance
        accountState = facade.accountState
    }

    func start() {
        guard !streamsStarted else { return }
        streamsStarted = true
        Task { [weak self] in
            guard let self else { return }
            if let live = facade as? LiveMailFacade {
                await live.restorePersistedAccount()
            }
            applyAccountState(facade.accountState)
            Task { [weak self] in
                guard let self else { return }
                for await state in facade.accountStateStream {
                    applyAccountState(state)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await folders in facade.foldersStream {
                    self.folders = folders
                    if selectedFolderID == nil, let inbox = folders.first(where: { $0.role == .inbox }) {
                        selectFolder(inbox.id)
                    } else if let selectedFolderID, folders.contains(where: { $0.id == selectedFolderID }) {
                        // keep
                    } else if let first = folders.first {
                        selectFolder(first.id)
                    }
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for await status in facade.syncStatusStream {
                    syncStatus = status
                }
            }
            if case .none = accountState {
                #if DEBUG
                if QALaunch.parse() != nil { return }
                #endif
                SettingsWindowController.shared.show(model: self, appearance: appearance)
            }
        }
    }

    func applyAccountState(_ state: AccountState) {
        let previous = accountState
        accountState = state
        switch state {
        case .none:
            folders = []
            selectedFolderID = nil
            selectedMessageID = nil
            detail = nil
            listRows = []
            SettingsWindowController.shared.show(model: self, appearance: appearance)
        case .authFailed(let message):
            toasts.post(title: "Couldn’t sign in", detail: message, severity: .error)
            SettingsWindowController.shared.show(model: self, appearance: appearance)
        case .connectionFailed(let message):
            toasts.post(title: "Couldn’t connect", detail: message, severity: .error)
            SettingsWindowController.shared.show(model: self, appearance: appearance)
        case .active:
            if case .active = previous { break }
            else { /* folders stream will populate */ }
        case .validating:
            break
        }
    }

    func selectFolder(_ id: FolderID?) {
        guard selectedFolderID != id else { return }
        selectedFolderID = id
        (facade as? LiveMailFacade)?.reportVisibleFolder(id)
        selectedMessageID = nil
        detail = nil
        rawSource = nil
        isShowingRawSource = false
        listRows = []
        listCursor = nil
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

    func selectMessage(_ id: MessageID?) {
        selectedMessageID = id
        isShowingRawSource = false
        rawSource = nil
        isFindPresented = false
        findQuery = ""
        allowRemoteImages = false
        guard let id else {
            detail = nil
            return
        }
        isLoadingDetail = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await facade.detail(id)
                guard selectedMessageID == id else { return }
                detail = loaded
                isLoadingDetail = false
                if listRows.first(where: { $0.id == id })?.isRead == false {
                    listRows = listRows.map { row in
                        guard row.id == id else { return row }
                        var updated = row
                        updated.isRead = true
                        return updated
                    }
                    markedRead.insert(id)
                    await facade.markRead(id)
                }
            } catch {
                isLoadingDetail = false
                toasts.post(title: "Couldn’t open message", detail: error.localizedDescription)
            }
        }
    }

    func openSearchResult(_ row: MessageRow) {
        isSearchPresented = false
        if let folder = folderContaining(row.id) {
            if selectedFolderID != folder {
                selectFolder(folder)
            }
        }
        selectMessage(row.id)
        if !listRows.contains(where: { $0.id == row.id }) {
            listRows.insert(row, at: 0)
        }
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

    func toggleFind() {
        guard detail != nil else { return }
        isFindPresented.toggle()
        if !isFindPresented { findQuery = "" }
    }

    func toggleSidebar() {
        withAnimation(MailMotion.sidebarToggle) {
            columnVisibility = columnVisibility == .all ? .doubleColumn : .all
        }
    }

    func showSettings() {
        SettingsWindowController.shared.show(model: self, appearance: appearance)
    }

    func loadRawSource() async {
        guard let id = selectedMessageID else { return }
        do {
            rawSource = try await facade.rawSource(id)
            isShowingRawSource = true
        } catch {
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
        guard let subject = detail?.envelope.subject ?? listRows.first(where: { $0.id == selectedMessageID })?.subject
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(subject, forType: .string)
    }

    private func applyFirstPage(_ page: MessagePage) {
        if listRows.isEmpty {
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
        let existing = Set(listRows.map(\.id))
        listRows.append(contentsOf: page.rows.filter { !existing.contains($0.id) })
        listCursor = page.next
    }

    private func folderContaining(_ id: MessageID) -> FolderID? {
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
