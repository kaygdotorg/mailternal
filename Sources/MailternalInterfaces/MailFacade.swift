// The UI ⇄ engine boundary — FROZEN during wave 1.
// AppShell (chunk A) consumes this against an in-memory mock; AccountPlumbing
// (chunk G) implements it over the real sync engine in wave 2.
import Foundation

@MainActor
public protocol MailFacade: AnyObject, MailFacadeDeepLinking {
    // Account lifecycle (0.0.1: exactly one IMAP account)
    var accountState: AccountState { get }
    var accountStateStream: AsyncStream<AccountState> { get }
    /// Validates transport + auth per spec (TLS rules), stores secret in Keychain,
    /// activates the account. Throws a user-presentable error on failure.
    func addAccount(_ config: AccountConfig, password: String) async throws
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
    /// Enqueues a local read mutation as `UID STORE +FLAGS.SILENT (\Seen)`.
    func markRead(_ id: MessageID) async
    /// Enqueues a local unread mutation as `UID STORE -FLAGS.SILENT (\Seen)`.
    func markUnread(_ id: MessageID) async
    /// Enqueues a move to the server's Trash folder.
    func trash(_ id: MessageID) async
    /// Enqueues a local `\Flagged` mutation.
    func setFlagged(_ id: MessageID, _ flagged: Bool) async
    /// Enqueues an archive move; the sync engine drains it. No-op toast-level failure is surfaced via error log.
    func archive(_ id: MessageID) async
    func rawSource(_ id: MessageID) async throws -> String
    /// On-demand attachment/inline-part fetch → file URL in the attachment cache.
    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL

    // Search (FTS5 over synced history)
    func search(_ query: String, limit: Int) async throws -> [MessageRow]

    // Sync surface
    var syncStatusStream: AsyncStream<SyncStatus> { get }
    func refresh() async // user-initiated ⌘R: run delta pass now
}
