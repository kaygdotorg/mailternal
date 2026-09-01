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

enum SyncEngineError: Error, Sendable {
    case stopped
    case messageNotFound
    case partMissing
    case folderNotFound
}
