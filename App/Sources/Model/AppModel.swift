import AppKit
import Observation
import SwiftUI
import MailternalInterfaces
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
    /// The list's full selection. `selectedMessageID` remains the reader
    /// anchor so a single-message reader survives ordinary list updates.
    var selectedMessageIDs: Set<MessageID> = []
    var selectedMessageID: MessageID?
    var detail: MessageDetail?
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

    /// Whether the sanitized message contains an app-controlled remote-image
    /// token. The sanitizer computes this once when the detail is ingested.
    var hasRemoteImageReferences: Bool {
        detail?.hasRemoteImageReferences ?? false
    }

    @ObservationIgnored private var pageTask: Task<Void, Never>?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var deepLinkQueue = DeepLinkRouteQueue()
    @ObservationIgnored private var foldersSnapshotReady = false
    @ObservationIgnored private var streamsStarted = false
    @ObservationIgnored private var markedRead: Set<MessageID> = []
    @ObservationIgnored private var qaSelectionSequence: UInt64 = 0
#if DEBUG
    @ObservationIgnored private var qaContextMenuDumped = false
#endif

    var selectedFolder: FolderSummary? {
        folders.first { $0.id == selectedFolderID }
    }

    /// Display name shown by the message-list title when it is flipped to the
    /// owning account.
    var listTitleAccountName: String {
        if let accountTitle = AccountTitlePolicy.title(for: accountConfig) {
            return accountTitle
        }
        if let name = facade.accountDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "Account"
    }

    /// The persisted non-secret values used to populate the account editor.
    var accountConfig: AccountConfig? {
        facade.accountConfig
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
                    #if DEBUG
                    if !self.foldersSnapshotReady { QALaunch.launchPhase("folders-snapshot") }
                    #endif
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
            selectedMessageIDs.removeAll()
            selectedMessageID = nil
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
        detail = nil
        rawSource = nil
        isShowingRawSource = false
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

    /// Updates the list selection and keeps a single anchor for the reader.
    /// Multi-selection deliberately clears detail: there is no ambiguous
    /// "current message" in the reader while several rows are selected.
    func selectMessages(_ ids: Set<MessageID>, anchor: MessageID? = nil) {
        guard !ids.isEmpty else {
            selectMessage(nil)
            return
        }
        selectedMessageIDs = ids
        let retainedAnchor = selectedMessageID.flatMap { ids.contains($0) ? $0 : nil }
        selectedMessageID = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? retainedAnchor ?? ids.first
        guard ids.count == 1, let selectedMessageID else {
            clearReaderSelection()
            return
        }
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
        allowRemoteImages = false
        isLoadingDetail = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await facade.detail(id)
                guard selectedMessageID == id, selectedMessageIDs == Set([id]) else { return }
                detail = loaded
                isLoadingDetail = false
                #if DEBUG
                if ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" {
                    QALaunch.log(
                        "selection-perf event=detail serial=\(qaSelection) t=\(DispatchTime.now().uptimeNanoseconds)"
                    )
                }
                #endif
                markRead(id)
            } catch {
                isLoadingDetail = false
                toasts.post(title: "Couldn’t open message", detail: error.localizedDescription)
            }
        }
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
            removeListRows(ids)
            Task { [weak self] in await self?.facade.archive(orderedIDs) }
        case .trash:
            removeListRows(ids)
            Task { [weak self] in await self?.facade.trash(orderedIDs) }
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

    /// Optimistically removes rows, preserving a still-selected reader anchor
    /// when one exists.
    private func removeListRows(_ ids: Set<MessageID>) {
        let anchorRemoved = selectedMessageID.map(ids.contains) ?? false
        listRows.removeAll { ids.contains($0.id) }
        selectedMessageIDs.subtract(ids)
        if anchorRemoved {
            selectedMessageID = selectedMessageIDs.first
            clearReaderSelection()
        } else if selectedMessageIDs.isEmpty {
            selectedMessageID = nil
            clearReaderSelection()
        }
    }

    func move(ids: Set<MessageID>, to folder: FolderID) {
        guard !ids.isEmpty, folder != selectedFolderID else { return }
        let orderedIDs = ids.sorted { $0.rawValue < $1.rawValue }
        removeListRows(ids)
        Task { [weak self] in
            await self?.facade.move(orderedIDs, to: folder)
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
            #if DEBUG
            if !page.rows.isEmpty { QALaunch.launchPhase("first-rows n=\(page.rows.count)") }
            #endif
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
            current: selectedFolderID
        )
        let titles = policyItems.flatMap { item in
            [item.title] + item.children.map(\.title)
        }
        QALaunch.log("context-menu titles=\(titles.joined(separator: " | "))")
    }
#endif

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
