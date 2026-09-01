import Foundation
import MailternalInterfaces

struct MailAccountError: LocalizedError, Sendable {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct StoredMessage: Sendable {
    var row: MessageRow
    var uid: IMAPUID
    var folder: FolderID
    var detail: MessageDetail
    var raw: String
    var parts: [String: (data: Data, mimeType: String)]
}

@MainActor
final class MockMailFacade: MailFacade {
    private(set) var accountState: AccountState = .none {
        didSet { accountContinuation.yield(accountState) }
    }

    let accountStateStream: AsyncStream<AccountState>
    let foldersStream: AsyncStream<[FolderSummary]>
    let syncStatusStream: AsyncStream<SyncStatus>

    private let accountContinuation: AsyncStream<AccountState>.Continuation
    private let foldersContinuation: AsyncStream<[FolderSummary]>.Continuation
    private let syncContinuation: AsyncStream<SyncStatus>.Continuation

    private var folders: [FolderSummary] = []
    private var messages: [FolderID: [StoredMessage]] = [:]
    private var byID: [MessageID: StoredMessage] = [:]
    private var syncStatus = SyncStatus(mode: .fullHistory, isOnline: true)
    private var seeded = false
    private var nextMessageID: Int64 = 1
    private var pageObservers: [UUID: PageObserver] = [:]
    private var config: AccountConfig?

    private struct PageObserver {
        var folder: FolderID
        var cursor: MessagePageCursor?
        var limit: Int
        var continuation: AsyncStream<MessagePage>.Continuation
    }

    init() {
        let account = AsyncStream.makeStream(of: AccountState.self, bufferingPolicy: .bufferingNewest(8))
        let folders = AsyncStream.makeStream(of: [FolderSummary].self, bufferingPolicy: .bufferingNewest(8))
        let sync = AsyncStream.makeStream(of: SyncStatus.self, bufferingPolicy: .bufferingNewest(8))
        accountStateStream = account.stream
        foldersStream = folders.stream
        syncStatusStream = sync.stream
        accountContinuation = account.continuation
        foldersContinuation = folders.continuation
        syncContinuation = sync.continuation
        account.continuation.yield(.none)
        folders.continuation.yield([])
        sync.continuation.yield(syncStatus)
    }

    func addAccount(_ config: AccountConfig, password: String) async throws {
        accountState = .validating
        try await Task.sleep(for: .milliseconds(280))
        if password == "wrong" {
            let message = "The username or password was rejected."
            accountState = .authFailed(message: message)
            throw MailAccountError(message)
        }
        if config.imap.host == "offline.local" || config.imap.host.hasPrefix("invalid.") {
            let message = "Could not connect to \(config.imap.host)."
            accountState = .connectionFailed(message: message)
            throw MailAccountError(message)
        }
        if password.isEmpty {
            let message = "A password is required."
            accountState = .authFailed(message: message)
            throw MailAccountError(message)
        }
        self.config = config
        if !seeded {
            seedMailbox()
            seeded = true
        }
        accountState = .active
        foldersContinuation.yield(folders)
        syncContinuation.yield(syncStatus)
    }

    func removeAccount() async throws {
        config = nil
        accountState = .none
        foldersContinuation.yield([])
    }

    func page(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) async throws -> MessagePage {
        currentPage(in: folder, after: cursor, limit: limit)
    }

    func observePage(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) -> AsyncStream<MessagePage> {
        let stream = AsyncStream.makeStream(of: MessagePage.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        pageObservers[id] = PageObserver(
            folder: folder,
            cursor: cursor,
            limit: limit,
            continuation: stream.continuation
        )
        stream.continuation.yield(currentPage(in: folder, after: cursor, limit: limit))
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.pageObservers.removeValue(forKey: id)
            }
        }
        return stream.stream
    }

    func folderID(for message: MessageID) -> FolderID? {
        byID[message]?.folder
    }

    func detail(_ id: MessageID) async throws -> MessageDetail {
        guard let stored = byID[id] else {
            throw MailAccountError("Message is no longer available.")
        }
        return stored.detail
    }

