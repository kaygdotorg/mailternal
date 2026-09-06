import SwiftUI
import MailternalInterfaces

struct IOSRootView: View {
    @Bindable var state: IOSAppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isAccountEditorPresented = false
    @State private var editingAccount: AccountConfig?
    @State private var folderToRename: FolderSummary?
    @State private var renameText = ""
    @State private var isMovePickerPresented = false
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            IOSFolderSidebar(
                state: state,
                columnVisibility: $columnVisibility,
                onRename: { folder in
                    folderToRename = folder
                    renameText = folder.name
                }
            )
            .navigationTitle("Mail")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isAccountEditorPresented = true } label: {
                        Label("Add Account", systemImage: "person.badge.plus")
                    }
                    .accessibilityLabel("Add account")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.isSettingsPresented = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        } content: {
            IOSMessageListView(
                state: state,
                columnVisibility: $columnVisibility,
                isMovePickerPresented: $isMovePickerPresented
            )
        } detail: {
            IOSReaderView(state: state)
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(state.isApplyingRemoteNavigation)
        .onChange(of: state.workspace.values) { _, _ in
            state.applyWorkspaceValues()
        }
        .sheet(isPresented: $isAccountEditorPresented) {
            IOSAccountEditorView(state: state, account: nil)
        }
        .sheet(isPresented: Binding(
            get: { editingAccount != nil },
            set: { if !$0 { editingAccount = nil } }
        )) {
            if let editingAccount {
                IOSAccountEditorView(state: state, account: editingAccount)
            }
        }
        .sheet(isPresented: $state.isSettingsPresented) {
            IOSSettingsView(state: state)
        }
        .alert("Rename folder", isPresented: Binding(
            get: { folderToRename != nil },
            set: { if !$0 { folderToRename = nil } }
        )) {
            TextField("Folder name", text: $renameText)
            Button("Cancel", role: .cancel) { folderToRename = nil }
            Button("Rename") {
                if let folder = folderToRename {
                    Task { await state.renameFolder(folder, name: renameText) }
                }
                folderToRename = nil
            }
        } message: {
            Text("The rename is queued and will be sent through the account’s IMAP session.")
        }
        .alert("Mailternal", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let notice = state.noticeMessage {
                IOSNoticeBanner(text: notice) { state.noticeMessage = nil }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

private struct IOSNoticeBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 5)
        .padding(.horizontal)
    }
}

struct IOSFolderSidebar: View {
    @Bindable var state: IOSAppState
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onRename: (FolderSummary) -> Void


