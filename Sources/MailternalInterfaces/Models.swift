// Shared value types — FROZEN during wave 1. Changes go through the integration owner.
import Foundation

// MARK: - Identity

public struct AccountID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Local (store-assigned) folder identity — stable across renames when the server
/// provides OBJECTID/MAILBOXID; otherwise a rename creates a new FolderID (spec: sync.md).
public struct FolderID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

/// Local message identity (store row), not the IMAP UID.
public struct MessageID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
}

public struct IMAPUID: Hashable, Comparable, Sendable, Codable, RawRepresentable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// UIDVALIDITY-scoped mailbox generation (spec: sync.md, generation-scoped replacement).
public struct MailboxGeneration: Hashable, Sendable, Codable {
    public let folder: FolderID
    public let uidValidity: UInt32
    public init(folder: FolderID, uidValidity: UInt32) {
        self.folder = folder
        self.uidValidity = uidValidity
    }
}

// MARK: - Folders

public enum FolderRole: String, Sendable, Codable, CaseIterable {
    case inbox, archive, trash, junk, sent, drafts, none
}

public struct FolderSummary: Identifiable, Hashable, Sendable {
    public var id: FolderID
    /// Owning account. Folder IDs are globally unique, but this field lets
    /// account-aware facades and the sidebar group one store snapshot.
    public var accountID: AccountID
    public var name: String
    public var path: String
    public var separator: Character?
    public var role: FolderRole
    public var unreadCount: Int
    public var totalCount: Int
    /// Whether message bodies and metadata are retained locally for this folder.
    /// Discovery and STATUS counts continue while this is disabled.
    public var keepLocally: Bool
    public var backfill: BackfillState
    /// Ephemeral work currently being performed for this folder. The store
    /// derives the initial value from `backfill`; sync engines may refine it
    /// while a batch is being fetched or committed.
    public var activity: FolderActivity
    public init(id: FolderID, name: String, path: String, separator: Character?, role: FolderRole,
                unreadCount: Int, totalCount: Int, keepLocally: Bool = true,
                backfill: BackfillState, activity: FolderActivity? = nil,
                accountID: AccountID = AccountID(rawValue: "")) {
        self.id = id; self.accountID = accountID; self.name = name; self.path = path; self.separator = separator; self.role = role
        self.unreadCount = unreadCount; self.totalCount = totalCount; self.keepLocally = keepLocally
        self.backfill = backfill
        self.activity = activity ?? FolderActivity(backfill: backfill)
    }
}

/// The mutually exclusive phases shown by a folder's sidebar accessory and
/// current-folder status subtitle.
public enum FolderActivity: Hashable, Sendable {
    case downloading
    case indexing
    case moving
    case idle
    case halted
    case quarantinedStall

    public init(backfill: BackfillState) {
        switch backfill {
        case .syncing:
            self = .downloading
        case .halted:
            self = .halted
        case .idle, .complete:
            self = .idle
        }
    }
}

public struct FolderActivityUpdate: Hashable, Sendable {
    public var folder: FolderID
    public var activity: FolderActivity

    public init(folder: FolderID, activity: FolderActivity) {
        self.folder = folder
        self.activity = activity
    }
}

public enum BackfillState: Hashable, Sendable {
    case idle
    case syncing(progress: Double?) // nil = indeterminate
    /// Halted by disk policy or windowed mode; UI must disclose "synced through <date>".
    case halted(syncedThrough: Date)
    case complete
}

// MARK: - Addresses & envelopes

public struct MailAddress: Hashable, Sendable, Codable {
    public var displayName: String?
    public var address: String
    public init(displayName: String?, address: String) {
        self.displayName = displayName
        self.address = address
    }
}

public struct Envelope: Hashable, Sendable, Codable {
    public var subject: String
    public var from: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var replyTo: [MailAddress]
    public var internalDate: Date
    public var headerDate: Date?
    /// Normalized threading headers — stored, not computed on, in 0.0.1 (spec: sync.md).
    public var rfcMessageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public init(subject: String, from: [MailAddress], to: [MailAddress], cc: [MailAddress],
                replyTo: [MailAddress], internalDate: Date, headerDate: Date?,
                rfcMessageID: String?, inReplyTo: String?, references: [String]) {
        self.subject = subject; self.from = from; self.to = to; self.cc = cc
        self.replyTo = replyTo; self.internalDate = internalDate; self.headerDate = headerDate
        self.rfcMessageID = rfcMessageID; self.inReplyTo = inReplyTo; self.references = references
    }
}

