// The UI ⇄ engine boundary.
// AppShell consumes this against an in-memory mock; the live facade implements
// it over the real sync engine.
import Foundation

@MainActor
public protocol MailFacade: AnyObject, MailFacadeDeepLinking {
    // Account lifecycle. Every account has independent credentials, state, and
    // sync engine; account IDs are stable for the life of a persisted account.
    var accounts: [AccountConfig] { get }
    var accountsStream: AsyncStream<[AccountConfig]> { get }
    var accountStates: [AccountID: AccountState] { get }
    var accountStatesStream: AsyncStream<[AccountID: AccountState]> { get }
    func accountState(for account: AccountID) -> AccountState
    /// Compatibility aggregate used by the launch shell: active when at least
    /// one account is active, otherwise the first meaningful account state.
    var accountState: AccountState { get }
    var accountStateStream: AsyncStream<AccountState> { get }
    /// The first account is retained as a compatibility convenience for older
    /// settings callers; multi-account UI uses `accounts` instead.
    var accountConfig: AccountConfig? { get }
    /// Validates transport + auth per spec (TLS rules), stores secret in Keychain,
    /// and starts this account without disturbing other running accounts.
    func addAccount(_ config: AccountConfig, password: String) async throws
    /// Updates one account. A nil password keeps its stored secret.
    func updateAccount(_ config: AccountConfig, password: String?) async throws
    /// Enables or disables an account's sync engine while retaining its settings.
    func setAccountEnabled(_ id: AccountID, _ enabled: Bool) async throws
    func removeAccount(_ id: AccountID) async throws
    // Folders from every account. Each summary carries its owning account ID.
    var foldersStream: AsyncStream<[FolderSummary]> { get }
    /// Enables or disables local message retention for a folder. Disabled
    /// folders continue discovery and STATUS count updates without FETCHes.
    func setKeepLocally(_ keep: Bool, for folder: FolderID) async throws
    /// Enqueues a persisted server-side mailbox rename.
    func renameFolder(_ id: FolderID, to name: String) async throws
    // Messages — keyset-paged for rendering; `sort` applies to the complete
    // folder and is retained by every returned cursor.
    func page(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) async throws -> MessagePage
    /// Returns every message ID in the folder's current generation in the same
    /// store-backed order as `page`.
    func messageIDs(in folder: FolderID, sort: MailListSort) async throws -> [MessageID]
    /// Live changes for the currently visible page window of a folder. Each
    /// emitted page uses the requested `sort`.
    func observePage(
        in folder: FolderID,
        after cursor: MessagePageCursor?,
        limit: Int,
        sort: MailListSort
    ) -> AsyncStream<MessagePage>
    // Detail
    func detail(_ id: MessageID) async throws -> MessageDetail
    /// Returns locally stored details for the requested IDs in input order.
    /// Duplicate IDs are returned once; IDs no longer present locally are omitted.
    /// This never fetches remote content.
    func details(_ ids: [MessageID]) async throws -> [MessageDetail]
    /// User-facing account label for titles and other account context.
    var accountDisplayName: String? { get }
    /// Enqueues local read mutations as `UID STORE +FLAGS.SILENT (\Seen)`.
    /// Returns only after durable enqueue; store failures throw, not server failures.
    func markRead(_ ids: [MessageID]) async throws
    /// Enqueues local unread mutations as `UID STORE -FLAGS.SILENT (\Seen)`.
    func markUnread(_ ids: [MessageID]) async throws
    /// Enqueues local `\Flagged` mutations.
    func setFlagged(_ ids: [MessageID], _ flagged: Bool) async throws
    /// Enqueues a move to the server's Trash folder.
    func trash(_ ids: [MessageID]) async throws
    /// Durably enqueues an archive move; missing destinations and write failures throw.
    func archive(_ ids: [MessageID]) async throws
    /// Enqueues a move to an arbitrary folder.
    func move(_ ids: [MessageID], to folder: FolderID) async throws -> MoveOutcome
    func rawSource(_ id: MessageID) async throws -> String
    /// On-demand attachment/inline-part fetch → file URL in the attachment cache.
    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL

    // Single-id convenience variants delegate to the atomic batch operations.
    func markRead(_ id: MessageID) async throws
    func markUnread(_ id: MessageID) async throws
    func trash(_ id: MessageID) async throws
    func setFlagged(_ id: MessageID, _ flagged: Bool) async throws
    func archive(_ id: MessageID) async throws
    func move(_ id: MessageID, to folder: FolderID) async throws -> MoveOutcome

    // Search (FTS5 over synced history)
    func search(_ query: String, limit: Int) async throws -> [MessageRow]

    // Sync surface
    var syncStatusStream: AsyncStream<SyncStatus> { get }
    func refresh() async // user-initiated ⌘R: run delta pass now
}

public extension MailFacade {
    /// Older settings/test callers may remove the first account explicitly.
    func removeAccount() async throws {
        guard let account = accounts.first else { return }
        try await removeAccount(account.id)
    }
    var accountConfig: AccountConfig? { accounts.first }
    var accountDisplayName: String? {
        guard let account = accounts.first else { return nil }
        let displayName = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? account.emailAddress : displayName
    }
    var accountState: AccountState {
        guard !accounts.isEmpty else { return .none }
        let states = accounts.map { accountState(for: $0.id) }
        if states.contains(.active) { return .active }
        if states.contains(.validating) { return .validating }
        return states.first ?? .none
    }
    var accountStateStream: AsyncStream<AccountState> {
        AsyncStream { continuation in
            continuation.yield(accountState)
            continuation.finish()
        }
    }
    var accountStatesStream: AsyncStream<[AccountID: AccountState]> {
        AsyncStream { continuation in
            continuation.yield(accountStates)
            continuation.finish()
        }
    }
    func markRead(_ id: MessageID) async throws {
        try await markRead([id])
    }

    func markUnread(_ id: MessageID) async throws {
        try await markUnread([id])
    }

    func trash(_ id: MessageID) async throws {
        try await trash([id])
    }

    func setFlagged(_ id: MessageID, _ flagged: Bool) async throws {
        try await setFlagged([id], flagged)
    }

    func archive(_ id: MessageID) async throws {
        try await archive([id])
    }

    func move(_ id: MessageID, to folder: FolderID) async throws -> MoveOutcome {
        try await move([id], to: folder)
    }
}
