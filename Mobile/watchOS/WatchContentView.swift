#if os(watchOS)
import MailternalCompanion
import SwiftUI

/// Root navigation for the paired Watch app. Mail is intentionally presented
/// as cached, recent content; this view never opens a socket or owns credentials.
public struct WatchContentView: View {
    @ObservedObject private var companion: WatchCompanionSession

    public init(companion: WatchCompanionSession) {
        self.companion = companion
    }

    public var body: some View {
        NavigationStack {
            List {
                WatchConnectionBanner(companion: companion)
                Section("Compose") {
                    if companion.state.accounts.contains(where: { $0.canSend }) {
                        NavigationLink {
                            WatchComposeView(companion: companion, mode: .newMessage)
                        } label: {
                            Label("New Message", systemImage: "square.and.pencil")
                        }
                    } else {
                        Text("Set up an enabled outgoing account on iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        WatchOutboxView(companion: companion)
                    } label: {
                        Label("Drafts & Outbox", systemImage: "tray.and.arrow.up")
                    }
                }
                let pending = companion.state.commands.filter { $0.status == .pendingOnWatch }.count
                let accepted = companion.state.commands.filter { $0.status == .acceptedByPhone }.count
                let needsReview = companion.state.commands.filter { $0.status == .needsReview }.count
                let pendingHandoffs = companion.state.handoffs.filter { $0.status == .pending }.count
                let failedHandoffs = companion.state.handoffs.filter { $0.status == .failed }.count
                if pending > 0 || accepted > 0 || needsReview > 0
                    || pendingHandoffs > 0 || failedHandoffs > 0 {
                    Section("Actions") {
                        if pending > 0 {
                            Label("\(pending) waiting for iPhone", systemImage: "clock")
                        }
                        if accepted > 0 {
                            Label("\(accepted) accepted by iPhone; queueing", systemImage: "checkmark")
                        }
                        if needsReview > 0 {
                            Label("\(needsReview) action(s) need delivery review",
                                  systemImage: "questionmark.circle")
                                .foregroundStyle(.orange)
                        }
                        if pendingHandoffs > 0 {
                            Label("\(pendingHandoffs) handoff requests waiting",
                                  systemImage: "iphone.and.arrow.forward")
                        }
                        if failedHandoffs > 0 {
                            Label("\(failedHandoffs) handoff requests failed",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if companion.state.folders.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Cached Mail",
                            systemImage: "envelope",
                            description: Text("Open Mailternal on iPhone to sync recent messages."))
                    }
                } else {
                    Section("Folders") {
                        ForEach(companion.state.folders) { folder in
                            NavigationLink {
                                WatchMessageListView(folder: folder, companion: companion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: folder.role == "inbox" ? "tray" : "folder")
                                        .foregroundStyle(.tint)
                                    Text(folder.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if folder.unreadCount > 0 {
                                        Text(folder.unreadCount, format: .number)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("\(folder.unreadCount) unread")
                                    }
                                }
                            }
                        }
                    }
                }
                if let lastError = companion.state.lastError {
                    Section {
                        Label(lastError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("Mailternal")
        }
    }
}

private struct WatchConnectionBanner: View {
    @ObservedObject var companion: WatchCompanionSession

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(companion.isReachable ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                    Text(syncDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var title: String {
        switch companion.connection {
        case .reachable:
            "Connected to iPhone"
        case .activating:
            "Connecting to iPhone"
        case .disconnected:
            "Using cached mail"
        case .unavailable:
            "iPhone companion unavailable"
        }
    }

    private var iconName: String {
        switch companion.connection {
        case .reachable, .activating:
            "iphone.and.arrow.forward"
        case .disconnected, .unavailable:
            "iphone.slash"
        }
    }

    private var accessibilityLabel: String {
        switch companion.connection {
        case .reachable:
            "Connected to iPhone"
        case .activating:
            "Connecting to iPhone; cached mail remains available"
        case .disconnected:
            "Disconnected; using cached mail"
        case .unavailable:
            "iPhone companion unavailable; using cached mail"
        }
    }

    private var syncDetail: String {
        if let date = companion.state.lastSyncAt {
            return "Last sync \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return companion.connection == .activating ? "Connecting…" : "No sync yet"
    }
}

private struct WatchMessageListView: View {
    let folder: CompanionFolderSnapshot
    @ObservedObject var companion: WatchCompanionSession

    private var messages: [CompanionMessageSnapshot] {
        // CompanionStore preserves the phone's effective per-folder order.
        // Re-sorting by date here would discard custom sort settings.
        companion.state.messages.filter { $0.folderLink == folder.canonicalLink }
    }

    var body: some View {
        List {
            if messages.isEmpty {
                ContentUnavailableView("No Cached Messages", systemImage: "envelope.open")
            } else {
                ForEach(messages) { message in
                    NavigationLink {
                        WatchMessageReaderView(message: message, companion: companion)
                    } label: {
                        WatchMessageRow(message: message, companion: companion)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            companion.queue(message, mutation: message.isRead ? .markUnread : .markRead)
                        } label: {
                            Label(message.isRead ? "Unread" : "Read",
                                  systemImage: message.isRead ? "envelope.badge" : "envelope.open")
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchMessageRow: View {
    let message: CompanionMessageSnapshot
    @ObservedObject var companion: WatchCompanionSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.sender)
                    .font(.footnote.weight(message.isRead ? .regular : .semibold))
                    .lineLimit(1)
                Spacer(minLength: 3)
                Text(message.receivedAt, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                .font(.footnote.weight(message.isRead ? .regular : .semibold))
                .lineLimit(2)
            if let status = statusText {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(
                        status.hasPrefix("Failed") || status.hasPrefix("Delivery")
                            ? .orange : .secondary
                    )
            } else if !message.preview.isEmpty {
                Text(message.preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(message.isPendingRemoval ? 0.62 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.sender), \(message.subject)")
    }

    private var statusText: String? {
        let records = companion.state.commands.filter { $0.command.messageLink == message.canonicalLink }
        guard let record = records.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        switch record.status {
        case .pendingOnWatch: return "Pending on Watch"
        case .acceptedByPhone: return "Accepted by iPhone; queueing"
        case .submittedToMailQueue: return "Submitted to iPhone mail queue"
        case .needsReview:
            return record.failureReason ?? "Delivery status unknown; review before retrying"
        case .failed: return "Failed: \(record.failureReason ?? "try again")"
        }
    }
}

private struct WatchMessageReaderView: View {
    let message: CompanionMessageSnapshot
    @ObservedObject var companion: WatchCompanionSession
    @State private var showsActions = false

    private var currentMessage: CompanionMessageSnapshot {
        companion.state.messages.first(where: { $0.canonicalLink == message.canonicalLink }) ?? message
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(currentMessage.subject.isEmpty ? "(No subject)" : currentMessage.subject)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentMessage.sender)
                        .font(.subheadline.weight(.semibold))
                    Text(currentMessage.receivedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let bodyText = currentMessage.bodyText, !bodyText.isEmpty {
                    Text(bodyText)
                        .font(.body)
                        .textCase(nil)
                } else {
                    Text(currentMessage.preview.isEmpty ? "No message body is cached." : currentMessage.preview)
                        .font(.body)
                        .textCase(nil)
                    Label(
                        "Only a preview is cached. Continue on iPhone for the full message.",
                        systemImage: "iphone.and.arrow.forward"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if currentMessage.hasAttachments {
                    Label(
                        "Attachments are available on iPhone.",
                        systemImage: "paperclip"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let status = statusText {
                    Label(status, systemImage: status.hasPrefix("Failed")
                        || status.hasPrefix("Delivery")
                        ? "exclamationmark.triangle" : "clock")
                        .font(.caption)
                        .foregroundStyle(
                            status.hasPrefix("Failed") || status.hasPrefix("Delivery")
                                ? .orange : .secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let handoffStatus = handoffStatusText {
                    Label(handoffStatus, systemImage: handoffStatus.hasPrefix("Failed") ? "exclamationmark.triangle" : "iphone.and.arrow.forward")
                        .font(.caption)
                        .foregroundStyle(handoffStatus.hasPrefix("Failed") ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Message actions", systemImage: "ellipsis") {
                    showsActions = true
                }
            }
        }
        .sheet(isPresented: $showsActions) {
            NavigationStack {
                List {
                    NavigationLink {
                        WatchComposeView(
                            companion: companion,
                            mode: .reply,
                            message: currentMessage
                        )
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    NavigationLink {
                        WatchComposeView(
                            companion: companion,
                            mode: .replyAll,
                            message: currentMessage
                        )
                    } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    NavigationLink {
                        WatchComposeView(
                            companion: companion,
                            mode: .forward,
                            message: currentMessage
                        )
                    } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    Button(currentMessage.isRead ? "Mark Unread" : "Mark Read",
                           systemImage: currentMessage.isRead ? "envelope.badge" : "envelope.open") {
                        queue(currentMessage.isRead ? .markUnread : .markRead)
                    }
                    Button(currentMessage.isFlagged ? "Unflag" : "Flag",
                           systemImage: currentMessage.isFlagged ? "flag.slash" : "flag") {
                        queue(.setFlagged(!currentMessage.isFlagged))
                    }
                    Button("Archive", systemImage: "archivebox") { queue(.archive) }
                    Button("Trash", systemImage: "trash", role: .destructive) { queue(.trash) }
                    NavigationLink {
                        List {
                            ForEach(companion.state.folders.filter {
                                $0.accountLinkID == currentMessage.accountLinkID &&
                                $0.canonicalLink != currentMessage.folderLink
                            }) { folder in
                                Button(folder.name) {
                                    queue(.move(destinationFolderLink: folder.canonicalLink))
                                }
                            }
                        }
                        .navigationTitle("Move to Folder")
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
                    }
                    Button("Continue on iPhone", systemImage: "iphone.and.arrow.forward") {
                        companion.continueOnPhone(currentMessage.canonicalLink)
                        showsActions = false
                    }
                }
                .navigationTitle("Actions")
            }
        }
    }

    private func queue(_ mutation: CompanionMutation) {
        companion.queue(currentMessage, mutation: mutation)
        showsActions = false
    }
    private var statusText: String? {
        let records = companion.state.commands.filter { $0.command.messageLink == currentMessage.canonicalLink }
        guard let record = records.max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        switch record.status {
        case .pendingOnWatch: return "Pending on Watch"
        case .acceptedByPhone: return "Accepted by iPhone; queueing"
        case .submittedToMailQueue: return "Submitted to iPhone mail queue"
        case .needsReview:
            return record.failureReason ?? "Delivery status unknown; review before retrying"
        case .failed: return "Failed: \(record.failureReason ?? "try again")"
        }
    }

    private var handoffStatusText: String? {
        guard let record = companion.state.handoffs
            .filter({ $0.messageLink == currentMessage.canonicalLink })
            .max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        switch record.status {
        case .pending: return "Continue on iPhone is waiting"
        case .accepted: return "Message opened on iPhone"
        case .failed: return "Failed: \(record.failureReason ?? "try again")"
        }
    }
}

private enum WatchComposeMode: Equatable {
    case newMessage
    case reply
    case replyAll
    case forward

    var title: String {
        switch self {
        case .newMessage: "New Message"
        case .reply: "Reply"
        case .replyAll: "Reply All"
        case .forward: "Forward"
        }
    }

    var sendKind: CompanionSendContent.Kind {
        switch self {
        case .newMessage: .newMessage
        case .reply: .reply
        case .replyAll: .replyAll
        case .forward: .forward
        }
    }
}

private struct WatchComposeView: View {
    @ObservedObject var companion: WatchCompanionSession
    let mode: WatchComposeMode
    let message: CompanionMessageSnapshot?
    @Environment(\.dismiss) private var dismiss
    @State private var accountLinkID: String
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var isSending = false
    @State private var validationMessage: String?
    @State private var confirmsDiscard = false

    init(
        companion: WatchCompanionSession,
        mode: WatchComposeMode,
        message: CompanionMessageSnapshot? = nil
    ) {
        self.companion = companion
        self.mode = mode
        self.message = message
        _accountLinkID = State(initialValue: message?.accountLinkID
            ?? companion.state.accounts.first(where: \.canSend)?.id
            ?? "")
    }

    private var accounts: [CompanionAccountSnapshot] {
        companion.state.accounts.filter(\.canSend)
    }

    private var selectedAccount: CompanionAccountSnapshot? {
        companion.state.accounts.first { $0.id == accountLinkID }
    }

    private var content: CompanionSendContent {
        CompanionSendContent(
            kind: mode.sendKind,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: bodyText
        )
    }

    private var canSend: Bool {
        !isSending && selectedAccount?.canSend == true && content.isSyntacticallyValid
    }

    private var hasInput: Bool {
        !to.isEmpty || !cc.isEmpty || !bcc.isEmpty || !subject.isEmpty || !bodyText.isEmpty
    }

    var body: some View {
        Form {
            if mode == .newMessage {
                Section("From") {
                    if accounts.isEmpty {
                        Text("Set up an enabled outgoing account on iPhone.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Account", selection: $accountLinkID) {
                            ForEach(accounts) { account in
                                Text(account.name.isEmpty ? account.email : account.name)
                                    .tag(account.id)
                            }
                        }
                    }
                }
            } else {
                Section("Account") {
                    Text(selectedAccount.map {
                        $0.name.isEmpty ? $0.email : "\($0.name) — \($0.email)"
                    } ?? "This account is unavailable on iPhone.")
                        .foregroundStyle(selectedAccount == nil ? .orange : .primary)
                }
            }

            if mode == .newMessage || mode == .forward {
                Section("Recipients") {
                    TextField("To", text: $to)
                    TextField("Cc", text: $cc)
                    TextField("Bcc", text: $bcc)
                }
            } else {
                Section {
                    Text("Recipients and threading are prepared from the original message on iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if mode == .newMessage {
                Section {
                    TextField("Subject", text: $subject)
                }
            }

            Section(mode == .forward ? "Note (optional)" : "Message") {
                TextField(mode == .forward ? "Note" : "Message", text: $bodyText)
                    .accessibilityLabel(mode == .forward ? "Note" : "Message")
            }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Text("Send queues this message on iPhone. Delivery status appears in Drafts & Outbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(mode.title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if hasInput { confirmsDiscard = true } else { dismiss() }
                }
                .disabled(isSending)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send", systemImage: "paperplane") {
                    Task { await send() }
                }
                .disabled(!canSend)
            }
        }
        .confirmationDialog(
            "Discard this message?",
            isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This message has not been queued.")
        }
        .onAppear {
            if let message, mode != .newMessage {
                accountLinkID = message.accountLinkID
            }
        }
    }

    private func send() async {
        guard selectedAccount?.canSend == true, let accountLinkID = selectedAccount?.id else {
            validationMessage = "Choose an enabled outgoing account."
            return
        }
        guard content.isSyntacticallyValid else {
            validationMessage = "Add a recipient and keep the message within the Watch limits."
            return
        }
        isSending = true
        validationMessage = nil
        let queued = await companion.queueOutgoing(
            accountLinkID: accountLinkID,
            messageLink: message?.canonicalLink,
            mutation: .send(content)
        )
        isSending = false
        if queued {
            dismiss()
        } else {
            validationMessage = companion.state.lastError
                ?? "The message was not saved on Watch. Keep editing and try again."
        }
    }
}

private struct WatchOutgoingItem: Identifiable {
    let id: String
    let accountLinkID: String
    let subject: String
    let state: CompanionOutboxState?
    let pendingStatus: CompanionCommandStatus?
    let failureReason: String?

    var title: String {
        subject.isEmpty ? "No Subject" : subject
    }

    var statusTitle: String {
        if let state {
            switch state {
            case .queued: "Queued on iPhone"
            case .preparing: "Preparing message"
            case .sending: "Sending"
            case .awaitingAcceptance: "Waiting for server confirmation"
            case .deliveryUnknown: "Delivery status unknown"
            case .failed: "Delivery failed"
            case .cancelled: "Delivery cancelled"
            case .sentCopyPending: "Sent · Saving Sent copy"
            case .sent: "Sent"
            }
        } else {
            switch pendingStatus {
            case .pendingOnWatch: "Waiting for iPhone"
            case .acceptedByPhone: "Accepted by iPhone; queueing"
            case .submittedToMailQueue: "Submitted to iPhone mail queue"
            case .needsReview: "Delivery status unknown; review required"
            case .failed: "Failed before iPhone mail queue"
            case nil: "Waiting for iPhone"
            }
        }
    }

    var symbol: String {
        if let state {
            switch state {
            case .queued: "clock"
            case .preparing, .sending, .awaitingAcceptance: "paperplane"
            case .deliveryUnknown, .failed: "exclamationmark.triangle"
            case .cancelled: "xmark.circle"
            case .sentCopyPending: "tray.and.arrow.down"
            case .sent: "checkmark.circle"
            }
        } else {
            pendingStatus == .failed || pendingStatus == .needsReview
                ? "exclamationmark.triangle" : "clock"
        }
    }
}

private struct WatchOutboxView: View {
    @ObservedObject var companion: WatchCompanionSession
    @State private var duplicateRiskID: String?

    private var items: [WatchOutgoingItem] {
        let outgoing = companion.state.outgoing
        let outgoingIDs = Set(outgoing.map(\.id))
        var result = outgoing.map {
            WatchOutgoingItem(
                id: $0.id,
                accountLinkID: $0.accountLinkID,
                subject: $0.subject,
                state: $0.state,
                pendingStatus: nil,
                failureReason: $0.failureReason
            )
        }
        result.append(contentsOf: companion.state.commands.compactMap { record in
            guard record.command.mutation.isOutgoing else { return nil }
            let projectedID: String?
            switch record.command.mutation {
            case .send:
                projectedID = record.id
            case .retrySubmission(let id, _), .cancelSubmission(let id):
                projectedID = id
            default:
                projectedID = nil
            }
            guard projectedID.map({ !outgoingIDs.contains($0) }) ?? true else {
                return nil
            }
            let subject: String
            if case .send(let content) = record.command.mutation {
                subject = content.subject
            } else {
                subject = ""
            }
            return WatchOutgoingItem(
                id: record.id,
                accountLinkID: record.command.accountLinkID,
                subject: subject,
                state: nil,
                pendingStatus: record.status,
                failureReason: record.failureReason
            )
        })
        return result
    }
    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("No Outgoing Messages", systemImage: "tray")
            } else {
                ForEach(items) { item in
                    outgoingRow(item)
                }
            }
            if let error = companion.state.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("Drafts & Outbox")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delivery status unknown",
            isPresented: Binding(
                get: { duplicateRiskID != nil },
                set: { if !$0 { duplicateRiskID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let id = duplicateRiskID,
               let item = items.first(where: { $0.id == id }) {
                Button("Send Again — Duplicate Possible", role: .destructive) {
                    Task {
                        _ = await companion.queueOutgoing(
                            accountLinkID: item.accountLinkID,
                            mutation: .retrySubmission(
                                id: item.id,
                                acknowledgeDuplicateRisk: true
                            )
                        )
                    }
                    duplicateRiskID = nil
                }
            }
            Button("Cancel", role: .cancel) { duplicateRiskID = nil }
        } message: {
            Text("The server may already have delivered this message. Retrying can send a duplicate. Check Sent or confirm with the recipient first.")
        }
    }

    @ViewBuilder
    private func outgoingRow(_ item: WatchOutgoingItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
            if let account = companion.state.accounts.first(where: { $0.id == item.accountLinkID }) {
                Text(account.name.isEmpty ? account.email : account.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Label(item.statusTitle, systemImage: item.symbol)
                .font(.caption)
                .foregroundStyle(
                    item.state == .failed || item.state == .deliveryUnknown
                        || item.pendingStatus == .failed || item.pendingStatus == .needsReview
                        ? .orange : .secondary
                )
            if let reason = item.failureReason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.state == .failed || item.state == .cancelled {
                Text("Open Drafts & Outbox on iPhone to edit or recover the retained draft and attachments.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if item.state == .deliveryUnknown {
                    Button("Retry") { duplicateRiskID = item.id }
                } else if item.state == .failed || item.state == .sentCopyPending {
                    Button(item.state == .sentCopyPending ? "Retry Sent Copy" : "Retry") {
                        Task {
                            _ = await companion.queueOutgoing(
                                accountLinkID: item.accountLinkID,
                                mutation: .retrySubmission(
                                    id: item.id,
                                    acknowledgeDuplicateRisk: false
                                )
                            )
                        }
                    }
                }
                if item.state == .queued || item.state == .preparing || item.state == .sending {
                    Button("Cancel", role: .destructive) {
                        Task {
                            _ = await companion.queueOutgoing(
                                accountLinkID: item.accountLinkID,
                                mutation: .cancelSubmission(id: item.id)
                            )
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

#endif
