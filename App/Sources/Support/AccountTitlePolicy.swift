import Foundation
import MailternalInterfaces

/// Shared account-title fallback used by the model and sidebar.
enum AccountTitlePolicy {
    static func title(for config: AccountConfig?) -> String? {
        guard let config else { return nil }
        let displayName = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? config.emailAddress : displayName
    }
}
