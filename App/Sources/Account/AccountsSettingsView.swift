import SwiftUI
import MailternalInterfaces

struct AccountsSettingsView: View {
    @Bindable var model: AppModel
    @State private var selectedAccountID: AccountID?
    @State private var editorPresentation: AccountEditorPresentation?
    @State private var isRemoveConfirmationPresented = false

    private var accounts: [AccountConfig] {
        AccountsListPolicy.sorted(model.accountConfigs)
    }
    private var selectedAccount: AccountConfig? {
        accounts.first { $0.id == selectedAccountID }
    }

    private var canAdd: Bool {
        AccountsListPolicy.canAdd(accountCount: accounts.count)
    }

    private var isValidating: Bool {
        if case .validating = model.accountState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
            controls
        }
        .accessibilityIdentifier(UIIdentifier.accountsList)
        .sheet(item: $editorPresentation) { presentation in
            AccountEditorSheet(
                model: model,
                configuration: presentation.configuration
            )
        }
        .alert("Remove Account?", isPresented: $isRemoveConfirmationPresented) {
            Button("Remove", role: .destructive) {
                Task { await removeSelectedAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the account and its saved password from Mailternal.")
        }
        .onChange(of: accounts.map(\.id)) { _, ids in
            if let selectedAccountID, !ids.contains(selectedAccountID) {
                self.selectedAccountID = nil
            }
        }
    }

    private var accountList: some View {
        List(selection: $selectedAccountID) {
            ForEach(accounts, id: \.id) { account in
                AccountRow(
                    account: account,
                    state: model.accountState,
                    onOpen: { openEditor(account) }
                )
                .tag(account.id)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onSubmit {
            if let selectedAccount { openEditor(selectedAccount) }
        }
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
                editorPresentation = .add
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(UIIdentifier.accountsEmptyAdd)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                Button {
                    editorPresentation = .add
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Add account")
                .accessibilityIdentifier(UIIdentifier.accountsAdd)
                .disabled(!canAdd)

                Button {
                    isRemoveConfirmationPresented = true
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Remove account")
                .accessibilityIdentifier(UIIdentifier.accountsRemove)
                .disabled(selectedAccount == nil || isValidating)
            }

            if !canAdd {
                Text(AccountsListPolicy.multipleAccountsCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func openEditor(_ account: AccountConfig) {
        editorPresentation = .edit(account)
    }

    private func removeSelectedAccount() async {
        guard selectedAccount != nil else { return }
        do {
            try await model.facade.removeAccount()
            selectedAccountID = nil
        } catch {
            // The facade exposes removal errors only as throws. Keep the
            // confirmation flow non-blocking; account state remains visible.
        }
    }
}

private struct AccountRow: View {
    let account: AccountConfig
    let state: AccountState
    let onOpen: () -> Void
    private var summary: AccountsListPolicy.RowSummary {
        AccountsListPolicy.rowSummary(for: account)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(summary.email)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(summary.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if case .error(let message) = AccountsListPolicy.status(for: state) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(UIIdentifier.accountsRow(account.id.rawValue))
        .accessibilityLabel(summary.text)
        .onTapGesture(count: 2, perform: onOpen)
    }

    private var statusColor: Color {
        switch AccountsListPolicy.status(for: state) {
        case .active: .green
        case .validating: .orange
        case .error: .red
        }
    }
}

enum AccountEditorPresentation: Identifiable {
    case add
    case edit(AccountConfig)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let config): "edit-\(config.id.rawValue)"
        }
    }

    var configuration: AccountConfig? {
        switch self {
        case .add: nil
        case .edit(let config): config
        }
    }
}
