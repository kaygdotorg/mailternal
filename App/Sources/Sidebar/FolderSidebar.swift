import AppKit
import SwiftUI
import MailternalInterfaces
import UniformTypeIdentifiers


struct FolderSidebar: View {
    @Bindable var model: AppModel
    @State private var inspectorFolder: FolderSummary?

    var body: some View {
        let roots = FolderHierarchy.make(from: model.folders)
        let specialRoots = roots.filter { $0.folder.role != .none }
        let customRoots = roots.filter { $0.folder.role == .none }

        List(selection: Binding(
            get: { model.selectedFolderID },
            set: { model.selectFolder($0) }
        )) {
            if !specialRoots.isEmpty {
                Section {
                    ForEach(specialRoots) { node in
                        folderNode(node)
                    }
                } header: {
                    sectionHeader(nil, includeAccountTitle: true)
                }
            }
            if !customRoots.isEmpty {
                Section {
                    ForEach(customRoots) { node in
                        folderNode(node)
                    }
                } header: {
                    sectionHeader("Folders", includeAccountTitle: specialRoots.isEmpty)
                }
            }
        }
        .listStyle(.sidebar)
        // The sidebar reaches under the titlebar and its list starts at the
        // window top; the account header carries the fixed inset itself.
        // Never inset the scroll view: SwiftUI rewrites a `.sidebar` List's
        // content insets from the safe area on every layout, and any inset
        // placed there flips in and out (measured: title jumping by 40pt).
        .ignoresSafeArea(.container, edges: .top)
        .background {
            ScrollEdgeEffectSuppressor()
                .allowsHitTesting(false)
        }
        .mailWindowDissolve(.sidebar)
        .popover(item: $inspectorFolder, arrowEdge: .trailing) { folder in
            FolderInspector(folder: folder)
        }
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

    @ViewBuilder
    private func sectionHeader(_ title: String?, includeAccountTitle: Bool) -> some View {
        if includeAccountTitle, model.hasAccount {
            VStack(alignment: .leading, spacing: 4) {
                Text(AccountTitlePolicy.title(for: model.accountConfig) ?? model.listTitleAccountName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(UIIdentifier.sidebarAccountTitle)
                if let title {
                    Text(title)
                }
            }
            .padding(.top, PaneHeaderInsetPolicy.sidebarHeaderPadding)
        } else if let title {
            Text(title)
        }
    }

    private func folderNode(_ node: FolderHierarchyNode) -> some View {
        FolderTreeNodeView(
            node: node,
            selectedID: model.selectedFolderID,
            inspectorFolder: $inspectorFolder,
            onRefresh: {
                Task { await model.refresh() }
            },
            onCopyDeepLink: model.isAccountActive
                ? { folder in
                    Task { await model.copyDeepLink(for: folder.id) }
                }
                : nil,
            onDrop: { folderID, providers in
                guard folderID != model.selectedFolderID else { return false }
                var accepted = false
                for provider in providers where provider.hasItemConformingToTypeIdentifier(MessageLinkPasteboard.type) {
                    accepted = true
                    provider.loadDataRepresentation(
                        forTypeIdentifier: MessageLinkPasteboard.type
                    ) { data, _ in
                        guard let data, let links = MessageLinkPasteboard.decode(data) else { return }
                        Task { @MainActor in
                            await model.moveDroppedLinks(links, to: folderID)
                        }
                    }
                }
                return accepted
            }
        )
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
}

private struct FolderTreeNodeView: View {
    let node: FolderHierarchyNode
    let selectedID: FolderID?
    @Binding var inspectorFolder: FolderSummary?
    let onRefresh: () -> Void
    let onCopyDeepLink: ((FolderSummary) -> Void)?
    let onDrop: (FolderID, [NSItemProvider]) -> Bool
    @State private var isExpanded = true
    @State private var isDropTargeted = false
    var body: some View {
        if node.children.isEmpty {
            decoratedRow
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FolderTreeNodeView(
                        node: child,
                        selectedID: selectedID,
                        inspectorFolder: $inspectorFolder,
                        onRefresh: onRefresh,
                        onCopyDeepLink: onCopyDeepLink,
                        onDrop: onDrop
                    )
                }
            } label: {
                decoratedRow
            }
        }
    }

    private var decoratedRow: some View {
        FolderRow(folder: node.folder, selected: node.folder.id == selectedID)
            .tag(node.folder.id)
            .contextMenu {
                Button("Get Info…") {
                    inspectorFolder = node.folder
                }
                Button("Refresh", action: onRefresh)
                Button("Copy Folder Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.folder.name, forType: .string)
                }
                if let onCopyDeepLink {
                    Button("Copy Deep Link") {
                        onCopyDeepLink(node.folder)
                    }
                }
            }
            .onDrop(
                of: [UTType(exportedAs: MessageLinkPasteboard.type)],
                isTargeted: Binding(
                    get: { isDropTargeted },
                    set: { isDropTargeted = node.folder.id != selectedID && $0 }
                ),
                perform: { providers in
                    guard node.folder.id != selectedID else { return false }
                    return onDrop(node.folder.id, providers)
                }
            )
            .overlay {
                if isDropTargeted, node.folder.id != selectedID {
                    RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(.horizontal, 2)
                }
            }
    }
}

struct FolderRow: View {
    let folder: FolderSummary
    let selected: Bool
    @Environment(AccentSource.self) private var accent
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.role.systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            backfillAccessory
            if folder.unreadCount > 0 {
                Text(folder.unreadCount > 99 ? "99+" : "\(folder.unreadCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(badgeForeground)
                    .background(accent.color, in: Capsule())
                    .accessibilityLabel("\(folder.unreadCount) unread")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .focusEffectDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "")
        // Every folder row is addressed by path in the UI tests, so the
        // identifier belongs on the row itself, hierarchy or not.
        .accessibilityIdentifier(UIIdentifier.sidebarFolder(folder.path))
    }

    @ViewBuilder
    private var backfillAccessory: some View {
        if case .syncing = folder.backfill {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Syncing")
        }
    }

    private var badgeForeground: Color {
        OutgoingForegroundPolicy.prefersBlackText(on: accent.nsColor) ? .black : .white
    }

    private var accessibilityLabel: String {
        var parts = [folder.name]
        if folder.unreadCount > 0 { parts.append("\(folder.unreadCount) unread") }
        switch folder.backfill {
        case .halted:
            parts.append("sync halted")
        case .syncing:
            parts.append("syncing")
        default:
            break
        }
        return parts.joined(separator: ", ")
    }
}

private struct FolderInspector: View {
    let folder: FolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder.name)
                .font(.headline)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("Name", value: folder.name)
                LabeledContent("Path", value: folder.path)
                LabeledContent("Role", value: folder.role.rawValue.capitalized)
                LabeledContent("Messages", value: "\(folder.totalCount)")
                LabeledContent("Unread", value: "\(folder.unreadCount)")
                LabeledContent("Sync", value: syncDescription)
            }
        }
        .padding(16)
        .frame(minWidth: 260, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(folder.name) folder information")
    }

    private var syncDescription: String {
        switch folder.backfill {
        case .idle:
            "Waiting to sync"
        case .complete:
            "Complete"
        case .syncing(let progress):
            progress.map { "Syncing \(Int(($0 * 100).rounded()))%" } ?? "Syncing…"
        case .halted(let date):
            "Halted; synced through \(MailDateFormat.syncedThrough(date))"
        }
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
