import AppKit
import SwiftUI
import MailternalInterfaces

struct AccountEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let configuration: AccountConfig?

    @State private var presetName = "Generic IMAP"
    @State private var displayName = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var security: IMAPEndpoint.Security = .implicitTLS
    @State private var fieldError: String?
    @State private var isSaving = false

    private var isEditing: Bool { configuration != nil }
    private var presets: [IMAPProviderPreset] { ProviderPresets.all }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Provider") {
                    Picker("Preset", selection: $presetName) {
                        Text("Generic IMAP").tag("Generic IMAP")
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    .accessibilityIdentifier(UIIdentifier.accountEditorPreset)
                    .onChange(of: presetName) { _, name in
                        applyPreset(named: name)
                    }

                    if let preset = presets.first(where: { $0.name == presetName }), !preset.guidance.isEmpty {
                        Text(preset.guidance)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("Account") {
                    TextField("Display Name", text: $displayName)
                        .accessibilityIdentifier(UIIdentifier.accountEditorDisplayName)
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
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(UIIdentifier.accountEditorCancel)
                Button(isEditing ? "Save Changes" : "Add Account") {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier(UIIdentifier.accountEditorSave)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 520, minHeight: 520)
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

    private func applyPreset(named name: String) {
        guard let preset = presets.first(where: { $0.name == name }) else { return }
        host = preset.host
        port = String(preset.port)
        security = preset.security
        if username.isEmpty { username = email }
    }

    private func loadFields() {
        guard let config = configuration else {
            if displayName.isEmpty { displayName = NSFullUserName() }
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

        let config = AccountConfig(
            id: configuration?.id ?? AccountID(rawValue: "account-1"),
            accountLinkID: configuration?.accountLinkID ?? .random(),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            emailAddress: email,
            username: username,
            imap: IMAPEndpoint(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portNumber,
                security: security
            )
        )

        isSaving = true
        defer { isSaving = false }
        do {
            if configuration != nil {
                try await model.updateAccount(config, password: password.isEmpty ? nil : password)
            } else {
                try await model.facade.addAccount(config, password: password)
            }
            password = ""
            dismiss()
        } catch {
            fieldError = error.localizedDescription
        }
    }
}
