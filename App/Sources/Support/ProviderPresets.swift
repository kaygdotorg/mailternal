import Foundation
import MailternalInterfaces

struct IMAPProviderPreset: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var host: String
    var port: Int
    var security: IMAPEndpoint.Security
    var usernameHint: String
    var guidance: String
    var smtpHost: String?
    var smtpPort: Int?
    var smtpSecurity: IMAPEndpoint.Security?
}

enum ProviderPresets {
    static let all: [IMAPProviderPreset] = load()

    static func load() -> [IMAPProviderPreset] {
        let urls = [
            Bundle.main.url(forResource: "IMAPPresets", withExtension: "plist"),
            Bundle.main.url(forResource: "IMAPPresets", withExtension: "plist", subdirectory: "Resources"),
        ].compactMap { $0 }

        for url in urls {
            if let presets = decode(url: url), !presets.isEmpty {
                return presets
            }
        }
        return builtin
    }

    private static func decode(url: URL) -> [IMAPProviderPreset]? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return nil }
        return raw.compactMap(parse)
    }

    private static func parse(_ dict: [String: Any]) -> IMAPProviderPreset? {
        guard let name = dict["name"] as? String,
              let host = dict["host"] as? String,
              let port = dict["port"] as? Int
        else { return nil }
        let security = IMAPEndpoint.Security(rawValue: dict["security"] as? String ?? "") ?? .implicitTLS
        let smtpSecurity = (dict["smtpSecurity"] as? String).flatMap(IMAPEndpoint.Security.init(rawValue:))
        return IMAPProviderPreset(
            name: name,
            host: host,
            port: port,
            security: security,
            usernameHint: dict["usernameHint"] as? String ?? "",
            guidance: dict["guidance"] as? String ?? "",
            smtpHost: dict["smtpHost"] as? String,
            smtpPort: dict["smtpPort"] as? Int,
            smtpSecurity: smtpSecurity
        )
    }

    private static let builtin: [IMAPProviderPreset] = [
        IMAPProviderPreset(
            name: "iCloud",
            host: "imap.mail.me.com",
            port: 993,
            security: .implicitTLS,
            usernameHint: "Your Apple Account email",
            guidance: "Create an app-specific password at appleid.apple.com. Two-factor authentication is required; the account password will not work.",
            smtpHost: "smtp.mail.me.com",
            smtpPort: 587,
            smtpSecurity: .startTLS
        ),
        IMAPProviderPreset(
            name: "Fastmail",
            host: "imap.fastmail.com",
            port: 993,
            security: .implicitTLS,
            usernameHint: "Your Fastmail email address",
            guidance: "Create an app-specific password in Fastmail → Privacy & Security → Integrations. The account password will not work with IMAP.",
            smtpHost: "smtp.fastmail.com",
            smtpPort: 587,
            smtpSecurity: .startTLS
        ),
    ]
}
