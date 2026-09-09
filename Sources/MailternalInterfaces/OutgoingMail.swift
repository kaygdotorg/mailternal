import Foundation

/// SMTP routing, separate from the visible MIME headers. Recipients include Bcc;
/// Bcc addresses must never be serialized into the message's headers.
/// The transport validates these untrusted address strings before sending any
/// SMTP command. SMTPUTF8 is required for non-ASCII envelope mailboxes or
/// internationalized message headers, including Reply-To and threading fields.
public struct SMTPEnvelope: Hashable, Sendable, Codable {
    public let sender: String
    public let recipients: [String]
    public let requiresSMTPUTF8: Bool

    public init(sender: String, recipients: [String], requiresSMTPUTF8: Bool) {
        self.sender = sender
        self.recipients = recipients
        self.requiresSMTPUTF8 = requiresSMTPUTF8
    }
}

/// Non-secret outgoing account settings. A nil credential reference reuses the
/// account's IMAP password; a non-nil value identifies a separate Keychain item.
/// The existing transport security modes also apply to SMTP: TLS is mandatory.
public struct SMTPConfiguration: Hashable, Sendable, Codable {
    public var host: String
    public var port: Int
    public var security: IMAPEndpoint.Security
    public var username: String
    public var credentialReference: String?

    public init(
        host: String, port: Int, security: IMAPEndpoint.Security,
        username: String, credentialReference: String? = nil
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.credentialReference = credentialReference
    }
}

/// An immutable, CRLF-serialized MIME file prepared for one submission attempt.
/// The owner retains the file until SMTP acceptance and Sent-copy persistence.
public struct SMTPSubmission: Sendable {
    public let fileURL: URL
    public let byteCount: Int64
    public let envelope: SMTPEnvelope

    public init(fileURL: URL, byteCount: Int64, envelope: SMTPEnvelope) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.envelope = envelope
    }
}

/// Positive completion of DATA, not merely completion of a socket write.
public struct SMTPSubmissionReceipt: Hashable, Sendable, Codable {
    public let acceptedAt: Date
    public let replyCode: Int

    public init(acceptedAt: Date, replyCode: Int) {
        self.acceptedAt = acceptedAt
        self.replyCode = replyCode
    }
}

/// Safe, user-visible delivery failure. Descriptions must not contain AUTH
/// payloads or credentials. Cancellation after DATA commit is deliveryUnknown.
public struct SMTPSubmissionError: Error, LocalizedError, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case configuration, tls, authentication, recipient, message
        case temporary, connection, cancelled, deliveryUnknown
    }

    public let kind: Kind
    public let replyCode: Int?
    public let message: String
    public var errorDescription: String? { message }
    public var isRetryable: Bool { kind == .temporary || kind == .connection }

    public init(kind: Kind, replyCode: Int? = nil, message: String) {
        self.kind = kind
        self.replyCode = replyCode
        self.message = message
    }
}

/// Shared submission seam. Secrets exist only for the duration of these calls.
public protocol SMTPSubmitting: Sendable {
    func validate(configuration: SMTPConfiguration, password: String) async throws

    /// Calls beforeCommit after streaming DATA but before writing its final
    /// terminator. The callback must durably mark acceptance as uncertain.
    /// If it throws, the transport closes without sending the terminator.
    /// After it succeeds, any unconfirmed result must be deliveryUnknown.
    func submit(
        _ submission: SMTPSubmission,
        configuration: SMTPConfiguration,
        password: String,
        beforeCommit: @escaping @Sendable () async throws -> Void
    ) async throws -> SMTPSubmissionReceipt
}

/// Durable attachment metadata. The owning runtime resolves this UUID inside
/// its private outgoing spool; clients cannot supply arbitrary server paths.
public struct DraftAttachment: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let byteCount: Int64

    public init(id: UUID, filename: String, mimeType: String, byteCount: Int64) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

/// A complete editor value. Incomplete addresses may be saved while editing;
/// sending validates the frozen value before beginning an SMTP transaction.
public struct DraftContent: Hashable, Sendable, Codable {
    public var from: MailAddress
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var replyTo: [MailAddress]
    public var subject: String
    public var plainText: String
    public var html: String?
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [DraftAttachment]

    public init(
        from: MailAddress, to: [MailAddress] = [], cc: [MailAddress] = [],
        bcc: [MailAddress] = [], replyTo: [MailAddress] = [],
        subject: String = "", plainText: String = "", html: String? = nil,
        inReplyTo: String? = nil, references: [String] = [],
        attachments: [DraftAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.plainText = plainText
        self.html = html
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }
}

/// A persisted draft head. Revision-checked edits replace this value; a stale
/// complete edit becomes a separate conflict draft rather than overwriting it.
public struct MailDraft: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let accountID: AccountID
    public let revision: Int64
    public let content: DraftContent
    public let updatedAt: Date
    public let conflictOf: UUID?

