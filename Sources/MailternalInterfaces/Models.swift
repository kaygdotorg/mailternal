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
    public var name: String
    public var path: String
    public var separator: Character?
    public var role: FolderRole
    public var unreadCount: Int
    public var totalCount: Int
    public var backfill: BackfillState
    public init(id: FolderID, name: String, path: String, separator: Character?, role: FolderRole,
                unreadCount: Int, totalCount: Int, backfill: BackfillState) {
        self.id = id; self.name = name; self.path = path; self.separator = separator; self.role = role
        self.unreadCount = unreadCount; self.totalCount = totalCount; self.backfill = backfill
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

public struct Envelope: Hashable, Sendable {
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

public struct MessageRow: Identifiable, Hashable, Sendable {
    public var id: MessageID
    public var from: String       // rendered sender
    public var subject: String
    public var preview: String
    public var date: Date
    public var isRead: Bool
    public var hasAttachments: Bool
    public init(id: MessageID, from: String, subject: String, preview: String,
                date: Date, isRead: Bool, hasAttachments: Bool) {
        self.id = id; self.from = from; self.subject = subject; self.preview = preview
        self.date = date; self.isRead = isRead; self.hasAttachments = hasAttachments
    }
}

/// Keyset pagination cursor over (internalDate DESC, uid DESC) — spec: sync.md storage.
public struct MessagePageCursor: Hashable, Sendable, Codable {
    public var internalDate: Date
    public var uid: IMAPUID
    public init(internalDate: Date, uid: IMAPUID) {
        self.internalDate = internalDate
        self.uid = uid
    }
}

public struct MessagePage: Sendable {
    public var rows: [MessageRow]
    public var next: MessagePageCursor? // nil = end
    public init(rows: [MessageRow], next: MessagePageCursor?) {
        self.rows = rows
        self.next = next
    }
}

public struct AttachmentInfo: Identifiable, Hashable, Sendable {
    public var id: String          // IMAP part specifier
    public var filename: String?
    public var mimeType: String
    public var sizeEstimate: Int?
    public var contentID: String?  // cid: reference, when inline
    public init(id: String, filename: String?, mimeType: String, sizeEstimate: Int?, contentID: String?) {
        self.id = id; self.filename = filename; self.mimeType = mimeType
        self.sizeEstimate = sizeEstimate; self.contentID = contentID
    }
}

public struct MessageDetail: Sendable {
    public var id: MessageID
    public var envelope: Envelope
    public var bodyText: String?
    /// Already-sanitized HTML (spec: sync.md HTML isolation). Never raw.
    public var sanitizedHTML: String?
    public var attachments: [AttachmentInfo]
    public var isQuarantined: Bool // parse failure; viewer offers capped raw fetch
    public init(id: MessageID, envelope: Envelope, bodyText: String?, sanitizedHTML: String?,
                attachments: [AttachmentInfo], isQuarantined: Bool) {
        self.id = id; self.envelope = envelope; self.bodyText = bodyText
        self.sanitizedHTML = sanitizedHTML; self.attachments = attachments
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
    public init(
        id: AccountID,
        accountLinkID: AccountLinkID,
        displayName: String,
        emailAddress: String,
        username: String,
        imap: IMAPEndpoint
    ) {
        self.id = id
        self.accountLinkID = accountLinkID
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.username = username
        self.imap = imap
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
