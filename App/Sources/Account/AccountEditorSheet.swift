import SwiftUI
import MailternalInterfaces

struct AccountEditorSheet: View {
    @Bindable var model: AppModel
    let configuration: AccountConfig?
    @State private var displayName = ""
    let onCancel: () -> Void
    let onSaved: () -> Void
    let onRemove: (() -> Void)?

    @State private var presetName = "Generic IMAP"
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var security: IMAPEndpoint.Security = .implicitTLS
    @State private var fieldError: String?
    @State private var isSaving = false
    @State private var smtpSettings = SMTPSettingsDraft()
    @State private var generatedAccountID: AccountID?
    @State private var accountWasSaved = false

    private var isEditing: Bool { configuration != nil || accountWasSaved }
    private var presets: [IMAPProviderPreset] { ProviderPresets.all }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    Picker("Preset", selection: Binding(
                        get: { presetName },
                        set: { presetName = $0; applyPreset(named: $0) }
                    )) {
                        Text("Generic IMAP").tag("Generic IMAP")
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    .accessibilityIdentifier(UIIdentifier.accountEditorPreset)

                    if let preset = presets.first(where: { $0.name == presetName }), !preset.guidance.isEmpty {
                        guidanceView(for: preset)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Account") {
                    TextField("Account name", text: $displayName)
                        .accessibilityIdentifier(UIIdentifier.accountEditorDisplayName)
                    if let configuration {
                        // Enablement is its own persisted command; Save Changes
                        // updates account details without changing this state.
                        Toggle("Enable this account", isOn: Binding(
                            get: { configuration.isEnabled },
                            set: { enabled in
                                Task { await model.setAccountEnabled(configuration.id, enabled) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                    TextField("Email Address", text: $email)
                        .textContentType(.username)
                        .accessibilityIdentifier(UIIdentifier.accountEditorEmail)
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .accessibilityIdentifier(UIIdentifier.accountEditorUsername)
                    SecureField(
                        "Password",
                        text: $password,
                        prompt: isEditing ? Text("unchanged") : nil
                    )
                    .textContentType(.password)
                    .accessibilityIdentifier(UIIdentifier.accountEditorPassword)
                }

                Section("IMAP") {
                    TextField("Host", text: $host)
                        .accessibilityIdentifier(UIIdentifier.accountEditorHost)
                    TextField("Port", text: $port)
                        .accessibilityIdentifier(UIIdentifier.accountEditorPort)
                    Picker("Security", selection: Binding(
                        get: { security.rawValue },
                        set: { security = IMAPEndpoint.Security(rawValue: $0) ?? .implicitTLS }
                    )) {
                        Text("SSL/TLS").tag(IMAPEndpoint.Security.implicitTLS.rawValue)
                        Text("STARTTLS").tag(IMAPEndpoint.Security.startTLS.rawValue)
                    }
                    .accessibilityIdentifier(UIIdentifier.accountEditorSecurity)
                    Text("Transport is implicit TLS or mandatory STARTTLS. There is no insecure fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SMTPAccountFields(draft: $smtpSettings)


                if let fieldError {
                    Section {
                        Label(fieldError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(isSaving || isValidating)

            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(UIIdentifier.accountEditorCancel)
                    .disabled(isSaving)

                if let onRemove {
                    Button("Remove", role: .destructive) { onRemove() }
                        .accessibilityIdentifier(UIIdentifier.accountEditorRemove)
                        .disabled(isSaving || isValidating)
                }

                Spacer()

                Button(isSaving ? "Saving…" : isEditing ? "Save Changes" : "Add Account") {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier(UIIdentifier.accountEditorSave)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .onExitCommand { if !isSaving { onCancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(UIIdentifier.accountEditorSheet)
        .onAppear(perform: loadFields)
    }

    private var isValidating: Bool {
        if case .validating = model.accountState { return true }
        return false
    }

    private var canSubmit: Bool {
        guard !isValidating else { return false }
        let hasPassword = isEditing || !password.isEmpty
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasPassword
            && Int(port) != nil
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

    private func applyPreset(named name: String) {
        guard let preset = presets.first(where: { $0.name == name }) else { return }
        host = preset.host
        port = String(preset.port)
        security = preset.security
        if username.isEmpty { username = email }
        smtpSettings.apply(preset, username: username)
    }

    private func loadFields() {
        guard let config = configuration else {
            applyPreset(named: presetName)
            return
        }
        presetName = presets.first(where: {
            $0.host == config.imap.host && $0.port == config.imap.port && $0.security == config.imap.security
        })?.name ?? "Generic IMAP"
        displayName = config.displayName
        email = config.emailAddress
        username = config.username
        host = config.imap.host
        port = String(config.imap.port)
        security = config.imap.security
        smtpSettings.load(config.smtp)
        password = ""
        fieldError = nil
    }

    private func submit() async {
        fieldError = nil
        guard let portNumber = Int(port), (1...65_535).contains(portNumber) else {
            fieldError = "Enter a port between 1 and 65535."
            return
        }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fieldError = "Enter an IMAP host."
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fieldError = "Enter a username."
            return
        }
        let hasPassword = isEditing || !password.isEmpty
        guard hasPassword else {
            fieldError = "Enter a password."
            return
        }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = AccountTitlePolicy.committedName(input: displayName, email: normalizedEmail)
        let id = configuration?.id ?? generatedAccountID ?? AccountID(rawValue: UUID().uuidString.lowercased())
        generatedAccountID = id
        let existing = model.facade.accounts.first { $0.id == id } ?? configuration
        let outgoing: SMTPConfiguration?
        do {
            outgoing = try smtpSettings.configuration(
                existing: existing?.smtp,
                accountUsername: username.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            fieldError = error.localizedDescription
            return
        }
        let config = AccountConfig(
            id: id,
            accountLinkID: existing?.accountLinkID ?? .random(),
            displayName: displayName,
            emailAddress: normalizedEmail,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            imap: IMAPEndpoint(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                security: security
            ),
            smtp: existing?.smtp,
            isEnabled: existing?.isEnabled ?? true
        )

        isSaving = true
        defer { isSaving = false }
        var savedAccount = false
        do {
            try await model.updateAccount(config, password: password.isEmpty ? nil : password)
            savedAccount = true
            accountWasSaved = true
            password = ""
            if outgoing != existing?.smtp || smtpSettings.replacementPassword != nil {
                _ = try await model.dispatch(
                    .configureSMTP(id, outgoing, hasPassword: smtpSettings.replacementPassword != nil),
                    secret: smtpSettings.replacementPassword
                )
            }
            smtpSettings.password = ""
            onSaved()
        } catch {
            fieldError = savedAccount
                ? "Account saved, but outgoing settings could not be saved: \(error.localizedDescription)"
                : error.localizedDescription
        }
    }
}