// MARK: - Message list & detail

public struct MessageRow: Identifiable, Hashable, Sendable, Codable {
    public var id: MessageID
    public var from: String       // rendered sender
    /// Original sender address retained for sender-domain favicon lookup.
    public var senderAddress: String?
    public var subject: String
    public var preview: String
    public var date: Date
    public var isRead: Bool
    public var hasAttachments: Bool
    public var isFlagged: Bool
    /// Display name of the containing folder (for example, "INBOX" or "Archive").
    public var folderName: String
    /// Owning account title for global search results.
    public var accountName: String?
    /// Owning folder when this row came from global search.
    public var folderID: FolderID?
    public init(id: MessageID, from: String, senderAddress: String? = nil, subject: String, preview: String,
                date: Date, isRead: Bool, hasAttachments: Bool,
                isFlagged: Bool = false, folderName: String,
                accountName: String? = nil, folderID: FolderID? = nil) {
        self.id = id; self.from = from; self.senderAddress = senderAddress; self.subject = subject; self.preview = preview
        self.date = date; self.isRead = isRead; self.hasAttachments = hasAttachments
        self.isFlagged = isFlagged; self.folderName = folderName
        self.accountName = accountName; self.folderID = folderID
    }

}
/// Result of an explicit-folder move request.
///
/// `movedCount` is the number of message IDs accepted and durably queued by
/// the facade. IDs from another account are not accepted because IMAP cannot
/// move them in the destination account; those are counted separately.
public struct MoveOutcome: Codable, Hashable, Sendable {
    public let movedCount: Int
    public let skippedCrossAccountCount: Int
    /// The accepted IDs let optimistic callers restore only IDs rejected by
    /// account validation when a mixed-account selection is submitted.
    public let acceptedIDs: Set<MessageID>

    public init(
        movedCount: Int,
        skippedCrossAccountCount: Int,
        acceptedIDs: Set<MessageID> = []
    ) {
        self.movedCount = movedCount
        self.skippedCrossAccountCount = skippedCrossAccountCount
        self.acceptedIDs = acceptedIDs
    }
}
/// The two user-visible IMAP system flags supported by the mutation queue.
public enum FlagKind: String, Sendable, Codable, Hashable, CaseIterable {
    case seen
    case flagged
}

/// A list ordering. The store applies this ordering to the complete folder,
/// rather than only to rows already loaded by a caller.
public struct MailListSort: Codable, Hashable, Sendable {
    public enum Field: String, Codable, Hashable, Sendable, CaseIterable {
        case date
        case sender
        case subject
        case read
        case flagged
        case attachments
    }

    public enum Direction: String, Codable, Hashable, Sendable, CaseIterable {
        case ascending
        case descending
    }

    public var field: Field
    public var direction: Direction

    public init(field: Field = .date, direction: Direction = .descending) {
        self.field = field
        self.direction = direction
    }

    public static let newest = MailListSort()
}

/// The value at the boundary of a keyset page. The case is deliberately
/// field-specific so a cursor cannot accidentally use a subject value as a
/// sender boundary.
public enum MessagePageCursorValue: Hashable, Sendable, Codable {
    case date(Date)
    case sender(String)
    case subject(String)
    case read(Bool)
    case flagged(Bool)
    case attachments(Bool)
}

/// Keyset pagination cursor over a selected list order and the stable IMAP UID
/// tie-breaker. Cursors are only valid with the same `sort` used to create them.
public struct MessagePageCursor: Hashable, Sendable, Codable {
    public var sort: MailListSort
    public var value: MessagePageCursorValue
    public var uid: IMAPUID

    public init(sort: MailListSort, value: MessagePageCursorValue, uid: IMAPUID) {
        self.sort = sort
        self.value = value
        self.uid = uid
    }
}

public struct MessagePage: Sendable, Codable {
    public var rows: [MessageRow]
    public var next: MessagePageCursor? // nil = end
    public init(rows: [MessageRow], next: MessagePageCursor?) {
        self.rows = rows
        self.next = next
    }
}