    func markRead(_ id: MessageID) async {
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
            foldersContinuation.yield(folders)
        }
        publishObservers(in: stored.folder)
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
            let hay = [
                stored.row.from,
                stored.row.subject,
                stored.row.preview,
                stored.detail.bodyText ?? "",
            ].joined(separator: "\n").lowercased()
            if hay.contains(needle) {
                hits.append(stored.row)
            }
        }
        return hits
    }

    func refresh() async {
        guard accountState == .active else { return }
        foldersContinuation.yield(folders)
        syncContinuation.yield(syncStatus)
        for observer in pageObservers.values {
            observer.continuation.yield(
                currentPage(in: observer.folder, after: observer.cursor, limit: observer.limit)
            )
        }
    }

    private func currentPage(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) -> MessagePage {
        let list = messages[folder] ?? []
        let sliced: ArraySlice<StoredMessage>
        if let cursor {
            let start = list.firstIndex { stored in
                if stored.row.date != cursor.internalDate {
                    return stored.row.date < cursor.internalDate
                }
                return stored.uid < cursor.uid
            } ?? list.endIndex
            sliced = list[start...].prefix(limit)
        } else {
            sliced = list.prefix(limit)
        }
        let rows = sliced.map(\.row)
        let next: MessagePageCursor?
        if sliced.count == limit, let last = sliced.last {
            next = MessagePageCursor(internalDate: last.row.date, uid: last.uid)
        } else {
            next = nil
        }
        return MessagePage(rows: rows, next: next)
    }

    private func publishObservers(in folder: FolderID) {
        for observer in pageObservers.values where observer.folder == folder {
            observer.continuation.yield(
                currentPage(in: observer.folder, after: observer.cursor, limit: observer.limit)
            )
        }
    }

    private func seedMailbox() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-30 * 24 * 3600)

        let specs: [(FolderID, String, String, FolderRole, BackfillState, Int, Double)] = [
            (FolderID(rawValue: 1), "Inbox", "INBOX", .inbox, .syncing(progress: 0.62), 1200, 0.34),
            (FolderID(rawValue: 2), "Archive", "Archive", .archive, .complete, 250, 0.04),
            (FolderID(rawValue: 3), "Sent", "Sent", .sent, .complete, 180, 0.0),
            (FolderID(rawValue: 4), "Drafts", "Drafts", .drafts, .idle, 12, 0.0),
            (FolderID(rawValue: 5), "Junk", "Junk", .junk, .complete, 80, 0.55),
            (FolderID(rawValue: 6), "Trash", "Trash", .trash, .complete, 40, 0.1),
            (FolderID(rawValue: 7), "Projects", "Projects", .none, .halted(syncedThrough: now.addingTimeInterval(-45 * 24 * 3600)), 150, 0.18),
            (FolderID(rawValue: 8), "旅行", "旅行", .none, .complete, 40, 0.22),
            (FolderID(rawValue: 9), "Newsletters", "Newsletters", .none, .syncing(progress: nil), 48, 0.7),
        ]

        var rng = SplitMix64(seed: 0x4D41_494C_5445_524E)
        var allFolders: [FolderSummary] = []
        for spec in specs {
            var unread = 0
            var list: [StoredMessage] = []
            list.reserveCapacity(spec.5)
            for index in 0..<spec.5 {
                let stored = makeMessage(
                    folder: spec.0,
                    folderName: spec.1,
                    index: index,
                    count: spec.5,
                    unreadRate: spec.6,
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
            messages[spec.0] = list
            allFolders.append(
                FolderSummary(
                    id: spec.0,
                    name: spec.1,
                    path: spec.2,
                    role: spec.3,
                    unreadCount: unread,
                    totalCount: spec.5,
                    backfill: spec.4
                )
            )
        }
        folders = allFolders
        syncStatus = SyncStatus(mode: .windowed(since: windowStart), isOnline: true)
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
            subject: envelope.subject,
            preview: preview,
            date: date,
            isRead: !unread,
            hasAttachments: hasAttachment
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
        return StoredMessage(row: row, uid: uid, folder: folder, detail: detail, raw: raw, parts: parts)
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
