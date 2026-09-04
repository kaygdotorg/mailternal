import MailternalInterfaces
import AppKit
import SwiftUI

struct AccountsSettingsView: View {
    @Bindable var model: AppModel
    let toolbarCoordinator: SettingsToolbarCoordinator
    @State private var expandedRowID: AccountID?
    @State private var pendingRemovalID: AccountID?
    @State private var draftDisplayNames: [AccountID: String] = [:]
    @State private var editorHeights: [AccountID: CGFloat] = [:]
    @State private var isRemoveConfirmationPresented = false

    private static let blankAccountID = AccountID(rawValue: "new-account")

    private var accounts: [AccountConfig] {
        AccountsListPolicy.sorted(model.accountConfigs)
    }

    private var isAdding: Bool {
        expandedRowID == Self.blankAccountID
    }

    private var canAdd: Bool {
        !isAdding
    }

    private var isValidating: Bool {
        model.accountStates.values.contains {
            if case .validating = $0 { return true }
            return false
        }
    }
    var body: some View {
        Group {
            if accounts.isEmpty && !isAdding {
                emptyState
            } else {
                accountList
            }
        }
        .accessibilityIdentifier(UIIdentifier.accountsList)
        .onAppear {
            reportToolbarState()
        }
        .onChange(of: isAdding) { _, _ in
            reportToolbarState()
        }
        .onChange(of: isValidating) { _, _ in
            reportToolbarState()
        }
        .onChange(of: toolbarCoordinator.addAccountRequestGeneration) { _, _ in
            addBlankAccount()
        }
        .alert("Remove Account?", isPresented: $isRemoveConfirmationPresented) {
            Button("Remove", role: .destructive) {
                Task { await removePendingAccount() }
            }
            Button("Cancel", role: .cancel) {
                pendingRemovalID = nil
            }
        } message: {
            Text("This removes the account and its saved password from Mailternal.")
        }
        .onChange(of: accounts.map(\.id)) { _, ids in
            guard let expandedRowID, expandedRowID != Self.blankAccountID else { return }
            if !ids.contains(expandedRowID) {
                self.expandedRowID = nil
            }
        }
    }

