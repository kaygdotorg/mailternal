// The UI ⇄ engine boundary.
// AppShell consumes this against an in-memory mock; the live facade implements
// it over the real sync engine.
import Foundation

@MainActor
public protocol MailFacade: AnyObject, MailFacadeDeepLinking {
    // Account lifecycle (0.0.1: exactly one IMAP account)
    var accountState: AccountState { get }
    var accountStateStream: AsyncStream<AccountState> { get }
    /// The persisted non-secret configuration for the active account.
    /// `nil` means no account has been configured.
    var accountConfig: AccountConfig? { get }
    /// Validates transport + auth per spec (TLS rules), stores secret in Keychain,
    /// activates the account. Throws a user-presentable error on failure.
    func addAccount(_ config: AccountConfig, password: String) async throws
    /// Updates the active account. A nil password keeps the stored secret.
    /// Display-name-only changes do not contact the server.
    func updateAccount(_ config: AccountConfig, password: String?) async throws
    func removeAccount() async throws

    // Folders
    var foldersStream: AsyncStream<[FolderSummary]> { get }

    // Messages — keyset-paged; never a whole-folder query (spec: sync.md storage)
    func page(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) async throws -> MessagePage
    /// Live changes for the currently visible page window of a folder.
    func observePage(in folder: FolderID, after cursor: MessagePageCursor?, limit: Int) -> AsyncStream<MessagePage>

    // Detail
    func detail(_ id: MessageID) async throws -> MessageDetail
    /// User-facing account label for titles and other account context.
    var accountDisplayName: String? { get }
    /// Enqueues local read mutations as `UID STORE +FLAGS.SILENT (\Seen)`.
    func markRead(_ ids: [MessageID]) async
    /// Enqueues local unread mutations as `UID STORE -FLAGS.SILENT (\Seen)`.
    func markUnread(_ ids: [MessageID]) async
    /// Enqueues local `\Flagged` mutations.
    func setFlagged(_ ids: [MessageID], _ flagged: Bool) async
    /// Enqueues a move to the server's Trash folder.
    func trash(_ ids: [MessageID]) async
    /// Enqueues an archive move; the sync engine drains it. No-op toast-level failure is surfaced via error log.
    func archive(_ ids: [MessageID]) async
    /// Enqueues a move to an arbitrary folder.
    func move(_ ids: [MessageID], to folder: FolderID) async
    func rawSource(_ id: MessageID) async throws -> String
    /// On-demand attachment/inline-part fetch → file URL in the attachment cache.
    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL

    // Single-id convenience variants delegate to the atomic batch operations.
    func markRead(_ id: MessageID) async
    func markUnread(_ id: MessageID) async
    func trash(_ id: MessageID) async
    func setFlagged(_ id: MessageID, _ flagged: Bool) async
    func archive(_ id: MessageID) async
    func move(_ id: MessageID, to folder: FolderID) async

    // Search (FTS5 over synced history)
    func search(_ query: String, limit: Int) async throws -> [MessageRow]

    // Sync surface
    var syncStatusStream: AsyncStream<SyncStatus> { get }
    func refresh() async // user-initiated ⌘R: run delta pass now
}

public extension MailFacade {
    /// Facades that cannot expose persisted account settings may leave this
    /// unavailable; the app's live and mock facades provide it for editing.
    var accountConfig: AccountConfig? { nil }
    func markRead(_ id: MessageID) async {
        await markRead([id])
    }

    func markUnread(_ id: MessageID) async {
        await markUnread([id])
    }

    func trash(_ id: MessageID) async {
        await trash([id])
    }

    func setFlagged(_ id: MessageID, _ flagged: Bool) async {
        await setFlagged([id], flagged)
    }

    func archive(_ id: MessageID) async {
        await archive([id])
    }

    func move(_ id: MessageID, to folder: FolderID) async {
        await move([id], to: folder)
    }
}