public struct AttachmentInfo: Identifiable, Hashable, Sendable, Codable {
    public var id: String          // IMAP part specifier
    public var filename: String?
    public var mimeType: String
    public var sizeEstimate: Int?
    public var contentID: String?  // cid: reference, when inline
    /// MIME Content-Transfer-Encoding for on-demand IMAP section fetches.
    /// Optional for rows written before this field was persisted.
    public var transferEncoding: String?
    public init(
        id: String,
        filename: String?,
        mimeType: String,
        sizeEstimate: Int?,
        contentID: String?,
        transferEncoding: String? = nil
    ) {
        self.id = id; self.filename = filename; self.mimeType = mimeType
        self.sizeEstimate = sizeEstimate; self.contentID = contentID
        self.transferEncoding = transferEncoding
    }
}

public struct MessageDetail: Sendable, Codable {
    public var id: MessageID
    public var envelope: Envelope
    public var bodyText: String?
    /// Already-sanitized HTML (spec: sync.md HTML isolation). Never raw.
    public var sanitizedHTML: String?
    /// Computed by the sanitizer once and carried with the detail. This avoids
    /// reparsing the full HTML on every SwiftUI observation pass.
    public var hasRemoteImageReferences: Bool
    public var attachments: [AttachmentInfo]
    public var isQuarantined: Bool // parse failure; viewer offers capped raw fetch
    public init(
        id: MessageID,
        envelope: Envelope,
        bodyText: String?,
        sanitizedHTML: String?,
        hasRemoteImageReferences: Bool = false,
        attachments: [AttachmentInfo],
        isQuarantined: Bool
    ) {
        self.id = id; self.envelope = envelope; self.bodyText = bodyText
        self.sanitizedHTML = sanitizedHTML
        self.hasRemoteImageReferences = hasRemoteImageReferences
        self.attachments = attachments
        self.isQuarantined = isQuarantined
    }
}

// MARK: - Account configuration

public struct IMAPEndpoint: Hashable, Sendable, Codable {
    public enum Security: String, Sendable, Codable {
        case implicitTLS   // port 993 style
        case startTLS      // mandatory upgrade; no insecure fallback (spec: product.md)
    }
    public var host: String
    public var port: Int
    public var security: Security
    public init(host: String, port: Int, security: Security) {
        self.host = host; self.port = port; self.security = security
    }
}

/// Non-secret account settings. The password lives in the Keychain, never here.
public struct AccountConfig: Hashable, Sendable, Codable {
    public var id: AccountID
    public var accountLinkID: AccountLinkID
    public var displayName: String
    public var emailAddress: String
    public var username: String
    public var imap: IMAPEndpoint
    /// Optional until outgoing setup is completed; contains no password.
    public var smtp: SMTPConfiguration?
    public var isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id, accountLinkID, displayName, emailAddress, username, imap, smtp, isEnabled
    }

    public init(
        id: AccountID,
        accountLinkID: AccountLinkID,
        displayName: String,
        emailAddress: String,
        username: String,
        imap: IMAPEndpoint,
        smtp: SMTPConfiguration? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.accountLinkID = accountLinkID
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.username = username
        self.imap = imap
        self.smtp = smtp
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AccountID.self, forKey: .id)
        accountLinkID = try container.decode(AccountLinkID.self, forKey: .accountLinkID)
        displayName = try container.decode(String.self, forKey: .displayName)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        username = try container.decode(String.self, forKey: .username)
        imap = try container.decode(IMAPEndpoint.self, forKey: .imap)
        smtp = try container.decodeIfPresent(SMTPConfiguration.self, forKey: .smtp)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public enum AccountState: Sendable, Hashable {
    case none                       // no account configured yet
    case validating
    case active
    case authFailed(message: String)
    case connectionFailed(message: String)
}

// MARK: - Sync status surface

public struct SyncStatus: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        case fullHistory
        /// Windowed degraded mode; UI persistently discloses "search covers mail since <date>".
        case windowed(since: Date)
    }
    public var mode: Mode
    public var isOnline: Bool
    public init(mode: Mode, isOnline: Bool) {
        self.mode = mode
        self.isOnline = isOnline
    }
}