    private var accountList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(accounts, id: \.id) { account in
                        accountSection(account)
                    }
                    if isAdding {
                        accountSection(nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: expandedRowID) { _, rowID in
                guard let rowID else { return }
                DispatchQueue.main.async {
                    withAnimation(MailMotion.expand) {
                        proxy.scrollTo(rowID, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountSection(_ account: AccountConfig?) -> some View {
        let rowID = account?.id ?? Self.blankAccountID
        let isExpanded = expandedRowID == rowID
        let state = account.map { model.accountStates[$0.id] ?? .none } ?? .none
        let editorHeight = editorHeights[rowID] ?? 0
        let targetEditorHeight = isExpanded ? editorHeight : 0

        VStack(spacing: 0) {
            AccountRow(
                account: account,
                state: state,
                displayName: displayNameBinding(for: account),
                isExpanded: isExpanded,
                onToggle: { toggleExpansion(for: rowID) },
                onCommitName: { commitDisplayName($0, for: rowID) },
                onToggleEnabled: account == nil ? nil : {
                    Task { await model.setAccountEnabled(rowID, !account!.isEnabled) }
                },
                onRemove: account == nil ? nil : { requestRemoval(rowID) }
            )

            // Keep the editor in the hierarchy while collapsed. Its fixed-size
            // measurement remains available even though the outer container
            // clips it to zero height, preventing a second reflow.
            ZStack(alignment: .top) {
                AccountEditorSheet(
                    model: model,
                    configuration: account,
                    displayName: displayNameBinding(for: account),
                    onCancel: { cancelEditing(rowID) },
                    onSaved: { finishEditing(rowID) },
                    onRemove: account == nil ? nil : { requestRemoval(rowID) }
                )
                .padding(.leading, 28)
                .padding(.trailing, 8)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    guard height.isFinite, height > 0 else { return }
                    guard abs((editorHeights[rowID] ?? 0) - height) > 0.5 else { return }
                    editorHeights[rowID] = height
                }
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: targetEditorHeight, alignment: .top)
            .clipped()
            .animation(
                isExpanded ? MailMotion.expand : MailMotion.accountEditorCollapse,
                value: targetEditorHeight
            )
        }
        .background(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(account.map { $0.isEnabled ? 1 : 0.55 } ?? 1)
        .id(rowID)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No accounts")
                .font(.headline)
            Text("Add an account to start receiving mail.")
                .foregroundStyle(.secondary)
            Button("Add an account") {
                addBlankAccount()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(UIIdentifier.accountsEmptyAdd)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayNameBinding(for account: AccountConfig?) -> Binding<String> {
        let id = account?.id ?? Self.blankAccountID
        return Binding(
            get: {
                if let draft = draftDisplayNames[id] { return draft }
                guard let account else { return "" }
                return AccountTitlePolicy.title(for: account) ?? account.emailAddress
            },
            set: { draftDisplayNames[id] = $0 }
        )
    }

    private func reportToolbarState() {
        toolbarCoordinator.reportAccountsState(
            canAdd: canAdd,
            isValidating: isValidating
        )
    }

    private func addBlankAccount() {
        guard canAdd else { return }
        draftDisplayNames[Self.blankAccountID] = ""
        withAnimation(MailMotion.expand) {
            expandedRowID = Self.blankAccountID
        }
    }

    private func toggleExpansion(for id: AccountID) {
        let next = AccountsListPolicy.nextExpandedID(
            current: expandedRowID,
            requested: id
        )
        withAnimation(next == nil ? MailMotion.accountEditorCollapse : MailMotion.expand) {
            expandedRowID = next
        }
    }

    private func cancelEditing(_ id: AccountID) {
        withAnimation(MailMotion.accountEditorCollapse) {
            if AccountsListPolicy.removesBlankRow(rowID: id, blankID: Self.blankAccountID) {
                draftDisplayNames[id] = nil
            }
            if expandedRowID == id {
                expandedRowID = nil
            }
        }
    }

    private func finishEditing(_ id: AccountID) {
        withAnimation(MailMotion.accountEditorCollapse) {
            if id == Self.blankAccountID {
                draftDisplayNames[id] = nil
            }
            if expandedRowID == id {
                expandedRowID = nil
            }
        }
    }

    private func commitDisplayName(_ input: String, for id: AccountID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        let committed = AccountsListPolicy.committedName(input: input, email: account.emailAddress)
        draftDisplayNames[id] = committed
        Task { @MainActor in
            await model.renameAccount(id, to: committed)
            // The stored name now flows through accountsStream; drop the
            // draft so the row shows exactly what was persisted.
            draftDisplayNames[id] = nil
        }
    }

    private func requestRemoval(_ id: AccountID) {
        pendingRemovalID = id
        isRemoveConfirmationPresented = true
    }
    @MainActor
    private func removePendingAccount() async {
        guard let id = pendingRemovalID else { return }
        do {
            try await model.facade.removeAccount(id)
            pendingRemovalID = nil
            expandedRowID = nil
        } catch {
            model.toasts.post(
                title: "Couldn’t remove account",
                detail: error.localizedDescription,
                severity: .error
            )
        }
    }
}

private struct AccountRow: View {
    let account: AccountConfig?
    let state: AccountState
    @Binding var displayName: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCommitName: (String) -> Void
    let onToggleEnabled: (() -> Void)?
    let onRemove: (() -> Void)?
    @State private var isHovered = false
    @FocusState private var isNameFocused: Bool

    private var rowID: String {
        account?.id.rawValue ?? "new-account"
    }

    private var email: String {
        account?.emailAddress ?? "Configure your account"
    }

    private var summary: AccountsListPolicy.RowSummary? {
        account.map { AccountsListPolicy.rowSummary(for: $0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Account name", text: $displayName)
                    .font(.headline)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($isNameFocused)
                    .onSubmit {
                        commitName()
                        if !isExpanded { onToggle() }
                    }
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused { commitName() }
                    }
                    .accessibilityIdentifier(UIIdentifier.accountsRowName)

                Text(email)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(UIIdentifier.accountsRowEmail)
                if case .error(let message) = AccountsListPolicy.status(for: state), account != nil {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if let account {
                HStack(spacing: 4) {
                    Button {
                        onToggleEnabled?()
                    } label: {
                        Image(systemName: account.isEnabled ? "pause.circle" : "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(account.isEnabled ? "Disable Account" : "Enable Account")
                    .help(account.isEnabled ? "Disable account" : "Enable account")

                    Button(role: .destructive) {
                        onRemove?()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(UIIdentifier.accountsRemove)
                    .accessibilityLabel("Remove Account")
                    .help("Remove account")
                }
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .animation(MailMotion.hover, value: isHovered)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityIdentifier(UIIdentifier.accountsRowDisclosure)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(UIIdentifier.accountsRow(rowID))
        .accessibilityLabel(summary?.text ?? "New account")
        .onTapGesture {
            guard !isNameFocused else { return }
            onToggle()
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if let account {
                Button {
                    onToggleEnabled?()
                } label: {
                    Label(
                        account.isEnabled ? "Disable Account" : "Enable Account",
                        systemImage: account.isEnabled ? "pause.circle" : "play.circle"
                    )
                }
                Button(role: .destructive) {
                    onRemove?()
                } label: {
                    Label("Remove Account", systemImage: "trash")
                }
            }
        }
    }

    private var statusColor: Color {
        guard account != nil else { return .secondary }
        switch AccountsListPolicy.status(for: state) {
        case .active: return .green
        case .validating: return .orange
        case .error: return .red
        }
    }

    private func commitName() {
        onCommitName(displayName)
    }
}
