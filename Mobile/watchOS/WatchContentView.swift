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
#endif
