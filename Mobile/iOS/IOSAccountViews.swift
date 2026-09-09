import Foundation
import SwiftUI
import MailternalInterfaces
import MailternalAutomation
struct IOSAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: IOSAppState
    let account: AccountConfig?

    @State private var displayName = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var security: IMAPEndpoint.Security = .implicitTLS
    @State private var provider = "Generic IMAP"
    @State private var syncParticipation = false
    @State private var validationMessage: String?
    @State private var isSaving = false
    @State private var generatedAccountID: AccountID?
    @State private var smtpSettings = SMTPSettingsDraft()
    @State private var accountWasSaved = false

    private var isEditing: Bool { account != nil || accountWasSaved }
    private var presets: [IMAPProviderPreset] { ProviderPresets.all }
    private var selectedPreset: IMAPProviderPreset? {
        presets.first(where: { $0.name == provider })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Provider", selection: Binding(
                        get: { provider },
                        set: { applyProvider($0) }
                    )) {
                        Text("Generic IMAP").tag("Generic IMAP")
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    if let preset = selectedPreset {
                        if !preset.usernameHint.isEmpty {
                            Text("Username: \(preset.usernameHint)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !preset.guidance.isEmpty {
                            guidanceView(for: preset)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    TextField("Display name", text: $displayName)
                        .textContentType(.organizationName)
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("IMAP") {
                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    Picker("Security", selection: $security) {
                        Text("Implicit TLS").tag(IMAPEndpoint.Security.implicitTLS)
                        Text("STARTTLS (required)").tag(IMAPEndpoint.Security.startTLS)
                    }
                    SecureField("Password (saved in Keychain)", text: $password)
                        .textContentType(.password)
                    Text("Passwords never enter Mailternal’s database or UI-state files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SMTPAccountFields(draft: $smtpSettings)
                Section("Apple-device workspace") {
                    Toggle("Sync layout and appearance with iCloud", isOn: $syncParticipation)
                    Text("Mail content and passwords stay on this device. You can change this later in Settings → Sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let validationMessage {
                    Section { Label(validationMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "Add Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .onAppear(perform: loadAccount)
        }
        .disabled(state.isApplyingRemoteNavigation)
        .interactiveDismissDisabled(isSaving)
    }
    private func loadAccount() {
        syncParticipation = state.workspace.isEnabled
        guard let account else { return }
        displayName = account.displayName
        email = account.emailAddress
        username = account.username
        host = account.imap.host
        port = String(account.imap.port)
        security = account.imap.security
        smtpSettings.load(account.smtp)
        provider = presets.first(where: {
            $0.host == host && $0.port == account.imap.port && $0.security == account.imap.security
        })?.name ?? "Generic IMAP"
        syncParticipation = state.workspace.isEnabled
    }

    private func applyProvider(_ value: String) {
        provider = value
        guard let preset = presets.first(where: { $0.name == value }), !preset.host.isEmpty else { return }
        host = preset.host
        port = String(preset.port)
        security = preset.security
        if username.isEmpty, !email.isEmpty { username = email }
        smtpSettings.apply(preset, username: username)
    }

    @ViewBuilder
    private func guidanceView(for preset: IMAPProviderPreset) -> some View {
        let appPasswordHost = "myaccount.google.com/apppasswords"
        if preset.guidance.contains(appPasswordHost) {
            let guidance = preset.guidance.replacingOccurrences(
                of: appPasswordHost,
                with: "[\(appPasswordHost)](https://\(appPasswordHost))"
            )
            Text(.init(guidance))
        } else {
            Text(preset.guidance)
        }
    }

    private func save() async {
        if let selected = selectedPreset, selected.host != host {
            applyProvider(provider)
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@") else { validationMessage = "Enter a valid email address."; return }
        guard !trimmedHost.isEmpty else { validationMessage = "Enter an IMAP host."; return }
        guard let parsedPort = Int(port), (1...65535).contains(parsedPort) else {
            validationMessage = "Enter a port from 1 to 65535."
            return
        }
        if account == nil && !accountWasSaved && password.isEmpty {
            validationMessage = "Enter the account password."
            return
        }
        let id: AccountID
        if let account {
            id = account.id
        } else if let generatedAccountID {
            id = generatedAccountID
        } else {
            let newID = AccountID(rawValue: UUID().uuidString.lowercased())
            generatedAccountID = newID
            id = newID
        }
        let existing = state.facade.accounts.first { $0.id == id } ?? account
        let outgoing: SMTPConfiguration?
        do {
            outgoing = try smtpSettings.configuration(
                existing: existing?.smtp,
                accountUsername: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedEmail : username
            )
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        let config = AccountConfig(
            id: id,
            accountLinkID: existing?.accountLinkID ?? .random(),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            emailAddress: trimmedEmail,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedEmail : username,
            imap: IMAPEndpoint(host: trimmedHost, port: parsedPort, security: security),
            smtp: existing?.smtp,
            isEnabled: existing?.isEnabled ?? true
        )
        isSaving = true
        let didSave = await state.updateAccount(
            config, password: password.isEmpty ? nil : password, isNew: account == nil && !accountWasSaved
        )
        if didSave {
            accountWasSaved = true
            password = ""
            do {
                if outgoing != existing?.smtp || smtpSettings.replacementPassword != nil {
                    _ = try await state.dispatcher.submit(
                        .configureSMTP(id, outgoing, hasPassword: smtpSettings.replacementPassword != nil),
                        secret: smtpSettings.replacementPassword
                    )
                }
                smtpSettings.password = ""
            } catch {
                validationMessage = "Account saved, but outgoing settings could not be saved: \(error.localizedDescription)"
                isSaving = false
                return
            }
            do {
                try await state.setWorkspaceParticipation(syncParticipation)
                dismiss()
            } catch {
                state.errorMessage = "Account saved, but workspace sync could not be updated: \(error.localizedDescription)"
                dismiss()
            }
        }
        isSaving = false
    }
}

/// A searchable section index by default, with the same controls available inline
/// in Flat View. The layout preference uses the shell's persisted appearance state.
struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Bindable var state: IOSAppState
    @State private var searchText = ""
    @State private var editingAccount: AccountConfig?
    @State private var addAccount = false
    @State private var pendingRemoval: AccountConfig?
    @State private var isPairingPresented = false

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [IOSSettingsSearchItem] {
        IOSSettingsSearchItem.all.filter { $0.matches(query) }
    }

    private var rowBackground: Color {
        Color(uiColor: .secondarySystemGroupedBackground)
            .opacity(reduceTransparency ? 1 : 0.45)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: Binding(
                        get: { state.settingsFlatView },
                        set: { flat in
                            state.settingsFlatView = flat
                            state.persistUIState()
                            Task { await state.publishLocalAppearance() }
                        }
                    )) {
                        Text("Flat View")
                    }
                    .toggleStyle(IOSSettingsCheckboxStyle())
                    .accessibilityIdentifier("settings-flat-view")
                }
                .listRowBackground(rowBackground)

                if !query.isEmpty {
                    searchResultsSection
                } else if state.settingsFlatView {
                    ForEach(IOSSettingsSection.allCases) { section in
                        settingsSection(section)
                    }
                } else {
                    Section {
                        ForEach(IOSSettingsSection.allCases) { section in
                            NavigationLink(value: IOSSettingsDestination(section: section)) {
                                Label(section.title, systemImage: section.systemImage)
                            }
                            .accessibilityIdentifier("settings-section-\(section.rawValue)")
                        }
                    }
                    .listRowBackground(rowBackground)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search settings"
            )
            .navigationDestination(for: IOSSettingsDestination.self) { destination in
                ScrollViewReader { proxy in
                    List {
                        settingsSection(destination.section)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .navigationTitle(destination.section.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .task(id: destination) {
                        guard let anchor = destination.anchor else { return }
                        await Task.yield()
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { state.persistUIState(); dismiss() }
                }
            }
        }
        .presentationBackground {
            if reduceTransparency {
                Color(uiColor: .systemGroupedBackground)
            } else {
                // One glass presentation surface, with semantic backing for text
                // contrast; individual settings rows do not stack glass effects.
                Color(uiColor: .systemBackground).opacity(0.2)
                    .glassEffect(.clear, in: Rectangle())
            }
        }
        .disabled(state.isApplyingRemoteNavigation)
        .sheet(isPresented: $addAccount) {
            IOSAccountEditorView(state: state, account: nil)
        }
        .sheet(isPresented: $isPairingPresented) {
            PairingView(
                accounts: state.accounts,
                makeBundle: { accountIDs, includeSettings in
                    try await state.makePairingBundle(accountIDs, includeSettings: includeSettings)
                },
                importBundle: { bundle, selectedIDs, replaceExisting, importSettings in
                    try await state.importPairingBundle(
                        bundle,
                        selectedAccountIDs: selectedIDs,
                        replaceExisting: replaceExisting,
                        importSettings: importSettings
                    )
                },
                bridge: state.pairingAutomation,
                onCommand: state.performPairingAction
            )
        }
        .sheet(isPresented: Binding(
            get: { editingAccount != nil },
            set: { if !$0 { editingAccount = nil } }
        )) {
            if let editingAccount {
                IOSAccountEditorView(state: state, account: editingAccount)
            }
        }
        .confirmationDialog("Remove account?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            if let account = pendingRemoval {
                Button("Remove \(account.emailAddress)", role: .destructive) {
                    Task { await state.removeAccount(account) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Mail and its local cache for this account will be removed. The saved password will be deleted from Keychain.")
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        Section("Results") {
            if searchResults.isEmpty {
                // Flat View is always directly available just above the results.
                if !IOSSettingsSearchItem.matches(query, in: "Flat View checkbox section settings layout") {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                ForEach(searchResults) { item in
                    NavigationLink(value: IOSSettingsDestination(section: item.section, anchor: item.anchor)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.section.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings-result-\(item.id)")
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    private func settingsSection(_ section: IOSSettingsSection) -> some View {
        Section(section.title) {
            sectionContents(section)
        }
        .listRowBackground(rowBackground)
    }

    @ViewBuilder
    private func sectionContents(_ section: IOSSettingsSection) -> some View {
        switch section {
        case .accounts:
            if state.accounts.isEmpty {
                ContentUnavailableView(
                    "No accounts",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add an IMAP account to begin.")
                )
            }
            ForEach(state.accounts, id: \.id) { account in
                IOSAccountSettingsRow(
                    state: state,
                    account: account,
                    onEdit: { editingAccount = account },
                    onRemove: { pendingRemoval = account }
                )
            }
            Button { addAccount = true } label: {
                Label("Add Account", systemImage: "plus")
            }
            .id("accounts.add")
        case .appearance:
            Toggle("Sender icons", isOn: Binding(
                get: { state.showSenderIcons },
                set: { value in
                    state.showSenderIcons = value
                    state.persistUIState()
                    Task { await state.publishLocalAppearance() }
                }
            ))
            .id("appearance.sender-icons")
            Picker("Email reading mode", selection: Binding(
                get: { state.readingMode },
                set: { value in
                    state.readingMode = value
                    state.persistUIState()
                    Task { await state.publishLocalAppearance() }
                }
            )) {
                ForEach(IOSReadingMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .id("appearance.reading-mode")
        case .gestures:
            Text("Leading swipe")
                .font(.headline)
                .id("gestures.leading")
            IOSSwipeActionSettings(state: state, edge: .leading, limit: ActionSettings.leadingSwipeLimit)
            Text("Trailing swipe")
                .font(.headline)
                .id("gestures.trailing")
            IOSSwipeActionSettings(state: state, edge: .trailing, limit: ActionSettings.trailingSwipeLimit)
        case .sync:
            Button { isPairingPresented = true } label: {
                Label("Pair Device", systemImage: "qrcode")
            }
            .id("sync.pair")
            .accessibilityIdentifier("settings-pair-device")
            Text("Transfer selected accounts and optional settings to another trusted device. Pairing does not require iCloud sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
            IOSWorkspaceSyncView(state: state)
        case .mailState:
            LabeledContent(
                "Accounts",
                value: state.accounts.isEmpty ? "None configured" : "\(state.enabledAccounts.count) enabled"
            )
            .id("mail-state.accounts")
            LabeledContent("Queued changes", value: state.pendingMutationCount.formatted())
                .id("mail-state.queued")
        case .pendingActions:
            if state.reviewRecords.isEmpty {
                Label("No pending actions", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.reviewRecords) { record in
                    IOSPendingCommandRow(state: state, record: record)
                }
                .id(state.commandRevision)
            }
        }
    }
}

private enum IOSSettingsSection: String, CaseIterable, Identifiable {
    case accounts, appearance, gestures, sync, mailState, pendingActions

    var id: Self { self }

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .appearance: "Appearance"
        case .gestures: "Gestures"
        case .sync: "Sync"
        case .mailState: "Mail state"
        case .pendingActions: "Pending actions"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "at"
        case .appearance: "paintbrush"
        case .gestures: "hand.draw"
        case .sync: "icloud"
        case .mailState: "envelope"
        case .pendingActions: "clock.arrow.circlepath"
        }
    }
}

private struct IOSSettingsDestination: Hashable {
    let section: IOSSettingsSection
    var anchor: String? = nil
}

/// Search indexes labels and setting vocabulary, never passwords or mail content.
/// Results navigate to the existing controls rather than maintaining duplicate forms.
private struct IOSSettingsSearchItem: Identifiable {
    let section: IOSSettingsSection
    let title: String
    let anchor: String?
    let keywords: String

    var id: String { anchor ?? section.rawValue }

    func matches(_ query: String) -> Bool {
        Self.matches(query, in: "\(section.title) \(title) \(keywords)")
    }

    static func matches(_ query: String, in text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }

    static let all: [Self] = [
        .init(section: .accounts, title: "Account connection settings", anchor: nil,
              keywords: "edit email address display name provider username password IMAP server host port security TLS enable disable remove"),
        .init(section: .accounts, title: "Add Account", anchor: "accounts.add", keywords: "new setup provider"),
        .init(section: .appearance, title: "Sender icons", anchor: "appearance.sender-icons", keywords: "avatar monogram"),
        .init(section: .appearance, title: "Email reading mode", anchor: "appearance.reading-mode", keywords: "original dark theme"),
        .init(section: .gestures, title: "Leading swipe actions", anchor: "gestures.leading",
              keywords: "archive delete trash read unread flag unflag move none left right"),
        .init(section: .gestures, title: "Trailing swipe actions", anchor: "gestures.trailing",
              keywords: "archive delete trash read unread flag unflag move none left right"),
        .init(section: .sync, title: "Pair Device", anchor: "sync.pair",
              keywords: "pairing QR code scan camera transfer accounts credentials export import encrypted file passphrase"),
        .init(section: .sync, title: "Sync Apple-device workspace", anchor: "sync.master", keywords: "iCloud enable disable"),
        .init(section: .sync, title: "Workspace sync", anchor: "sync.workspace", keywords: "category navigation layout"),
        .init(section: .sync, title: "Appearance sync", anchor: "sync.appearance", keywords: "category theme icons"),
        .init(section: .sync, title: "Actions sync", anchor: "sync.actions", keywords: "category gestures swipes"),
        .init(section: .sync, title: "Last synced", anchor: "sync.status", keywords: "status error conflict choose local cloud"),
        .init(section: .sync, title: "Apply sort to", anchor: "sync.list-scope", keywords: "message list all folders this folder"),
        .init(section: .sync, title: "Sort by", anchor: "sync.list-field", keywords: "message list date sender subject read status flagged attachments"),
        .init(section: .sync, title: "Order", anchor: "sync.list-order", keywords: "sort ascending descending"),
        .init(section: .sync, title: "Effective for this folder", anchor: "sync.list-effective", keywords: "message list sort"),
        .init(section: .sync, title: "Reset folder sort", anchor: "sync.list-reset", keywords: "message list all folders defaults"),
        .init(section: .mailState, title: "Enabled accounts", anchor: "mail-state.accounts", keywords: "status configured"),
        .init(section: .mailState, title: "Queued changes", anchor: "mail-state.queued", keywords: "pending count mutations"),
        .init(section: .pendingActions, title: "Review pending actions", anchor: nil, keywords: "retry discard failed password error"),
    ]
}

/// iOS has no CheckboxToggleStyle. Preserve native Toggle accessibility while
/// drawing the requested checkbox with SF Symbols and a full-width touch target.
private struct IOSSettingsCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                configuration.label
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: Binding(
                get: { configuration.isOn },
                set: { configuration.isOn = $0 }
            )) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}

private struct IOSSwipeActionSettings: View {
    @Bindable var state: IOSAppState
    let edge: SwipeEdge
    let limit: Int

    var body: some View {
        ForEach(0..<limit, id: \.self) { index in
            Picker("Action \(index + 1)", selection: Binding<SwipeActionKind?>(
                get: {
                    let actions = state.actions.swipeActions(for: edge)
                    return actions.indices.contains(index) ? actions[index] : nil
                },
                set: { action in
                    state.actions.setSwipeAction(action, at: index, edge: edge)
                    Task { await state.publishLocalActions() }
                }
            )) {
                Text("None").tag(nil as SwipeActionKind?)
                ForEach(SwipeActionKind.allCases) { action in
                    Text(action.title).tag(Optional(action))
                }
            }
        }
}
}

private struct IOSPendingCommandRow: View {
    @Bindable var state: IOSAppState
    let record: IOSCommandDispatcher.Record
    @State private var password = ""
    private var reviewMessage: String {
        switch record.command {
        case .sendDraft, .retrySubmission, .cancelSubmission:
            "Review Outbox before retrying; another submission could duplicate delivery."
        default:
            "This action may already have been applied. Review the affected state before retrying."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.title)
                .font(.subheadline.weight(.semibold))
            if let error = record.errorDescription {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.command.requiresPassword {
                SecureField("Account password", text: $password)
                    .textContentType(.password)
            }
            if record.status == .needsReview {
                Text(reviewMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                if record.status == .failed {
                    Button("Retry") {
                        Task {
                            await state.retry(
                                record,
                                password: record.command.requiresPassword ? password : nil
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(record.command.requiresLivePairing || (record.command.requiresPassword && password.isEmpty))
                }
                Button("Discard", role: .destructive) { state.discard(record) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct IOSAccountSettingsRow: View {
    @Bindable var state: IOSAppState
    let account: AccountConfig
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(account.isEnabled ? .green : .red).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName.isEmpty ? account.emailAddress : account.displayName)
                    .font(.body.weight(.semibold))
                Text(account.emailAddress).font(.caption).foregroundStyle(.secondary)
                if let status = state.accountStateDescription(account) {
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Menu {
                Button(account.isEnabled ? "Disable" : "Enable") {
                    Task { await state.setAccountEnabled(account, enabled: !account.isEnabled) }
                }
                Button("Edit") { onEdit() }
                Button("Remove", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Account actions")
        }
        .swipeActions(edge: .trailing) {
            Button(account.isEnabled ? "Disable" : "Enable") {
                Task { await state.setAccountEnabled(account, enabled: !account.isEnabled) }
            }
            .tint(account.isEnabled ? .orange : .green)
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "trash")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}
