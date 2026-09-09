import MailternalInterfaces
import SwiftUI

struct AccountsSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedRowID: AccountID?
    @State private var pendingRemovalID: AccountID?
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
            if AccountsListPolicy.showsEmptyState(for: accounts, isAdding: isAdding) {
                emptyState
            } else {
                accountList
            }
        }
        .accessibilityIdentifier(UIIdentifier.accountsList)
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
            List {
                ForEach(accounts, id: \.id) { account in
                    accountSection(account)
                }
                if isAdding {
                    accountSection(nil)
                }
                HStack {
                    Spacer()
                    Button("Add account…", action: addBlankAccount)
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .disabled(!canAdd || isValidating)
                        .accessibilityIdentifier(UIIdentifier.accountsAdd)
                }
                .padding(.top, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onChange(of: expandedRowID) { _, rowID in
                guard let rowID else { return }
                DispatchQueue.main.async {
                    withAnimation(reduceMotion ? nil : MailMotion.expand) {
                        proxy.scrollTo(rowID, anchor: .top)
                    }
                }
            }
        }
    }

    private func accountSection(_ account: AccountConfig?) -> some View {
        let rowID = account?.id ?? Self.blankAccountID
        let state = account.map { model.accountStates[$0.id] ?? .none } ?? .none

        return Group {
            Button {
                toggleExpansion(for: rowID)
            } label: {
                GroupBox {
                    AccountRow(account: account, state: state)
                        .opacity(account.map { $0.isEnabled ? 1 : 0.55 } ?? 1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(account.map { AccountsListPolicy.rowSummary(for: $0).text } ?? "New account")
            .accessibilityValue(expandedRowID == rowID ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(UIIdentifier.accountsRow(rowID.rawValue))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .id(rowID)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let account {
                Button {
                    Task { await model.setAccountEnabled(rowID, !account.isEnabled) }
                } label: {
                    Label(
                        account.isEnabled ? "Disable Account" : "Enable Account",
                        systemImage: account.isEnabled ? "pause.circle" : "play.circle"
                    )
                }
                .tint(account.isEnabled ? .orange : .green)
                Button(role: .destructive) {
                    requestRemoval(rowID)
                } label: {
                    Label("Remove Account", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if let account {
                Button {
                    Task { await model.setAccountEnabled(rowID, !account.isEnabled) }
                } label: {
                    Label(
                        account.isEnabled ? "Disable Account" : "Enable Account",
                        systemImage: account.isEnabled ? "pause.circle" : "play.circle"
                    )
                }
                Button(role: .destructive) {
                    requestRemoval(rowID)
                } label: {
                    Label("Remove Account", systemImage: "trash")
                }
            }
        }
            if expandedRowID == rowID {
                accountEditorRow(account)
            }
        }
    }

    private func accountEditorRow(_ account: AccountConfig?) -> some View {
        let rowID = account?.id ?? Self.blankAccountID

        return AccountEditorSheet(
            model: model,
            configuration: account,
            onCancel: { closeEditor(rowID) },
            onSaved: { closeEditor(rowID) },
            onRemove: account == nil ? nil : { requestRemoval(rowID) }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .id("\(rowID.rawValue)-editor")
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
            Button("Add account…") {
                addBlankAccount()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd || isValidating)
            .accessibilityIdentifier(UIIdentifier.accountsEmptyAdd)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }



    private func addBlankAccount() {
        guard canAdd, !isValidating else { return }
        withAnimation(reduceMotion ? nil : MailMotion.expand) {
            expandedRowID = Self.blankAccountID
        }
    }

    private func toggleExpansion(for id: AccountID) {
        let next = AccountsListPolicy.nextExpandedID(
            current: expandedRowID,
            requested: id
        )
        withAnimation(reduceMotion ? nil : (next == nil ? MailMotion.accountEditorCollapse : MailMotion.expand)) {
            expandedRowID = next
        }
    }

    private func closeEditor(_ id: AccountID) {
        withAnimation(reduceMotion ? nil : MailMotion.accountEditorCollapse) {
            if expandedRowID == id {
                expandedRowID = nil
            }
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
            try await model.removeAccount(id)
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
                Text(account.map { AccountTitlePolicy.title(for: $0) ?? $0.emailAddress } ?? "New account")
                    .font(.headline)
                    .lineLimit(1)

                Text(email)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(UIIdentifier.accountsRowEmail)
                // A disabled account is explained by its dimmed row and red
                // dot alone; the "no account" state message belongs to the
                // empty pane, not to a row the user switched off.
                if let account, account.isEnabled,
                   case .error(let message) = AccountsListPolicy.status(for: state) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary?.text ?? "New account")
    }

    private var statusColor: Color {
        guard let account else { return .secondary }
        guard account.isEnabled else { return .red }
        switch AccountsListPolicy.status(for: state) {
        case .active: return .green
        case .validating: return .orange
        case .error: return .red
        }
    }


}
