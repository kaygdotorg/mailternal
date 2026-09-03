import SwiftUI
import MailternalInterfaces

struct CacheSettingsView: View {
    @Bindable var model: AppModel

    private var foldersByAccount: [AccountID: [FolderSummary]] {
        guard let account = model.accountConfig else { return [:] }
        return [account.id: model.folders.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }]
    }

    private var accountIDs: [AccountID] {
        foldersByAccount.keys.sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
    }

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
        CacheTriStateToggle(
            title: accountTitle(for: accountID),
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

        ForEach(folders) { folder in
            Toggle(isOn: Binding(
                get: { folder.keepLocally },
                set: { keep in setKeepLocally(keep, folderIDs: [folder.id]) }
            )) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
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
            .accessibilityIdentifier(UIIdentifier.cacheFolder(String(folder.id.rawValue)))
            .accessibilityValue(folder.keepLocally ? "Kept locally" : "Not kept locally")
        }
    }

    private func accountTitle(for id: AccountID) -> String {
        if let config = model.accountConfig, config.id == id {
            return AccountTitlePolicy.title(for: config) ?? config.emailAddress
        }
        return id.rawValue
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
    let title: String
    let state: CacheTreePolicy.State
    let onToggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(
            get: { state == .checked },
            set: { _ in onToggle() }
        )) {
            Text(title)
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
