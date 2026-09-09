import Foundation
import SwiftUI
import MailternalInterfaces

/// Non-secret settings plus an ephemeral password field. Configuration is
/// committed by account.smtp.configure; the secret never enters AccountConfig.
struct SMTPSettingsDraft {
    var isEnabled = false
    var host = ""
    var port = "587"
    var security: IMAPEndpoint.Security = .startTLS
    var username = ""
    var usesIMAPPassword = true
    var password = ""

    mutating func load(_ configuration: SMTPConfiguration?) {
        isEnabled = configuration != nil
        host = configuration?.host ?? ""
        port = configuration.map { String($0.port) } ?? "587"
        security = configuration?.security ?? .startTLS
        username = configuration?.username ?? ""
        usesIMAPPassword = configuration?.credentialReference == nil
        password = ""
    }

    mutating func apply(_ preset: IMAPProviderPreset, username: String) {
        isEnabled = preset.smtpHost != nil
        host = preset.smtpHost ?? ""
        port = String(preset.smtpPort ?? 587)
        security = preset.smtpSecurity ?? .startTLS
        self.username = username
        usesIMAPPassword = true
        password = ""
    }

    func configuration(existing: SMTPConfiguration?, accountUsername: String) throws -> SMTPConfiguration? {
        guard isEnabled else { return nil }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw SMTPSettingsError.missingHost }
        guard let port = Int(port), (1...65535).contains(port) else { throw SMTPSettingsError.invalidPort }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = usesIMAPPassword ? nil : existing?.credentialReference
        if !usesIMAPPassword, password.isEmpty, reference == nil {
            throw SMTPSettingsError.missingPassword
        }
        return SMTPConfiguration(
            host: host, port: port, security: security,
            username: username.isEmpty ? accountUsername : username,
            credentialReference: reference
        )
    }

    var replacementPassword: String? {
        isEnabled && !usesIMAPPassword && !password.isEmpty ? password : nil
    }
}

struct SMTPAccountFields: View {
    @Binding var draft: SMTPSettingsDraft

    var body: some View {
        Section("Outgoing Mail (SMTP)") {
            Toggle("Enable sending", isOn: $draft.isEnabled)
            if draft.isEnabled {
                TextField("SMTP host", text: $draft.host)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .accessibilityIdentifier("account-smtp-host")
                TextField("SMTP port", text: $draft.port)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Picker("SMTP security", selection: $draft.security) {
                    Text("Implicit TLS").tag(IMAPEndpoint.Security.implicitTLS)
                    Text("STARTTLS (required)").tag(IMAPEndpoint.Security.startTLS)
                }
                TextField("SMTP username", text: $draft.username, prompt: Text("Same as account username"))
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Toggle("Use IMAP password", isOn: $draft.usesIMAPPassword)
                if !draft.usesIMAPPassword {
                    SecureField("SMTP password", text: $draft.password, prompt: Text("Unchanged if already saved"))
                        .textContentType(.password)
                }
                Text("TLS is required. A separate SMTP password is saved in the account’s Keychain, never in mail or command history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("You can save drafts without sending enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private enum SMTPSettingsError: Error, LocalizedError {
    case missingHost, invalidPort, missingPassword
    var errorDescription: String? {
        switch self {
        case .missingHost: "Enter an SMTP host."
        case .invalidPort: "Enter an SMTP port from 1 to 65535."
        case .missingPassword: "Enter a separate SMTP password, or choose Use IMAP password."
        }
    }
}
