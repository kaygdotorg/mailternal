import Foundation
import MailternalInterfaces

struct MailAccountError: LocalizedError, Sendable {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct StoredMessage: Sendable {
    var row: MessageRow
    var uid: IMAPUID
    var uidValidity: UInt32
    var folder: FolderID
    var detail: MessageDetail
    var raw: String
    var parts: [String: (data: Data, mimeType: String)]
}

@MainActor
final class MockMailFacade: MailFacade {
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

    private var folders: [FolderSummary] = []
    private var messages: [FolderID: [StoredMessage]] = [:]
    private var byID: [MessageID: StoredMessage] = [:]
    private var syncStatus = SyncStatus(mode: .fullHistory, isOnline: true)
    private var activityCycleTask: Task<Void, Never>?
    private var nextMessageID: Int64 = 1
    private var nextFolderID: Int64 = 1
    private var passwords: [AccountID: String] = [:]
    var accountConfig: AccountConfig? { accounts.first }
    var accountDisplayName: String? {
        guard let config = accounts.first else { return nil }
        let displayName = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? config.emailAddress : displayName
    }
    var activeAccountID: AccountID? { accounts.first?.id }
    private(set) var validationCallCount = 0
    private var pageObservers: [UUID: PageObserver] = [:]
    private struct PageObserver {
        var folder: FolderID
        var cursor: MessagePageCursor?
        var limit: Int
        var sort: MailListSort
        var continuation: AsyncStream<MessagePage>.Continuation
    }

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

    init() {
        let accounts = AsyncStream.makeStream(of: [AccountConfig].self, bufferingPolicy: .bufferingNewest(8))
        let states = AsyncStream.makeStream(
            of: [AccountID: AccountState].self,
            bufferingPolicy: .bufferingNewest(8)
        )
        let account = AsyncStream.makeStream(of: AccountState.self, bufferingPolicy: .bufferingNewest(8))
        let folders = AsyncStream.makeStream(of: [FolderSummary].self, bufferingPolicy: .bufferingNewest(8))
        let sync = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(8))
        accountsStream = accounts.stream
        accountStatesStream = states.stream
        accountStateStream = account.stream
        foldersStream = folders.stream
        syncStatusStream = sync.stream
        accountsContinuation = accounts.continuation
        accountStatesContinuation = states.continuation
        accountContinuation = account.continuation
        foldersContinuation = folders.continuation
        syncContinuation = sync.continuation
        accounts.continuation.yield([])
        states.continuation.yield([:])
        account.continuation.yield(.none)
        folders.continuation.yield([])
        sync.continuation.yield(syncStatus)
    }

    func addAccount(_ config: AccountConfig, password: String) async throws {
        if config.isEnabled {
            setState(.validating, for: config.id)
            try await validate(config, password: password)
        }
        let mockConfig = AccountConfig(
            id: config.id,
            accountLinkID: config.accountLinkID,
            displayName: config.displayName,
            emailAddress: config.emailAddress,
            username: config.username,
            imap: config.imap,
            isEnabled: config.isEnabled
        )
        if let index = accounts.firstIndex(where: { $0.id == mockConfig.id }) {
            accounts[index] = mockConfig
        } else {
            accounts.append(mockConfig)
        }
        passwords[mockConfig.id] = password
        seedMailbox(for: mockConfig.id)
        setState(mockConfig.isEnabled ? .active : .none, for: mockConfig.id)
        publishFolders()
        syncContinuation.yield(syncStatus)
    }

