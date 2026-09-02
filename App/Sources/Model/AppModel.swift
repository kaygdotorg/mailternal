import AppKit
import Observation
import SwiftUI
import MailternalInterfaces
import MailternalSanitizer
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
    let facade: any MailFacade
    let appearance: AppearanceSettings
    let actions: ActionSettings
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

    /// Whether the sanitized message actually contains an app-controlled
    /// token for a remote image. Inline `cid:` parts do not require consent.
    var hasRemoteImageReferences: Bool {
        guard let html = detail?.sanitizedHTML, !html.isEmpty else { return false }
        return HTMLSanitizer.sanitize(html).hasRemoteReferences
    }

    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var deepLinkQueue = DeepLinkRouteQueue()
    @ObservationIgnored private var foldersSnapshotReady = false
    @ObservationIgnored private var streamsStarted = false
    @ObservationIgnored private var markedRead: Set<MessageID> = []

    var selectedFolder: FolderSummary? {
        folders.first { $0.id == selectedFolderID }
    }

    /// Display name shown by the message-list title when it is flipped to the
    /// owning account.
    var listTitleAccountName: String {
        facade.accountDisplayName ?? "Account"
    }
    var hasAccount: Bool {
        if case .none = accountState { return false }
        return true
    }

    var isAccountActive: Bool {
        if case .active = accountState { return true }
        return false
    }

    init(facade: any MailFacade, appearance: AppearanceSettings, actions: ActionSettings) {
        self.facade = facade
        self.appearance = appearance
        self.actions = actions
        accountState = facade.accountState
    }

    /// Receives platform open-URL events. Parsing happens at this one seam so
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

    private func prepareFolderForRoute(_ folderID: FolderID) {
        if selectedFolderID == folderID {
            pageTask?.cancel()
            selectedMessageID = nil
            detail = nil
            rawSource = nil
            isShowingRawSource = false
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
                selectMessage(messageID)
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
                    self.foldersSnapshotReady = true
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
                SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
            }
        }
    }

    func applyAccountState(_ state: AccountState) {
        let previous = accountState
        accountState = state
        switch state {
        case .none:
            foldersSnapshotReady = false
            folders = []
            selectedFolderID = nil
            selectedMessageID = nil
            detail = nil
            listRows = []
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
                markRead(id)
            } catch {
                isLoadingDetail = false
                toasts.post(title: "Couldn’t open message", detail: error.localizedDescription)
            }
        }
    }

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
        guard let index = listRows.firstIndex(where: { $0.id == id }) else { return }
        switch kind {
        case .archive:
            removeListRow(id)
            Task { [weak self] in await self?.facade.archive(id) }
        case .trash:
            removeListRow(id)
            Task { [weak self] in await self?.facade.trash(id) }
        case .toggleRead:
            var row = listRows[index]
            row.isRead.toggle()
            listRows[index] = row
            let isRead = row.isRead
            Task { [weak self] in
                if isRead {
                    await self?.facade.markRead(id)
                } else {
                    await self?.facade.markUnread(id)
                }
            }
        case .toggleFlag:
            var row = listRows[index]
            row.isFlagged.toggle()
            listRows[index] = row
            let flagged = row.isFlagged
            Task { [weak self] in
                await self?.facade.setFlagged(id, flagged)
            }
        }
    }

    private func removeListRow(_ id: MessageID) {
        listRows.removeAll { $0.id == id }
        if selectedMessageID == id {
            selectedMessageID = nil
            detail = nil
            isLoadingDetail = false
            rawSource = nil
            isShowingRawSource = false
            isFindPresented = false
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
        SettingsWindowController.shared.show(model: self, appearance: appearance, actions: actions)
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
        guard let id = selectedMessageID else { return }
        copySubject(for: id)
    }

    func copySubject(for message: MessageID) {
        guard let subject = listRows.first(where: { $0.id == message })?.subject
            ?? (detail?.id == message ? detail?.envelope.subject : nil) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(subject, forType: .string)
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