    var body: some View {
        Group {
            if state.accounts.isEmpty && state.launchPhase == .ready {
                ContentUnavailableView {
                    Label("No accounts", systemImage: "tray")
                } description: {
                    Text("Add an IMAP account to start reading mail.")
                } actions: {
                    Text("Use the add-account button in the toolbar.")
                        .foregroundStyle(.secondary)
                }
            } else {
                List(selection: Binding(
                    get: { state.selectedFolderID },
                    set: { folder in
                        guard let folder else { return }
                        Task {
                            await state.selectFolder(folder)
                            if horizontalSizeClass == .compact {
                                columnVisibility = .doubleColumn
                            }
                        }
                    }
                )) {
                    ForEach(state.accounts, id: \.id) { account in
                        let folders = state.folders.filter { $0.accountID == account.id }
                        Section {
                            if folders.isEmpty {
                                Text(account.isEnabled ? "Waiting for folders…" : "Account disabled")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(folders) { folder in
                                    IOSFolderRow(folder: folder)
                                        .tag(folder.id)
                                        .contextMenu {
                                            Button("Rename…") { onRename(folder) }
                                            Toggle(
                                                "Keep Mail on This Device",
                                                isOn: Binding(
                                                    get: { folder.keepLocally },
                                                    set: { keep in Task { await state.setRetention(folder, keep: keep) } }
                                                )
                                            )
                                        }
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(account.isEnabled ? .green : .red)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName.isEmpty ? account.emailAddress : account.displayName)
                                        .font(.headline)
                                        .foregroundStyle(account.isEnabled ? .primary : .secondary)
                                    Text(state.accountStateDescription(account) ?? account.emailAddress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .textCase(nil)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .overlay {
            if state.launchPhase == .opening || state.launchPhase == .restoring {
                IOSLoadingCard(title: state.launchPhase == .opening ? "Opening mail storage…" : "Restoring accounts…")
            } else if case .failed(let message) = state.launchPhase {
                IOSLoadingCard(title: "Storage unavailable", detail: message)
            }
        }
    }
}

private struct IOSFolderRow: View {
    let folder: FolderSummary
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(folder.name).lineLimit(1)
                Spacer(minLength: 0)
                if folder.unreadCount > 0 {
                    Text(folder.unreadCount.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                switch folder.activity {
                case .downloading, .indexing, .moving:
                    ProgressView().controlSize(.mini)
                case .halted:
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                case .idle, .quarantinedStall:
                    EmptyView()
                }
            }
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(folder.role == .inbox ? .blue : .secondary)
        }
        .accessibilityValue(folder.unreadCount > 0 ? "\(folder.unreadCount) unread" : "No unread messages")
    }

    private var iconName: String {
        switch folder.role {
        case .inbox: "tray"
        case .archive: "archivebox"
        case .trash: "trash"
        case .junk: "exclamationmark.triangle"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .none: "folder"
        }
    }
}

struct IOSMessageListView: View {
    @Bindable var state: IOSAppState
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isMovePickerPresented: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchText = ""

    private func open(_ row: MessageRow) {
        if state.isSelecting {
            state.toggleSelection(row)
            return
        }
        Task {
            guard await state.open(row: row) else { return }
            if horizontalSizeClass == .compact {
                columnVisibility = .detailOnly
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if state.syncStatus.mode.isWindowed {
                Label(state.syncStatus.mode.coverageDisclosure, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.45))
            }
            if state.isSelecting {
                IOSSelectionToolbar(state: state, isMovePickerPresented: $isMovePickerPresented)
            }
            List {
                if !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(state.searchResults) { row in
                        IOSMessageRow(
                            row: row,
                            selected: state.selectedMessageIDs.contains(row.id),
                            showSenderIcon: state.showSenderIcons,
                            leadingSwipe: state.actions.swipeActions(for: .leading),
                            trailingSwipe: state.actions.swipeActions(for: .trailing),
                            onOpen: { open(row) },
                            onSelect: { state.toggleSelection(row) },
                            onMark: { Task { await state.mark(row, read: !row.isRead) } },
                            onFlag: { Task { await state.toggleFlag(row) } },
                            onArchive: { Task { await state.archive(row) } },
                            onTrash: { Task { await state.trash(row) } }
                        )
                    }
                } else {
                    ForEach(state.rows) { row in
                        IOSMessageRow(
                            row: row,
                            selected: state.selectedMessageIDs.contains(row.id),
                            showSenderIcon: state.showSenderIcons,
                            leadingSwipe: state.actions.swipeActions(for: .leading),
                            trailingSwipe: state.actions.swipeActions(for: .trailing),
                            onOpen: { open(row) },
                            onSelect: { state.toggleSelection(row) },
                            onMark: { Task { await state.mark(row, read: !row.isRead) } },
                            onFlag: { Task { await state.toggleFlag(row) } },
                            onArchive: { Task { await state.archive(row) } },
                            onTrash: { Task { await state.trash(row) } }
                        )
                        .onAppear {
                            if row.id == state.rows.last?.id && state.hasMorePages {
                                Task { await state.loadNextPage() }
                            }
                        }
                    }
                    if state.isLoadingPage {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                let trimmedQuery = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedQuery.isEmpty && !state.isSearching {
                    if let searchError = state.searchErrorMessage {
                        ContentUnavailableView {
                            Label("Search unavailable", systemImage: "exclamationmark.magnifyingglass")
                        } description: {
                            Text(searchError)
                        }
                    } else if state.searchResults.isEmpty {
                        ContentUnavailableView {
                            Label("No results", systemImage: "magnifyingglass")
                        } description: {
                            Text("No messages matched “\(trimmedQuery)” in synced mail.")
                        }
                    }
                }
                if state.rows.isEmpty && trimmedQuery.isEmpty && !state.isLoadingPage {
                    let localRetention = state.selectedFolder?.keepLocally ?? true
                    ContentUnavailableView {
                        Label(
                            localRetention ? (state.selectedFolder == nil ? "Select a folder" : "No messages") : "Mail isn’t kept on this device",
                            systemImage: localRetention ? "tray" : "externaldrive.badge.xmark"
                        )
                    } description: {
                        Text(
                            localRetention
                                ? (state.selectedFolder == nil ? "Choose a mailbox from the sidebar." : "New mail will appear here when it arrives.")
                                : "Enable Keep Mail on This Device in the folder menu to read cached messages here."
                        )
                    }
                }
                if state.isSearching { ProgressView().controlSize(.large) }
            }
        }
        .navigationTitle(state.selectedFolder?.name ?? "Messages")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search all mail")
        .onChange(of: searchText) { _, text in
            Task { await state.search(text) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                IOSListSortMenu(state: state)
                if state.isSelecting {
                    Button("Done") { state.clearSelection() }
                } else {
                    Button { state.isSelecting = true } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
                Button { Task { await state.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private struct IOSListSortMenu: View {
    @Bindable var state: IOSAppState

    var body: some View {
        Menu {
            Picker(
                "Scope",
                selection: Binding(
                    get: {
                        state.canCustomizeCurrentFolder
                            ? state.listSettingsScope
                            : .global
                    },
                    set: { state.setListSettingsScope($0) }
                )
            ) {
                Text(IOSListSettingsScope.global.title)
                    .tag(IOSListSettingsScope.global)
                if state.canCustomizeCurrentFolder {
                    Text(IOSListSettingsScope.currentFolder.title)
                        .tag(IOSListSettingsScope.currentFolder)
                }
            }
            Divider()
            Picker(
                "Sort by",
                selection: Binding(
                    get: { state.listSortForSettings.field },
                    set: { field in
                        let current = state.listSortForSettings
                        Task {
                            await state.setListSort(
                                MailListSort(field: field, direction: current.direction)
                            )
                        }
                    }
                )
            ) {
                ForEach(MailListSort.Field.allCases, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            }
            Picker(
                "Order",
                selection: Binding(
                    get: { state.listSortForSettings.direction },
                    set: { direction in
                        let current = state.listSortForSettings
                        Task {
                            await state.setListSort(
                                MailListSort(field: current.field, direction: direction)
                            )
                        }
                    }
                )
            ) {
                ForEach(MailListSort.Direction.allCases, id: \.self) { direction in
                    Text(direction.title).tag(direction)
                }
            }
            Divider()
            Button("Reset \(state.listSettingsScopeTitle) sort", role: .destructive) {
                Task { await state.resetListSort() }
            }
        } label: {
            Label("Sort and scope", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Message list sort and scope")
    }
}

private struct IOSSelectionToolbar: View {
    @Bindable var state: IOSAppState
    @Binding var isMovePickerPresented: Bool
    var body: some View {
        let unflag = state.selectedMessagesAreAllFlagged
        HStack(spacing: 18) {
            Text("\(state.selectedMessageIDs.count) selected")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button { Task { await state.markSelected(read: true) } } label: { Label("Read", systemImage: "envelope.open") }
            Button { Task { await state.setFlagged(!unflag) } } label: {
                Label(unflag ? "Unflag" : "Flag", systemImage: unflag ? "flag.slash" : "flag")
            }
            .accessibilityLabel(unflag ? "Unflag selected messages" : "Flag selected messages")
            Button { Task { await state.archiveSelected() } } label: { Label("Archive", systemImage: "archivebox") }
            Button { Task { await state.trashSelected() } } label: { Label("Trash", systemImage: "trash") }
            Button { isMovePickerPresented = true } label: { Label("Move", systemImage: "folder") }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal)
        .padding(.vertical, 9)
        .background(.bar)
        .sheet(isPresented: $isMovePickerPresented) {
            IOSMoveFolderView(state: state)
        }
    }
}
private struct IOSMessageRow: View {
    let row: MessageRow
    let selected: Bool
    let showSenderIcon: Bool
    let leadingSwipe: [SwipeActionKind]
    let trailingSwipe: [SwipeActionKind]
    let onOpen: () -> Void
    let onSelect: () -> Void
    let onMark: () -> Void
    let onFlag: () -> Void
    let onArchive: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            } else if showSenderIcon {
                Text(row.from.first.map(String.init) ?? "?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.gradient, in: Circle())
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(row.from)
                            .font(.subheadline.weight(row.isRead ? .regular : .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(row.date, format: .dateTime.month(.abbreviated).day())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Text(row.subject.isEmpty ? "(No subject)" : row.subject)
                            .font(.subheadline.weight(row.isRead ? .regular : .semibold))
                            .lineLimit(1)
                        if row.isFlagged { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                        if row.hasAttachments { Image(systemName: "paperclip").foregroundStyle(.secondary) }
                    }
                    Text(row.preview.isEmpty ? "No preview available" : row.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Open") { onOpen() }
            Button("Select") { onSelect() }
            Button(row.isRead ? "Mark Unread" : "Mark Read") { onMark() }
            Button(row.isFlagged ? "Unflag" : "Flag") { onFlag() }
            Divider()
            Button("Archive") { onArchive() }
            Button("Trash", role: .destructive) { onTrash() }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            ForEach(Array(leadingSwipe.enumerated()), id: \.offset) { item in
                swipeButton(item.element)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            ForEach(Array(trailingSwipe.enumerated()), id: \.offset) { item in
                swipeButton(item.element)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.from), \(row.subject.isEmpty ? "No subject" : row.subject)")
        .accessibilityValue(row.isRead ? "Read" : "Unread")
    }

    @ViewBuilder
    private func swipeButton(_ kind: SwipeActionKind) -> some View {
        let label = Label(
            kind.title(isRead: row.isRead, isFlagged: row.isFlagged),
            systemImage: kind.systemImage(isRead: row.isRead, isFlagged: row.isFlagged)
        )
        switch kind {
        case .trash:
            Button(role: .destructive, action: onTrash) { label }
        case .archive:
            Button(action: onArchive) { label }.tint(.blue)
        case .toggleRead:
            Button(action: onMark) { label }.tint(.blue)
        case .toggleFlag:
            Button(action: onFlag) { label }.tint(.orange)
        }
    }
}

private struct IOSMoveFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: IOSAppState
    var body: some View {
        NavigationStack {
            List(state.folders) { folder in
                Button {
                    Task { await state.moveSelected(to: folder.id); dismiss() }
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
                .disabled(folder.id == state.selectedFolderID)
            }
            .navigationTitle("Move to Folder")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct IOSLoadingCard: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 18)
        .padding()
    }
}

private extension SyncStatus.Mode {
    var isWindowed: Bool {
        if case .windowed = self { return true }
        return false
    }

    var coverageDisclosure: String {
        if case .windowed(let date) = self {
            return "Search covers mail since \(date.formatted(date: .abbreviated, time: .omitted))."
        }
        return ""
    }
}