    func updateAccount(_ config: AccountConfig, password: String?) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == config.id }) else {
            throw MailAccountError("That account is no longer available.")
        }
        let existing = accounts[index]
        var updated = config
        updated.accountLinkID = existing.accountLinkID
        updated.isEnabled = existing.isEnabled
        let requiresValidation =
            existing.emailAddress != updated.emailAddress
            || existing.username != updated.username
            || existing.imap != updated.imap
            || password != nil
        if requiresValidation {
            setState(.validating, for: existing.id)
            try await validate(updated, password: password ?? passwords[existing.id, default: ""])
        }
        accounts[index] = updated
        if let password { passwords[existing.id] = password }
        setState(updated.isEnabled ? .active : .none, for: existing.id)
        publishFolders()
    }

    func setAccountEnabled(_ id: AccountID, _ enabled: Bool) async throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw MailAccountError("That account is no longer available.")
        }
        guard accounts[index].isEnabled != enabled else { return }
        accounts[index].isEnabled = enabled
        setState(enabled ? .active : .none, for: id)
        publishFolders()
    }

    func resetValidationCallCount() {
        validationCallCount = 0
    }

    private func validate(_ config: AccountConfig, password: String) async throws {
        validationCallCount += 1
        try await Task.sleep(for: .milliseconds(280))
        if password == "wrong" {
            let message = "The username or password was rejected."
            setState(.authFailed(message: message), for: config.id)
            throw MailAccountError(message)
        }
        if config.imap.host == "offline.local" || config.imap.host.hasPrefix("invalid.") {
            let message = "Could not connect to \(config.imap.host)."
            setState(.connectionFailed(message: message), for: config.id)
            throw MailAccountError(message)
        }
        if password.isEmpty {
            let message = "A password is required."
            setState(.authFailed(message: message), for: config.id)
            throw MailAccountError(message)
        }
    }
    func removeAccount(_ id: AccountID) async throws {
        activityCycleTask?.cancel()
        let removedFolders = folders.filter { $0.accountID == id }.map(\.id)
        folders.removeAll { $0.accountID == id }
        for folder in removedFolders {
            messages[folder] = nil
        }
        byID = byID.filter { !removedFolders.contains($0.value.folder) }
        passwords[id] = nil
        accounts.removeAll { $0.id == id }
        accountStates[id] = nil
        publishFolders()
        publishAggregateState()
    }


    func makeDeepLink(for folder: FolderID) async throws -> MailternalDeepLink? {
        guard let summary = folders.first(where: { $0.id == folder }),
              let account = accounts.first(where: { $0.id == summary.accountID }),
              accountState(for: account.id) == .active else { return nil }
        return .folder(
            accountLinkID: account.accountLinkID,
            folderLocator: FolderLocator(kind: .path, value: summary.path)
        )
    }

    func makeDeepLink(for message: MessageID) async throws -> MailternalDeepLink? {
        guard let stored = byID[message],
              let summary = folders.first(where: { $0.id == stored.folder }),
              let account = accounts.first(where: { $0.id == summary.accountID }),
              accountState(for: account.id) == .active else { return nil }
        return .message(
            accountLinkID: account.accountLinkID,
            folderLocator: FolderLocator(kind: .path, value: summary.path),
            uidValidity: stored.uidValidity,
            uid: stored.uid
        )
    }

    func resolve(_ link: MailternalDeepLink) async throws -> MailternalDeepLinkResolution? {
        guard let account = accounts.first(where: { $0.accountLinkID == link.accountLinkID }),
              accountState(for: account.id) == .active else { return nil }
        guard let folder = folders.first(where: {
            $0.accountID == account.id
                && $0.path == link.folderLocator.value
                && link.folderLocator.kind == .path
        }) else { return nil }
        switch link {
        case .folder:
            return .folder(folder.id)
        case .message(_, _, let uidValidity, let uid):
            guard let stored = messages[folder.id]?.first(where: {
                $0.uidValidity == uidValidity && $0.uid == uid
            }) else { return nil }
            return .message(folderID: folder.id, messageID: stored.row.id, row: stored.row)
        }
    }

    func folderID(for message: MessageID) -> FolderID? {
        byID[message]?.folder
    }

    func page(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) async throws -> MessagePage {
        try currentPage(in: folder, after: cursor, limit: limit, sort: sort)
    }

    func messageIDs(in folder: FolderID, sort: MailListSort) async throws -> [MessageID] {
        orderedMessages(in: folder, sort: sort).map(\.row.id)
    }

    func observePage(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) -> AsyncStream<MessagePage> {
        let stream = AsyncStream.makeStream(of: MessagePage.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        pageObservers[id] = PageObserver(
            folder: folder,
            cursor: cursor,
            limit: limit,
            sort: sort,
            continuation: stream.continuation
        )
        do {
            stream.continuation.yield(
                try currentPage(in: folder, after: cursor, limit: limit, sort: sort)
            )
        } catch {
            stream.continuation.finish()
        }
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.pageObservers.removeValue(forKey: id)
            }
        }
        return stream.stream
    }
    func setKeepLocally(_ keep: Bool, for folder: FolderID) async throws {
        guard let index = folders.firstIndex(where: { $0.id == folder }) else {
            throw MailAccountError("Folder is no longer available.")
        }
        folders[index].keepLocally = keep
        publishFolders()
    }
    func renameFolder(_ id: FolderID, to name: String) async throws {
        let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            throw MailAccountError("A folder name is required.")
        }
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            throw MailAccountError("Folder is no longer available.")
        }
        guard folders[index].name != targetName else { return }

        let currentPath = folders[index].path
        let separator = folders[index].separator ?? "/"
        let targetPath: String
        if let lastSeparator = currentPath.lastIndex(of: separator) {
            let prefixEnd = currentPath.index(after: lastSeparator)
            targetPath = String(currentPath[..<prefixEnd]) + targetName
        } else {
            targetPath = targetName
        }
        folders[index].name = targetName
        folders[index].path = targetPath
        if var folderMessages = messages[id] {
            for index in folderMessages.indices {
                let messageID = folderMessages[index].row.id
                guard var message = byID[messageID] else { continue }
                message.row.folderName = targetName
                byID[messageID] = message
                folderMessages[index] = message
            }
            messages[id] = folderMessages
        }
        publishFolders()
        publishObservers(in: id)
    }

    private func setState(_ state: AccountState, for account: AccountID) {
        accountStates[account] = state
        accountState = aggregateState
    }

    private func publishAggregateState() {
        accountState = aggregateState
    }
    private func publishFolders() {
        let enabledAccounts = Set(accounts.lazy.filter { $0.isEnabled }.map(\.id))
        foldersContinuation.yield(folders.filter { enabledAccounts.contains($0.accountID) })
    }



    func detail(_ id: MessageID) async throws -> MessageDetail {
        guard let stored = byID[id] else {
            throw MailAccountError("Message is no longer available.")
        }
        return stored.detail
    }

    func details(_ ids: [MessageID]) async throws -> [MessageDetail] {
        var details: [MessageDetail] = []
        details.reserveCapacity(ids.count)
        var seen = Set<MessageID>()
        for id in ids where seen.insert(id).inserted {
            guard let stored = byID[id] else { continue }
            details.append(stored.detail)
        }
        return details
    }

    func markRead(_ ids: [MessageID]) async {
        for id in Set(ids) {
            markReadOne(id)
        }
    }

    private func markReadOne(_ id: MessageID) {
        guard var stored = byID[id], !stored.row.isRead else { return }
        stored.row.isRead = true
        byID[id] = stored
        if var list = messages[stored.folder],
           let index = list.firstIndex(where: { $0.row.id == id }) {
            list[index] = stored
            messages[stored.folder] = list
        }
        if let folderIndex = folders.firstIndex(where: { $0.id == stored.folder }) {
            folders[folderIndex].unreadCount = max(0, folders[folderIndex].unreadCount - 1)
            publishFolders()
        }
        publishObservers(in: stored.folder)
    }

    func markUnread(_ ids: [MessageID]) async {
        for id in Set(ids) {
            markUnreadOne(id)
        }
    }

    private func markUnreadOne(_ id: MessageID) {
        guard var stored = byID[id], stored.row.isRead else { return }
        stored.row.isRead = false
        byID[id] = stored
        if var list = messages[stored.folder],
           let index = list.firstIndex(where: { $0.row.id == id }) {
            list[index] = stored
            messages[stored.folder] = list
        }
        if let folderIndex = folders.firstIndex(where: { $0.id == stored.folder }) {
            folders[folderIndex].unreadCount += 1
            publishFolders()
        }
        publishObservers(in: stored.folder)
    }

    func setFlagged(_ ids: [MessageID], _ flagged: Bool) async {
        for id in Set(ids) {
            guard var stored = byID[id], stored.row.isFlagged != flagged else { continue }
            stored.row.isFlagged = flagged
            byID[id] = stored
            if var list = messages[stored.folder],
               let index = list.firstIndex(where: { $0.row.id == id }) {
                list[index] = stored
                messages[stored.folder] = list
            }
            publishObservers(in: stored.folder)
        }
    }

    func trash(_ ids: [MessageID]) async {
        await moveToRole(.trash, ids: ids)
    }

    func archive(_ ids: [MessageID]) async {
        await moveToRole(.archive, ids: ids)
    }

    private func moveToRole(_ role: FolderRole, ids: [MessageID]) async {
        for account in accounts {
            guard let destination = folders.first(where: {
                $0.accountID == account.id && $0.role == role
            })?.id else { continue }
            let accountIDs = ids.filter { id in
                guard let stored = byID[id],
                      let folder = folders.first(where: { $0.id == stored.folder })
                else { return false }
                return folder.accountID == account.id
            }
            for id in accountIDs {
                moveOne(id, to: destination)
            }
        }
    }

    func move(_ ids: [MessageID], to destination: FolderID) async throws -> MoveOutcome {
        guard let destinationSummary = folders.first(where: { $0.id == destination }) else {
            throw MailAccountError("That destination folder is no longer available.")
        }
        var acceptedIDs = Set<MessageID>()
        var skippedCrossAccount = 0
        for id in ids {
            guard let stored = byID[id],
                  let sourceSummary = folders.first(where: { $0.id == stored.folder })
            else {
                throw MailAccountError("That message is no longer available.")
            }
            guard sourceSummary.accountID == destinationSummary.accountID else {
                skippedCrossAccount += 1
                continue
            }
            if moveOne(id, to: destination) {
                acceptedIDs.insert(id)
            }
        }
        return MoveOutcome(
            movedCount: acceptedIDs.count,
            skippedCrossAccountCount: skippedCrossAccount,
            acceptedIDs: acceptedIDs
        )
    }

    @discardableResult
    private func moveOne(_ id: MessageID, to destination: FolderID) -> Bool {
        guard let stored = byID[id],
              let sourceSummary = folders.first(where: { $0.id == stored.folder }),
              let destinationSummary = folders.first(where: { $0.id == destination }),
              sourceSummary.accountID == destinationSummary.accountID
        else { return false }
        let source = stored.folder
        guard var sourceList = messages[source],
              let sourceIndex = sourceList.firstIndex(where: { $0.row.id == id })
        else { return false }
        sourceList.remove(at: sourceIndex)
        messages[source] = sourceList

        if source != destination {
            var moved = stored
            moved.folder = destination
            moved.row.folderName = folders.first(where: { $0.id == destination })?.name ?? moved.row.folderName
            byID[id] = moved
            var destinationList = messages[destination] ?? []
            destinationList.append(moved)
            destinationList.sort {
                if $0.row.date != $1.row.date { return $0.row.date > $1.row.date }
                return $0.uid > $1.uid
            }
            messages[destination] = destinationList
        } else {
            messages[source] = sourceList
        }

        if let folderIndex = folders.firstIndex(where: { $0.id == source }), source != destination {
            folders[folderIndex].totalCount = max(0, folders[folderIndex].totalCount - 1)
            if !stored.row.isRead {
                folders[folderIndex].unreadCount = max(0, folders[folderIndex].unreadCount - 1)
            }
        }
        if let folderIndex = folders.firstIndex(where: { $0.id == destination }), source != destination {
            folders[folderIndex].totalCount += 1
            if !stored.row.isRead {
                folders[folderIndex].unreadCount += 1
            }
        }
        publishFolders()
        publishObservers(in: source)
        if source != destination {
            publishObservers(in: destination)
        }
        return true
    }

    func rawSource(_ id: MessageID) async throws -> String {
        guard let stored = byID[id] else {
            throw MailAccountError("Message is no longer available.")
        }
        return stored.raw
    }

    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL {
        guard let stored = byID[message] else {
            throw MailAccountError("Message is no longer available.")
        }
        let key = part.hasPrefix("cid:") ? String(part.dropFirst(4)) : part
        let payload = stored.parts[key] ?? stored.parts[part] ?? (Self.pixelPNG, "image/png")
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mailternal-mock-\(message.rawValue)-\(key.hashValue).png")
        try payload.data.write(to: url, options: .atomic)
        return url
    }

    func search(_ query: String, limit: Int) async throws -> [MessageRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var hits: [MessageRow] = []
        hits.reserveCapacity(min(limit, 64))
        let all = messages.values.flatMap { $0 }.sorted { lhs, rhs in
            if lhs.row.date != rhs.row.date { return lhs.row.date > rhs.row.date }
            return lhs.uid > rhs.uid
        }
        for stored in all {
            if hits.count >= limit { break }
            guard let summary = folders.first(where: { $0.id == stored.folder }),
                  let account = accounts.first(where: { $0.id == summary.accountID }),
                  account.isEnabled else {
                continue
            }
            let hay = [
                stored.row.from,
                stored.row.subject,
                stored.row.preview,
                stored.detail.bodyText ?? "",
            ].joined(separator: "\n").lowercased()
            if hay.contains(needle) {
                var row = stored.row
                let title = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                row.accountName = title.isEmpty ? account.emailAddress : title
                row.folderID = summary.id
                hits.append(row)
            }
        }
        return hits
    }

    func refresh() async {
        guard accountState == .active else { return }
        publishFolders()
        syncContinuation.yield(syncStatus)
        for observer in pageObservers.values {
            if let page = try? currentPage(
                in: observer.folder,
                after: observer.cursor,
                limit: observer.limit,
                sort: observer.sort
            ) {
                observer.continuation.yield(page)
            }
        }
    }

    private func orderedMessages(in folder: FolderID, sort: MailListSort) -> [StoredMessage] {
        (messages[folder] ?? []).sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sort.field {
            case .date:
                comparison = lhs.row.date.compare(rhs.row.date)
            case .sender:
                comparison = lhs.row.from.compare(rhs.row.from)
            case .subject:
                comparison = lhs.row.subject.compare(rhs.row.subject)
            case .read:
                comparison = (lhs.row.isRead ? 1 : 0) == (rhs.row.isRead ? 1 : 0)
                    ? .orderedSame
                    : (lhs.row.isRead ? .orderedDescending : .orderedAscending)
            case .flagged:
                comparison = (lhs.row.isFlagged ? 1 : 0) == (rhs.row.isFlagged ? 1 : 0)
                    ? .orderedSame
                    : (lhs.row.isFlagged ? .orderedDescending : .orderedAscending)
            case .attachments:
                comparison = (lhs.row.hasAttachments ? 1 : 0) == (rhs.row.hasAttachments ? 1 : 0)
                    ? .orderedSame
                    : (lhs.row.hasAttachments ? .orderedDescending : .orderedAscending)
            }
            if comparison == .orderedSame {
                return sort.direction == .ascending ? lhs.uid < rhs.uid : lhs.uid > rhs.uid
            }
            return sort.direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private func validateCursor(
        _ cursor: MessagePageCursor?,
        sort: MailListSort
    ) throws {
        guard let cursor else { return }
        guard cursor.sort == sort else {
            throw MailAccountError("That page cursor uses another sort order.")
        }
        switch (sort.field, cursor.value) {
        case (.date, .date(_)), (.sender, .sender(_)), (.subject, .subject(_)),
             (.read, .read(_)), (.flagged, .flagged(_)), (.attachments, .attachments(_)):
            return
        default:
            throw MailAccountError("That page cursor has an invalid sort value.")
        }
    }

    private func isAfter(
        _ stored: StoredMessage,
        cursor: MessagePageCursor,
        sort: MailListSort
    ) throws -> Bool {
        guard cursor.sort == sort else { throw MailAccountError("That page cursor uses another sort order.") }
        let comparison: ComparisonResult
        switch (sort.field, cursor.value) {
        case (.date, .date(let date)):
            comparison = stored.row.date.compare(date)
        case (.sender, .sender(let sender)):
            comparison = stored.row.from.compare(sender)
        case (.subject, .subject(let subject)):
            comparison = stored.row.subject.compare(subject)
        case (.read, .read(let read)):
            comparison = (stored.row.isRead ? 1 : 0) == (read ? 1 : 0)
                ? .orderedSame
                : (stored.row.isRead ? .orderedDescending : .orderedAscending)
        case (.flagged, .flagged(let flagged)):
            comparison = (stored.row.isFlagged ? 1 : 0) == (flagged ? 1 : 0)
                ? .orderedSame
                : (stored.row.isFlagged ? .orderedDescending : .orderedAscending)
        case (.attachments, .attachments(let attachments)):
            comparison = (stored.row.hasAttachments ? 1 : 0) == (attachments ? 1 : 0)
                ? .orderedSame
                : (stored.row.hasAttachments ? .orderedDescending : .orderedAscending)
        default:
            throw MailAccountError("That page cursor has an invalid sort value.")
        }
        if comparison == .orderedSame {
            return sort.direction == .ascending ? stored.uid > cursor.uid : stored.uid < cursor.uid
        }
        return sort.direction == .ascending
            ? comparison == .orderedDescending
            : comparison == .orderedAscending
    }

    private func currentPage(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) throws -> MessagePage {
        try validateCursor(cursor, sort: sort)
        let cap = max(limit, 0)
        guard cap > 0 else { return MessagePage(rows: [], next: nil) }
        let list = orderedMessages(in: folder, sort: sort)
        let start: Int
        if let cursor {
            start = try list.firstIndex { stored in
                try isAfter(stored, cursor: cursor, sort: sort)
            } ?? list.endIndex
        } else {
            start = list.startIndex
        }
        let end = start + min(cap, list.endIndex - start)
        let slice = list[start..<end]
        let rows = slice.map(\.row)
        let next: MessagePageCursor?
        if end < list.endIndex, let last = slice.last {
            let value: MessagePageCursorValue
            switch sort.field {
            case .date: value = .date(last.row.date)
            case .sender: value = .sender(last.row.from)
            case .subject: value = .subject(last.row.subject)
            case .read: value = .read(last.row.isRead)
            case .flagged: value = .flagged(last.row.isFlagged)
            case .attachments: value = .attachments(last.row.hasAttachments)
            }
            next = MessagePageCursor(sort: sort, value: value, uid: last.uid)
        } else {
            next = nil
        }
        return MessagePage(rows: rows, next: next)
    }

    private func publishObservers(in folder: FolderID) {
        for observer in pageObservers.values where observer.folder == folder {
            if let page = try? currentPage(
                in: observer.folder,
                after: observer.cursor,
                limit: observer.limit,
                sort: observer.sort
            ) {
                observer.continuation.yield(page)
            }
        }
    }

    private func seedMailbox(for accountID: AccountID) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-30 * 24 * 3600)

        let specs: [(id: FolderID, name: String, path: String, separator: Character?, role: FolderRole, backfill: BackfillState, count: Int, unreadRate: Double)] = [
            (id: FolderID(rawValue: 1), name: "Inbox", path: "INBOX", separator: nil, role: .inbox, backfill: .syncing(progress: 0.62), count: 1200, unreadRate: 0.34),
            (id: FolderID(rawValue: 2), name: "Archive", path: "Archive", separator: nil, role: .archive, backfill: .complete, count: 250, unreadRate: 0.04),
            (id: FolderID(rawValue: 3), name: "Sent", path: "Sent", separator: nil, role: .sent, backfill: .complete, count: 180, unreadRate: 0.0),
            (id: FolderID(rawValue: 4), name: "Drafts", path: "Drafts", separator: nil, role: .drafts, backfill: .idle, count: 12, unreadRate: 0.0),
            (id: FolderID(rawValue: 5), name: "Junk", path: "Junk", separator: nil, role: .junk, backfill: .complete, count: 80, unreadRate: 0.55),
            (id: FolderID(rawValue: 6), name: "Trash", path: "Trash", separator: nil, role: .trash, backfill: .complete, count: 40, unreadRate: 0.1),
            (id: FolderID(rawValue: 7), name: "Projects", path: "Projects", separator: nil, role: .none, backfill: .halted(syncedThrough: now.addingTimeInterval(-45 * 24 * 3600)), count: 150, unreadRate: 0.18),
            (id: FolderID(rawValue: 17), name: "Horrors", path: "Horrors", separator: nil, role: .none, backfill: .complete, count: 0, unreadRate: 0),
            (id: FolderID(rawValue: 8), name: "旅行", path: "旅行", separator: nil, role: .none, backfill: .complete, count: 40, unreadRate: 0.22),
            (id: FolderID(rawValue: 9), name: "Newsletters", path: "Newsletters", separator: nil, role: .none, backfill: .syncing(progress: nil), count: 48, unreadRate: 0.7),
            // These folders deliberately carry their server-reported separators. The slash and
            // dot trees exercise independent hierarchy formats without changing the legacy
            // special-folder/message fixtures above.
            (id: FolderID(rawValue: 10), name: "Engineering", path: "Engineering", separator: "/", role: .none, backfill: .syncing(progress: 0.62), count: 0, unreadRate: 0),
            (id: FolderID(rawValue: 11), name: "Reports", path: "Engineering/Reports", separator: "/", role: .none, backfill: .complete, count: 0, unreadRate: 0),
            (id: FolderID(rawValue: 12), name: "Weekly", path: "Engineering/Reports/Weekly", separator: "/", role: .none, backfill: .halted(syncedThrough: now.addingTimeInterval(-7 * 24 * 3600)), count: 0, unreadRate: 0),
            (id: FolderID(rawValue: 13), name: "Research", path: "Research", separator: ".", role: .none, backfill: .complete, count: 0, unreadRate: 0),
            (id: FolderID(rawValue: 14), name: "Notes", path: "Research.Notes", separator: ".", role: .none, backfill: .complete, count: 0, unreadRate: 0),
            // There is no separator metadata here: "AdjacentLeaf" must remain a root,
            // rather than being guessed as a child of "Adjacent".
            (id: FolderID(rawValue: 15), name: "Adjacent", path: "Adjacent", separator: nil, role: .none, backfill: .complete, count: 0, unreadRate: 0),
            (id: FolderID(rawValue: 16), name: "Leaf", path: "AdjacentLeaf", separator: nil, role: .none, backfill: .complete, count: 0, unreadRate: 0),
        ]

        let base = nextFolderID
        nextFolderID += Int64(specs.count)
        var rng = SplitMix64(seed: 0x4D41_494C_5445_524E &+ UInt64(base))
        var allFolders: [FolderSummary] = []
        for spec in specs {
            let folderID = FolderID(rawValue: base + spec.id.rawValue - 1)
            var unread = 0
            var list: [StoredMessage] = []
            list.reserveCapacity(spec.count)
            for index in 0..<spec.count {
                let stored = makeMessage(
                    folder: folderID,
                    folderName: spec.name,
                    index: index,
                    count: spec.count,
                    unreadRate: spec.unreadRate,
                    now: now,
                    rng: &rng
                )
                if !stored.row.isRead { unread += 1 }
                list.append(stored)
                byID[stored.row.id] = stored
            }
            list.sort { lhs, rhs in
                if lhs.row.date != rhs.row.date { return lhs.row.date > rhs.row.date }
                return lhs.uid > rhs.uid
            }
            messages[folderID] = list
            allFolders.append(
                FolderSummary(
                    id: folderID,
                    name: spec.name,
                    path: spec.path,
                    separator: spec.separator,
                    role: spec.role,
                    unreadCount: unread,
                    totalCount: spec.count,
                    keepLocally: spec.role != .none,
                    backfill: spec.backfill,
                    accountID: accountID
                )
            )
        }
        folders.append(contentsOf: allFolders)
        syncStatus = SyncStatus(mode: .windowed(since: windowStart), isOnline: true)
        startActivityCycle()
    }
    private func startActivityCycle() {
        activityCycleTask?.cancel()
        activityCycleTask = Task { [weak self] in
            let cycle: [FolderActivity] = [
                .downloading, .indexing, .idle, .halted, .quarantinedStall,
            ]
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled, let self else { return }
                let activity = cycle[index % cycle.count]
                index += 1
                guard let folder = self.folders.first(where: {
                    if case .syncing = $0.backfill { return true }
                    return false
                }) else { continue }
                guard let folderIndex = self.folders.firstIndex(where: { $0.id == folder.id }) else {
                    continue
                }
                self.folders[folderIndex].activity = activity
                self.publishFolders()
            }
        }
    }


    private func makeMessage(
        folder: FolderID,
        folderName: String,
        index: Int,
        count: Int,
        unreadRate: Double,
        now: Date,
        rng: inout SplitMix64
    ) -> StoredMessage {
        let id = MessageID(rawValue: nextMessageID)
        nextMessageID += 1
        let uid = IMAPUID(rawValue: UInt32(truncatingIfNeeded: nextMessageID &+ Int64(folder.rawValue) &* 10_000))
        let age = Double(index) * (folder.rawValue == 7 ? 6.5 : 2.4) * 3600
            + Double(rng.next() % 3_600)
        let date = now.addingTimeInterval(-age)
        let sender = Self.senders[Int(rng.next() % UInt64(Self.senders.count))]
        let subject = Self.subject(index: index, bucket: Int(rng.next() % 9), folder: folderName)
        let unread = (rng.nextDouble() < unreadRate) && folderName != "Sent" && folderName != "Drafts"
        let hasAttachment = rng.nextDouble() < 0.18 || index % 17 == 0
        let isHTML = index % 11 == 0
        let quarantined = index % 97 == 0
        let preview: String
        let body: String
        if quarantined {
            preview = "This message could not be parsed."
            body = ""
        } else {
            body = Self.body(index: index, sender: sender.display, subject: subject)
            preview = String(body.prefix(140)).replacingOccurrences(of: "\n", with: " ")
        }

        let fromAddress = MailAddress(displayName: sender.display, address: sender.email)
        let envelope = Envelope(
            subject: subject.isEmpty ? "(no subject)" : subject,
            from: [fromAddress],
            to: [MailAddress(displayName: "Kay", address: "kay@mailternal.example")],
            cc: index % 23 == 0 ? [MailAddress(displayName: "Cc Desk", address: "cc@example.com")] : [],
            replyTo: [fromAddress],
            internalDate: date,
            headerDate: date,
            rfcMessageID: "<\(id.rawValue)@mailternal.mock>",
            inReplyTo: nil,
            references: []
        )
        var attachments: [AttachmentInfo] = []
        var parts: [String: (data: Data, mimeType: String)] = [:]
        if hasAttachment {
            attachments.append(
                AttachmentInfo(
                    id: "2",
                    filename: index % 2 == 0 ? "notes.pdf" : "写真.png",
                    mimeType: index % 2 == 0 ? "application/pdf" : "image/png",
                    sizeEstimate: 24_000 + Int(rng.next() % 80_000),
                    contentID: isHTML ? "photo@mail" : nil
                )
            )
            parts["2"] = (Self.pixelPNG, "image/png")
            parts["photo@mail"] = (Self.pixelPNG, "image/png")
        }

        let html: String?
        if quarantined {
            html = nil
        } else if isHTML {
            html = """
            <article>
            <p>Hello from <strong>Mailternal</strong>.</p>
            <p>\(Self.escape(String(body.prefix(280))))</p>
            \(hasAttachment ? #"<p><img src="cid:photo@mail" alt="Attached"></p>"# : "")
            </article>
            """
        } else {
            html = nil
        }

        let row = MessageRow(
            id: id,
            from: sender.display,
            senderAddress: sender.email,
            subject: envelope.subject,
            preview: preview,
            date: date,
            isRead: !unread,
            hasAttachments: hasAttachment,
            isFlagged: false,
            folderName: folderName
        )
        let detail = MessageDetail(
            id: id,
            envelope: envelope,
            bodyText: quarantined ? nil : body,
            sanitizedHTML: html,
            attachments: attachments,
            isQuarantined: quarantined
        )
        let raw = """
        From: \(sender.display) <\(sender.email)>
        Date: \(date.formatted(.iso8601))
        Subject: \(envelope.subject)
        Message-ID: \(envelope.rfcMessageID ?? "")

        \(quarantined ? "<unparseable payload>" : body)
        """
        return StoredMessage(
            row: row,
            uid: uid,
            uidValidity: 1,
            folder: folder,
            detail: detail,
            raw: raw,
            parts: parts
        )
    }

    private static func subject(index: Int, bucket: Int, folder: String) -> String {
        switch bucket {
        case 0: "Lunch?"
        case 1: "Re: \(folder) update \(index)"
        case 2: String(repeating: "Very long subject about scheduling the quarterly review and the attached agenda — ", count: 3)
        case 3: "プロジェクトの件 \(index)"
        case 4: "مرحبا — follow-up"
        case 5: index % 40 == 0 ? "" : "Invoice #\(1000 + index)"
        case 6: "🚀 Launch checklist"
        case 7: " vis-à-vis résumé"
        default: "Notes from \(folder)"
        }
    }

    private static func body(index: Int, sender: String, subject: String) -> String {
        """
        Hi Kay,

        \(sender) here — following up on “\(subject.isEmpty ? "that thread" : subject)”.

        The mock mailbox is seeded so the list, search, and viewer can be exercised at a couple of thousand rows. Paragraph two exists so the reading measure and the 10-point paragraph gap are visible.

        Best,
        \(sender)
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let senders: [(display: String, email: String)] = [
        ("Alex Rivera", "alex@example.com"),
        ("佐藤 美咲", "misaki@example.jp"),
        ("Zoe Müller", "zoe@example.de"),
        ("Анна Петрова", "anna@example.ru"),
        ("محمد الأحمد", "mohammad@example.sa"),
        ("김민준", "minjun@example.kr"),
        ("李娜", "lina@example.cn"),
        ("Camille Dupont", "camille@example.fr"),
        ("José García", "jose@example.es"),
        ("Þóra Einarsdóttir", "thora@example.is"),
    ]

    private static let mockAccountLinkID = AccountLinkID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    )!
    fileprivate static let pixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
