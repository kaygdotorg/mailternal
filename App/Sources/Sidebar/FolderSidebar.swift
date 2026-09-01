import AppKit
import SwiftUI
import MailternalInterfaces


struct FolderSidebar: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: Binding(
            get: { model.selectedFolderID },
            set: { model.selectFolder($0) }
        )) {
            if !model.specialFolders.isEmpty {
                Section("Mailboxes") {
                    ForEach(model.specialFolders) { folder in
                        FolderRow(folder: folder, selected: folder.id == model.selectedFolderID)
                            .tag(folder.id)
                            .contextMenu { folderMenu(folder) }
                    }
                }
            }
            if !model.customFolders.isEmpty {
                Section("Folders") {
                    ForEach(model.customFolders) { folder in
                        FolderRow(folder: folder, selected: folder.id == model.selectedFolderID)
                            .tag(folder.id)
                            .contextMenu { folderMenu(folder) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(UIIdentifier.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        .overlay {
            if model.folders.isEmpty {
                EmptyMailboxState(
                    title: model.isAccountActive ? "No mailboxes" : "Add an account",
                    detail: model.isAccountActive
                        ? "Mailboxes appear after the first sync."
                        : "Set up an IMAP account to start reading mail."
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let accountLabel {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(accountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private var accountLabel: String? {
        switch model.accountState {
        case .none: nil
        case .validating: "Signing in…"
        case .active: "IMAP account"
        case .authFailed: "Sign-in failed"
        case .connectionFailed: "Offline"
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: FolderSummary) -> some View {
        Button("Refresh") {
            Task { await model.refresh() }
        }
        Button("Copy Folder Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
        Divider()
        Text("\(folder.unreadCount) unread of \(folder.totalCount)")
    }
}

struct FolderRow: View {
    let folder: FolderSummary
    let selected: Bool
    @State private var disclosed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: folder.role.systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                backfillAccessory
                if folder.unreadCount > 0 {
                    Text(folder.unreadCount > 99 ? "99+" : "\(folder.unreadCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(badgeForeground)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityLabel("\(folder.unreadCount) unread")
                }
            }
            if disclosed {
                statusLine
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(reduceMotion ? MailMotion.disclosure : MailMotion.disclosure) {
                disclosed.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(UIIdentifier.sidebarFolder(folder.path))
    }

    @ViewBuilder
    private var backfillAccessory: some View {
        switch folder.backfill {
        case .idle, .complete:
            EmptyView()
        case .syncing(let progress):
            if let progress {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .frame(width: 36)
                    .accessibilityLabel("Backfill \(Int((progress * 100).rounded())) percent")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Backfill in progress")
            }
        case .halted:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .help("Backfill halted")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch folder.backfill {
        case .halted(let date):
            Text("Synced through \(MailDateFormat.syncedThrough(date))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing(let progress):
            Text(progress.map { "Backfilling \(Int(($0 * 100).rounded()))%" } ?? "Backfilling…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .idle:
            Text("Waiting to sync")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .complete:
            EmptyView()
        }
    }

    private var badgeForeground: Color {
        OutgoingForegroundPolicy.prefersBlackText(on: NSColor.controlAccentColor) ? .black : .white
    }

    private var accessibilityLabel: String {
        var parts = [folder.name]
        if folder.unreadCount > 0 { parts.append("\(folder.unreadCount) unread") }
        switch folder.backfill {
        case .halted(let date):
            parts.append("synced through \(MailDateFormat.syncedThrough(date))")
        case .syncing:
            parts.append("syncing")
        default:
            break
        }
        return parts.joined(separator: ", ")
    }
}

struct EmptyMailboxState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
