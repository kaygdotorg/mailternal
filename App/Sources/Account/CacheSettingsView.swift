import SwiftUI
import MailternalInterfaces

struct CacheSettingsView: View {
    @Bindable var model: AppModel

    private var foldersByAccount: [AccountID: [FolderSummary]] {
        CacheTreePolicy.foldersByAccount(model.folders)
    }

    private var accounts: [AccountConfig] {
        AccountsListPolicy.sorted(model.accountConfigs)
    }

    private var accountIDs: [AccountID] {
        let knownIDs = accounts.map(\.id)
        let unknownIDs = foldersByAccount.keys
            .filter { !knownIDs.contains($0) }
            .sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
        return knownIDs + unknownIDs
    }

    @State private var collapsedAccountIDs: Set<AccountID> = []


    var body: some View {
        Form {
            Section {
                CacheTriStateToggle(
                    title: "All",
                    state: CacheTreePolicy.allState(for: foldersByAccount),
                    onToggle: {
                        let state = CacheTreePolicy.allState(for: foldersByAccount)
                        setKeepLocally(
                            CacheTreePolicy.desiredValue(for: state),
                            folderIDs: CacheTreePolicy.folderUpdates(
                                for: state,
                                foldersByAccount: foldersByAccount
                            ).keys
                        )
                    }
                )
                .accessibilityIdentifier(UIIdentifier.cacheAll)
            } footer: {
                Text("Choose which folders retain mail on this Mac.")
            }
            Section("Accounts") {
                if accountIDs.isEmpty {
                    Text("No account configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accountIDs, id: \.self) { accountID in
                        accountNode(accountID)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(UIIdentifier.cacheTree)
    }

    @ViewBuilder
    private func accountNode(_ accountID: AccountID) -> some View {
        let folders = foldersByAccount[accountID] ?? []
        let config = model.accountConfigs.first { $0.id == accountID }
        let title = AccountTitlePolicy.title(for: config) ?? accountID.rawValue
        let isExpanded = !collapsedAccountIDs.contains(accountID)

        VStack(alignment: .leading, spacing: CacheSettingsLayout.accountToFoldersGap) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    withAnimation(MailMotion.expand) {
                        if isExpanded {
                            collapsedAccountIDs.insert(accountID)
                        } else {
                            collapsedAccountIDs.remove(accountID)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")

                CacheTriStateToggle(
                    title: nil,
                    state: CacheTreePolicy.accountState(for: folders),
                    onToggle: {
                        let state = CacheTreePolicy.accountState(for: folders)
                        setKeepLocally(
                            CacheTreePolicy.desiredValue(for: state),
                            folderIDs: CacheTreePolicy.folderUpdates(for: state, folders: folders).keys
                        )
                    }
                )
                .accessibilityIdentifier(UIIdentifier.cacheAccount(accountID.rawValue))
                .accessibilityLabel("Enable all folders under \(title)")

                VStack(alignment: .leading, spacing: CacheSettingsLayout.titleSubtitleGap) {
                    Text(title)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let config {
                    Text(config.emailAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 80, maxWidth: 180, alignment: .trailing)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: CacheSettingsLayout.folderRowGap) {
                    ForEach(folders) { folder in
                        Toggle(isOn: Binding(
                            get: { folder.keepLocally },
                            set: { keep in setKeepLocally(keep, folderIDs: [folder.id]) }
                        )) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: CacheSettingsLayout.titleSubtitleGap) {
                                    Text(folder.name)
                                        .lineLimit(1)
                                    Text(CacheTreePolicy.countCaption(for: folder))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 24)
                        .padding(.vertical, CacheSettingsLayout.folderRowInset)
                        .accessibilityIdentifier(UIIdentifier.cacheFolder(String(folder.id.rawValue)))
                        .accessibilityValue(folder.keepLocally ? "Kept locally" : "Not kept locally")
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(MailMotion.expand, value: isExpanded)
    }

    private func setKeepLocally(_ keep: Bool, folderIDs: some Collection<FolderID>) {
        let ids = Array(folderIDs).sorted { $0.rawValue < $1.rawValue }
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            for id in ids {
                do {
                    try await model.facade.setKeepLocally(keep, for: id)
                } catch {
                    model.toasts.post(
                        title: "Couldn’t update cache setting",
                        detail: error.localizedDescription,
                        severity: .error
                    )
                    break
                }
            }
        }
    }
}

private struct CacheTriStateToggle: View {
    let title: String?
    let state: CacheTreePolicy.State
    let onToggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { state == .checked },
            set: { _ in onToggle() }
        ) {
            if let title {
                Text(title)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityValue(accessibilityValue)
        .overlay(alignment: .leading) {
            if state == .mixed {
                Image(systemName: "minus.square.fill")
                    .foregroundStyle(.tint)
                    .allowsHitTesting(false)
            }
        }
    }


    private var accessibilityValue: String {
        switch state {
        case .checked: "Checked"
        case .mixed: "Mixed"
        case .unchecked: "Unchecked"
        }
    }
}

/// Cache pane rhythm: rows need room to breathe between title/subtitle and
/// between list items (user review 2026-09-04).
enum CacheSettingsLayout {
    static let titleSubtitleGap: CGFloat = 4
    static let folderRowGap: CGFloat = 6
    static let folderRowInset: CGFloat = 4
    static let accountToFoldersGap: CGFloat = 10
}