    public init(
        id: UUID, accountID: AccountID, revision: Int64, content: DraftContent,
        updatedAt: Date, conflictOf: UUID? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.revision = revision
        self.content = content
        self.updatedAt = updatedAt
        self.conflictOf = conflictOf
    }
}

/// On conflict, saved is the retained fork and conflictWith is the untouched
/// current head. Both edits remain available to the user.
public struct DraftSaveResult: Hashable, Sendable, Codable {
    public let saved: MailDraft
    public let conflictWith: MailDraft?

    public init(saved: MailDraft, conflictWith: MailDraft? = nil) {
        self.saved = saved
        self.conflictWith = conflictWith
    }
}

public enum OutboxState: String, Hashable, Sendable, Codable {
    case queued, preparing, sending, awaitingAcceptance
    case deliveryUnknown, failed, cancelled, sentCopyPending, sent
}

/// Frozen submission state. Preparing/sending attempts can recover as unsent;
/// awaitingAcceptance recovers as deliveryUnknown and never automatically sends
/// again. sentCopyPending retries only IMAP persistence, never SMTP.
public struct OutboxRecord: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var accountID: AccountID
    public var draftID: UUID
    public var draftRevision: Int64
    public var content: DraftContent
    public var messageID: String
    public var messageDate: Date
    public var state: OutboxState
    public var attemptID: UUID?
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var envelope: SMTPEnvelope?
    public var byteCount: Int64?
    public var acceptedAt: Date?
    public var failure: SMTPSubmissionError?

    public init(
        id: UUID, accountID: AccountID, draftID: UUID, draftRevision: Int64,
        content: DraftContent, messageID: String, messageDate: Date,
        state: OutboxState = .queued, attemptID: UUID? = nil,
        attemptCount: Int = 0, nextAttemptAt: Date? = nil,
        envelope: SMTPEnvelope? = nil, byteCount: Int64? = nil,
        acceptedAt: Date? = nil, failure: SMTPSubmissionError? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.draftID = draftID
        self.draftRevision = draftRevision
        self.content = content
        self.messageID = messageID
        self.messageDate = messageDate
        self.state = state
        self.attemptID = attemptID
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.envelope = envelope
        self.byteCount = byteCount
        self.acceptedAt = acceptedAt
        self.failure = failure
    }
}

public enum OutgoingMailError: Error, LocalizedError, Equatable, Sendable {
    case draftNotFound
    case revisionConflict
    case attachmentNotFound
    case submissionNotFound
    case invalidTransition
    case duplicateRiskRequiresAcknowledgement
    case invalidContent(String)

    public var errorDescription: String? {
        switch self {
        case .draftNotFound: "The draft is no longer available."
        case .revisionConflict: "The draft changed. Reload it before sending or deleting."
        case .attachmentNotFound: "A draft attachment is unavailable."
        case .submissionNotFound: "The outbox item is no longer available."
        case .invalidTransition: "The delivery state changed. Reload it before trying again."
        case .duplicateRiskRequiresAcknowledgement:
            "Delivery status is unknown. Retrying may send another copy and requires an explicit choice."
        case .invalidContent(let message): message
        }
    }
}

/// Lightweight draft-list projection; body and attachment metadata are fetched
/// only when a client opens the draft.
public struct DraftSummary: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let accountID: AccountID
    public let revision: Int64
    public let subject: String
    public let updatedAt: Date
    public let conflictOf: UUID?
    public let attachmentCount: Int

    public init(
        id: UUID, accountID: AccountID, revision: Int64, subject: String,
        updatedAt: Date, conflictOf: UUID?, attachmentCount: Int
    ) {
        self.id = id
        self.accountID = accountID
        self.revision = revision
        self.subject = subject
        self.updatedAt = updatedAt
        self.conflictOf = conflictOf
        self.attachmentCount = attachmentCount
    }
}

/// Lightweight outbox-list projection. This is an explicit mail query result,
/// not a body-bearing payload repeated in global automation state events.
public struct OutboxSummary: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let accountID: AccountID
    public let draftID: UUID
    public let draftRevision: Int64
    public let subject: String
    public let state: OutboxState
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let acceptedAt: Date?
    public let failure: SMTPSubmissionError?

    public init(
        id: UUID, accountID: AccountID, draftID: UUID, draftRevision: Int64,
        subject: String, state: OutboxState, attemptCount: Int,
        nextAttemptAt: Date?, acceptedAt: Date?, failure: SMTPSubmissionError?
    ) {
        self.id = id
        self.accountID = accountID
        self.draftID = draftID
        self.draftRevision = draftRevision
        self.subject = subject
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.acceptedAt = acceptedAt
        self.failure = failure
    }
}

/// Bounded, body-free projections observed by the owning runtime. Full editor
/// content is loaded explicitly by draft/submission identifier.
public struct OutgoingState: Hashable, Sendable, Codable {
    public let drafts: [DraftSummary]
    public let outbox: [OutboxSummary]

    public init(drafts: [DraftSummary] = [], outbox: [OutboxSummary] = []) {
        self.drafts = drafts
        self.outbox = outbox
    }
}
