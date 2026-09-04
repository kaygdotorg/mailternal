import Foundation
import MailternalInterfaces

/// Shared account-title fallback used by the model and sidebar.
enum AccountTitlePolicy {
    static func title(for config: AccountConfig?) -> String? {
        guard let config else { return nil }
        let displayName = config.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? config.emailAddress : displayName
    }

    /// Resolves the value committed by the inline account-name field.
    ///
    /// A blank name is not a blank title in the UI: it falls back to the
    /// account's address, just as `title(for:)` does.
    static func committedName(input: String, email: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? email : trimmed
    }
}

/// Pure presentation rules for the account list.
///
/// The facade still owns one account today. Keeping these rules independent of
/// SwiftUI lets the accounts pane already model the future multi-account list.
enum AccountsListPolicy {
    struct RowSummary: Equatable, Sendable {
        let displayName: String
        let email: String
        let host: String

        var text: String {
            [displayName, email, host]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    enum Status: Equatable, Sendable {
        case active
        case validating
        case error(message: String)
    }

    static func sorted(_ configs: [AccountConfig]) -> [AccountConfig] {
        configs.sorted {
            let lhs = AccountTitlePolicy.title(for: $0) ?? ""
            let rhs = AccountTitlePolicy.title(for: $1) ?? ""
            let titleOrder = lhs.localizedCaseInsensitiveCompare(rhs)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let emailOrder = $0.emailAddress.localizedCaseInsensitiveCompare($1.emailAddress)
            if emailOrder != .orderedSame { return emailOrder == .orderedAscending }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    /// The account editor's empty state is reserved for an actually empty
    /// configuration list. Disabled accounts remain visible so they can be
    /// enabled again.
    static func showsEmptyState(for configs: [AccountConfig], isAdding: Bool) -> Bool {
        configs.isEmpty && !isAdding
    }

    static func rowSummary(for config: AccountConfig) -> RowSummary {
        RowSummary(
            displayName: AccountTitlePolicy.title(for: config) ?? "",
            email: config.emailAddress,
            host: config.imap.host
        )
    }

    static func status(for state: AccountState) -> Status {
        switch state {
        case .active:
            .active
        case .validating:
            .validating
        case .none:
            .error(message: "No account configured.")
        case .authFailed(let message), .connectionFailed(let message):
            .error(message: message)
        }
    }
    static func committedName(input: String, email: String) -> String {
        AccountTitlePolicy.committedName(input: input, email: email)
    }

    static func nextExpandedID(current: AccountID?, requested: AccountID) -> AccountID? {
        current == requested ? nil : requested
    }

    static func removesBlankRow(rowID: AccountID, blankID: AccountID) -> Bool {
        rowID == blankID
    }
}
