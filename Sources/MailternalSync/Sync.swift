import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore

/// Supplies the IMAP secret. Implementations read Keychain (LiveWiring) or a
/// test fixture; the engine never persists the password.
public protocol IMAPCredentialProvider: Sendable {
    func password(for account: AccountID) async throws -> String
}

/// Live-path new-mail event. Emitted only for UIDs **>** the persisted INBOX
/// baseline, in the live generation, after a delta commit — never from backfill.
public struct NewMailEvent: Sendable {
    public var folder: FolderID
    public var from: String
    public var subject: String
    public var messageID: MessageID

    public init(folder: FolderID, from: String, subject: String, messageID: MessageID) {
        self.folder = folder
        self.from = from
        self.subject = subject
        self.messageID = messageID
    }
}

enum SyncEngineError: Error, Sendable, Equatable {
    case stopped
    case messageNotFound
    case partMissing
    case folderNotFound
    /// `fetchPart` was given something other than a numeric IMAP section
    /// (`1`, `1.2`, `1.2.HEADER`, `1.2.TEXT`).
    case invalidPartSpecifier
}

enum IMAPSectionSpecifier {
    /// Legal IMAP BODY section: `^[0-9]+(\.[0-9]+)*$` with optional `.HEADER` / `.TEXT`.
    static func isLegal(_ part: String) -> Bool {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let upper = trimmed.uppercased()
        let core: String
        if upper.hasSuffix(".HEADER") {
            core = String(trimmed.dropLast(7))
        } else if upper.hasSuffix(".TEXT") {
            core = String(trimmed.dropLast(5))
        } else {
            core = trimmed
        }
        guard !core.isEmpty else { return false }
        let pieces = core.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
    }
}
