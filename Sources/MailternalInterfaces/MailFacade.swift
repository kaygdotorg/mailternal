// The UI ⇄ engine boundary.
// AppShell consumes this against an in-memory mock; the live facade implements
// it over the real sync engine.
import Foundation

/// The lightweight state needed to authorize and reverse a user mutation.
/// This deliberately excludes message bodies and raw MIME.
public struct MessageMutationState: Sendable, Hashable {
    public let id: MessageID
    /// The currently retained cache row. This differs from `id` only when an
    /// exact move collided with a row already fetched in the destination.
    public let canonicalID: MessageID
    public let folderID: FolderID
    public let accountLinkID: AccountLinkID
    public let isRead: Bool
    public let isFlagged: Bool
    public let link: MailternalDeepLink?

    public init(
        id: MessageID,
        canonicalID: MessageID? = nil,
        folderID: FolderID,
        accountLinkID: AccountLinkID,
        isRead: Bool,
        isFlagged: Bool,
        link: MailternalDeepLink?
    ) {
        self.id = id; self.canonicalID = canonicalID ?? id; self.folderID = folderID
        self.accountLinkID = accountLinkID; self.isRead = isRead; self.isFlagged = isFlagged; self.link = link
    }
}

/// Errors surfaced by the persisted mail undo journal.
public enum MailUndoError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case permissionDenied
    case irreversible(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "No reversible mail action is available."
        case .permissionDenied:
            return "Undo is not permitted for this mail action."
        case .irreversible(let reason):
            return "This mail action cannot be undone: \(reason)"
        }
    }
}

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
    /// Returns lightweight state for each unique locally stored message ID in
    /// input order; missing/expunged rows are omitted.
    func messageMutationStates(_ ids: [MessageID]) async throws -> [MessageMutationState]
    /// Whether the newest reversible mail operation is available to this scope.
    func canUndo(allowedAccountLinks: Set<AccountLinkID>?) async throws -> Bool
    /// Atomically requests undo of the newest reversible mail operation.
    func undo(allowedAccountLinks: Set<AccountLinkID>?) async throws
    /// On-demand attachment/inline-part fetch → file URL in the attachment cache.
    func fetchAttachment(_ message: MessageID, part: String) async throws -> URL

    // Single-id convenience variants delegate to the atomic batch operations.
    func markRead(_ id: MessageID) async throws
    func markUnread(_ id: MessageID) async throws
    func trash(_ id: MessageID) async throws
    func setFlagged(_ id: MessageID, _ flagged: Bool) async throws
    func archive(_ id: MessageID) async throws
    func move(_ id: MessageID, to folder: FolderID) async throws -> MoveOutcome
    func search(
        _ query: String,
        limit: Int,
        accountLinks: Set<AccountLinkID>?
    ) async throws -> [MessageRow]

    // Outgoing mail. Drafts, submissions, and attachments are account-scoped
    // durable records; clients never receive store or worker internals.
    func configureSMTP(
        _ accountID: AccountID,
        configuration: SMTPConfiguration?,
        password: String?
    ) async throws
    func createDraft(id: UUID, accountID: AccountID, content: DraftContent) async throws -> MailDraft
    func createReplyDraft(id: UUID, messageID: MessageID, replyAll: Bool) async throws -> MailDraft
    func createForwardDraft(id: UUID, messageID: MessageID) async throws -> MailDraft
    func saveDraft(
        id: UUID,
        expectedRevision: Int64,
        content: DraftContent
    ) async throws -> DraftSaveResult
    func deleteDraft(id: UUID, expectedRevision: Int64) async throws
    func draft(id: UUID) async throws -> MailDraft?
    func drafts(accounts: Set<AccountID>?, limit: Int) async throws -> [DraftSummary]
    /// Stages a caller-identified immutable file until a saved draft adopts it.
    /// Retrying the same account and identifier returns the original import.
    func importDraftAttachment(
        id: UUID,
        accountID: AccountID,
        sourceURL: URL,
        filename: String,
        mimeType: String
    ) async throws -> DraftAttachment
    func draftAttachmentURL(id: UUID, accountID: AccountID) async throws -> URL
    func enqueueSubmission(
        id: UUID,
        draftID: UUID,
        expectedRevision: Int64
    ) async throws -> OutboxRecord
    func retrySubmission(
        id: UUID,
        acknowledgeDuplicateRisk: Bool
    ) async throws -> OutboxRecord
    func cancelSubmission(id: UUID) async throws -> OutboxRecord
    func outbox(id: UUID) async throws -> OutboxRecord?
    func outbox(accounts: Set<AccountID>?, limit: Int) async throws -> [OutboxSummary]
    func observeOutgoing(accounts: Set<AccountID>?, limit: Int) -> AsyncStream<OutgoingState>

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
