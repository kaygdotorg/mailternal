import Foundation
import SwiftUI
import MailternalInterfaces
import MailternalWorkspace
/// Settings surface for the shared iCloud workspace controller. Mail content is
/// never written here; only appearance/actions/workspace metadata participate.
struct IOSWorkspaceSyncView: View {
    @Bindable var state: IOSAppState
    @Bindable var controller: WorkspaceSyncController
    @State private var conflictCategory: WorkspaceSyncCategory?
    @State private var actionError: String?

    init(state: IOSAppState) {
        self.state = state
        self._controller = Bindable(wrappedValue: state.workspace)
    }

    var body: some View {
        Group {
            Toggle("Sync Apple-device workspace", isOn: Binding(
                get: { controller.isEnabled },
                set: { enabled in Task { await setMaster(enabled) } }
            ))
            .id("sync.master")
            Text("Mailbox content and passwords stay in the mail runtime and Keychain. This syncs layout and appearance only.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(WorkspaceSyncCategory.allCases, id: \.self) { category in
                Toggle(category.title, isOn: Binding(
                    get: { controller.enabledCategories.contains(category) },
                    set: { enabled in Task { await setCategory(category, enabled: enabled) } }
                ))
                .disabled(!controller.isEnabled || controller.pendingConflicts.contains(category))
                .id("sync.\(category.rawValue)")
            }
            if let lastSync = controller.lastSync {
                Label("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .id("sync.status")
            } else {
                Label("Not synced yet", systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .id("sync.status")
            }
            if let error = controller.lastError ?? actionError {
                Label(error, systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !controller.pendingConflicts.isEmpty {
                ForEach(Array(controller.pendingConflicts), id: \.self) { category in
                    HStack {
                        Label("Choose settings for \(category.title)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                        Spacer()
                        Button("Choose") { conflictCategory = category }
                            .buttonStyle(.bordered)
                    }
                }
            }
            Group {
                Text("Message list")
                    .font(.headline)
                Picker(
                    "Apply sort to",
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
                .id("sync.list-scope")
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
                .id("sync.list-field")
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
                .id("sync.list-order")
                LabeledContent("Effective for this folder", value: state.effectiveListSort.title)
                    .font(.caption)
                    .id("sync.list-effective")
                Button("Reset \(state.listSettingsScopeTitle) sort", role: .destructive) {
                    Task { await state.resetListSort() }
                }
                .id("sync.list-reset")
            }
        }
        .onAppear { state.applyWorkspaceValues() }
        .onChange(of: controller.values) { _, _ in state.applyWorkspaceValues() }
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
        do { try await controller.setEnabled(enabled) }
        catch { actionError = error.localizedDescription }
    }
    private func setCategory(_ category: WorkspaceSyncCategory, enabled: Bool) async {
        do { try await controller.setCategory(category, enabled: enabled) }
        catch { actionError = error.localizedDescription }
    }

    private func resolve(_ category: WorkspaceSyncCategory, using choice: WorkspaceSyncChoice) async {
        do { try await controller.resolve(category, using: choice) }
        catch { actionError = error.localizedDescription }
    }

}

private extension WorkspaceSyncValue {
    var displayValue: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "On" : "Off"
        case .integer(let value): return String(value)
        case .number(let value): return value.formatted()
        case .data(let value): return "\(value.count) bytes"
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
