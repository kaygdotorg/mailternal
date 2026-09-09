import Foundation
import SwiftUI
import MailternalWorkspace

/// Native Settings → Sync controls for Apple-device workspace metadata and account transfer.
/// Workspace synchronization excludes mail content and credentials; Pair Device opens
/// the separate explicit account-transfer flow.
struct WorkspaceSyncSettingsView: View {
    @Bindable var model: AppModel
    let coordinator: MacWorkspaceCoordinator
    let onPairDevice: () -> Void
    @Bindable var controller: WorkspaceSyncController
    @State private var conflictCategory: WorkspaceSyncCategory?
    @State private var actionError: String?

    init(model: AppModel, onPairDevice: @escaping () -> Void) {
        self.model = model
        self.coordinator = model.workspaceSync
        self.onPairDevice = onPairDevice
        self._controller = Bindable(wrappedValue: model.workspaceSync.controller)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Sync Apple-device workspace", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in Task { await setMaster(enabled) } }
                ))
                Text("Mailbox content and passwords stay in the mail runtime and Keychain. This syncs layout, appearance, gestures, and reading handoff only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Account transfer") {
                Button(action: onPairDevice) {
                    Label("Pair Device", systemImage: "qrcode")
                }
                Text("Transfer selected accounts and optional settings with another device. This is independent of ongoing workspace synchronization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.isEnabled {
                Section("Categories") {
                    ForEach(WorkspaceSyncCategory.allCases, id: \.self) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { controller.enabledCategories.contains(category) },
                            set: { enabled in Task { await setCategory(category, enabled: enabled) } }
                        ))
                        .disabled(controller.pendingConflicts.contains(category))
                    }
                }
            }

            Section("Status") {
                if let lastSync = controller.lastSync {
                    Label("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud")
                        .foregroundStyle(.secondary)
                } else if controller.isEnabled {
                    Label("Not synced yet", systemImage: "icloud")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Sync is off; local and synced settings are preserved.", systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
                if let error = controller.lastError ?? coordinator.actionError ?? actionError {
                    Label(error, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !controller.pendingConflicts.isEmpty {
                Section("Choose settings") {
                    ForEach(controller.pendingConflicts.sorted { $0.rawValue < $1.rawValue }, id: \.self) { category in
                        HStack {
                            Label("Choose settings for \(category.title)", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            Button("Choose") { conflictCategory = category }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { coordinator.applyWorkspaceValues() }
        .onChange(of: controller.values) { _, _ in coordinator.applyWorkspaceValues() }
        .confirmationDialog("Workspace settings", isPresented: Binding(
            get: { conflictCategory != nil },
            set: { if !$0 { conflictCategory = nil } }
        )) {
            if let category = conflictCategory {
                Button("Use this device’s settings") { Task { await resolve(category, using: .local) } }
                Button("Use synced settings") { Task { await resolve(category, using: .cloud) } }
            }
            Button("Cancel", role: .cancel) { conflictCategory = nil }
        } message: {
            Text("Your local and synced workspace settings differ.")
        }
    }

    private func setMaster(_ enabled: Bool) async {
        do {
            try await model.dispatch(.setWorkspaceSync(enabled))
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func setCategory(_ category: WorkspaceSyncCategory, enabled: Bool) async {
        do {
            try await model.dispatch(.setWorkspaceSyncCategory(category, enabled))
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resolve(_ category: WorkspaceSyncCategory, using choice: WorkspaceSyncChoice) async {
        do {
            try await model.dispatch(.resolveWorkspaceSyncConflict(category, choice))
            conflictCategory = nil
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private extension WorkspaceSyncCategory {
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .appearance: "Appearance"
        case .actions: "Actions"
        }
    }
}
