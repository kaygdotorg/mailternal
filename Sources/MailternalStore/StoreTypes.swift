import Foundation
@_exported import MailternalInterfaces

// MARK: - Write budget

/// Bounds a single writer transaction (spec: sync.md backfill).
///
/// A batch commits when either `maxRows` or `maxDecodedBytes` would be exceeded
/// by the next item. A single item that itself exceeds the byte budget still
/// occupies its own transaction so a large message cannot stall the folder.
public struct WriteBudget: Hashable, Sendable {
    public var maxRows: Int
    public var maxDecodedBytes: Int

    public init(maxRows: Int, maxDecodedBytes: Int) {
        self.maxRows = max(1, maxRows)
        self.maxDecodedBytes = max(0, maxDecodedBytes)
    }

    /// Default backfill budget: 64 rows or 1 MiB of decoded text per transaction.
    public static let backfill = WriteBudget(maxRows: 64, maxDecodedBytes: 1_048_576)
}

/// Outcome of a budgeted multi-transaction write.
public struct BatchWriteResult: Hashable, Sendable {
    public var committedCount: Int
    public var transactionCount: Int
    public var committedDecodedBytes: Int
    public var lastCommittedUID: IMAPUID?

    public init(
        committedCount: Int,
        transactionCount: Int,
        committedDecodedBytes: Int,
        lastCommittedUID: IMAPUID?
    ) {
        self.committedCount = committedCount
        self.transactionCount = transactionCount
        self.committedDecodedBytes = committedDecodedBytes
        self.lastCommittedUID = lastCommittedUID
    }
}

// MARK: - Flags & incoming messages

/// IMAP system flags plus extra keywords. `\Seen` is `isRead`.
public struct MessageFlags: Hashable, Sendable {
    public var isRead: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var isDraft: Bool
    public var isDeleted: Bool
    public var extra: [String]

    public init(
        isRead: Bool = false,
        isFlagged: Bool = false,
        isAnswered: Bool = false,
        isDraft: Bool = false,
        isDeleted: Bool = false,
        extra: [String] = []
    ) {
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
        self.isDraft = isDraft
        self.isDeleted = isDeleted
        self.extra = extra
    }
}

/// A parsed message ready to persist. Bodies are omitted from list projections.
public struct IncomingMessage: Sendable {
    public var generation: MailboxGeneration
    public var uid: IMAPUID
    public var envelope: Envelope
    public var flags: MessageFlags
    public var bodyText: String?
    public var sanitizedHTML: String?
    public var attachments: [AttachmentInfo]
    public var isTruncated: Bool
    public var isQuarantined: Bool
    /// Parse-defect record stored on the row and mirrored into `error_log`.
    public var parseDefect: String?
    /// Decoded text-part bytes used for the writer byte budget (spec: sync.md).
    public var decodedBytes: Int

    public init(
        generation: MailboxGeneration,
        uid: IMAPUID,
        envelope: Envelope,
        flags: MessageFlags = MessageFlags(),
        bodyText: String? = nil,
        sanitizedHTML: String? = nil,
        attachments: [AttachmentInfo] = [],
        isTruncated: Bool = false,
        isQuarantined: Bool = false,
        parseDefect: String? = nil,
        decodedBytes: Int = 0
    ) {
        self.generation = generation
        self.uid = uid
        self.envelope = envelope
        self.flags = flags
        self.bodyText = bodyText
        self.sanitizedHTML = sanitizedHTML
        self.attachments = attachments
        self.isTruncated = isTruncated
        self.isQuarantined = isQuarantined
        self.parseDefect = parseDefect
        self.decodedBytes = max(0, decodedBytes)
    }
}

public struct FlagDelta: Hashable, Sendable {
    public var uid: IMAPUID
    public var flags: MessageFlags

    public init(uid: IMAPUID, flags: MessageFlags) {
        self.uid = uid
        self.flags = flags
    }
}

// MARK: - Sync / generations

/// Per-folder delta path (spec: sync.md change detection). Persistent and downgradeable.
public enum DeltaPath: String, Sendable, Codable, Hashable {
    case qresync
    case condstore
    case basic
}

/// Per-generation backfill cursor phase. The cursor only advances after commit.
public enum BackfillPhase: String, Sendable, Codable, Hashable {
    case idle
    case walking
    case complete
    case halted
}

public enum GenerationState: String, Sendable, Codable, Hashable {
    /// Currently readable snapshot for the folder.
    case live
    /// Being backfilled; the previous live generation remains readable.
    case replacement
    /// Switched away; awaiting bounded message + FTS cleanup.
    case retiring
}

/// Per-folder-generation sync cursor and capability selection (spec: sync.md Storage).
public struct FolderSyncState: Hashable, Sendable {
    public var generation: MailboxGeneration
    public var deltaPath: DeltaPath
    public var highestModseq: UInt64?
    public var backfillPhase: BackfillPhase
    public var lowWaterUID: IMAPUID?
    public var baselineUID: IMAPUID?
    public var progress: Double?
    public var haltedThrough: Date?

    public init(
        generation: MailboxGeneration,
        deltaPath: DeltaPath = .basic,
        highestModseq: UInt64? = nil,
        backfillPhase: BackfillPhase = .idle,
        lowWaterUID: IMAPUID? = nil,
        baselineUID: IMAPUID? = nil,
        progress: Double? = nil,
        haltedThrough: Date? = nil
    ) {
        self.generation = generation
        self.deltaPath = deltaPath
        self.highestModseq = highestModseq
        self.backfillPhase = backfillPhase
        self.lowWaterUID = lowWaterUID
        self.baselineUID = baselineUID
        self.progress = progress
        self.haltedThrough = haltedThrough
    }
}

// MARK: - Seen queue

/// Persisted `\Seen` mutation (spec: sync.md Seen queue).
public struct SeenOp: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var account: AccountID
    public var folder: FolderID
    public var uidValidity: UInt32
    public var uid: IMAPUID

    public init(id: Int64, account: AccountID, folder: FolderID, uidValidity: UInt32, uid: IMAPUID) {
        self.id = id
        self.account = account
        self.folder = folder
        self.uidValidity = uidValidity
        self.uid = uid
    }
}
 
// MARK: - Archive queue

/// Persisted archive mutation (spec: sync.md Archive queue).
public struct ArchiveOp: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var account: AccountID
    public var folder: FolderID
    public var uidValidity: UInt32
    public var uid: IMAPUID
    public var copied: Bool

    public init(
        id: Int64,
        account: AccountID,
        folder: FolderID,
        uidValidity: UInt32,
        uid: IMAPUID,
        copied: Bool = false
    ) {
        self.id = id
        self.account = account
        self.folder = folder
        self.uidValidity = uidValidity
        self.uid = uid
        self.copied = copied
    }
}


// MARK: - Error log

public enum StoreErrorKind: String, Sendable, Codable, Hashable {
    case parse
    case sync
    case seen
    case archive
}

public struct StoreLogEntry: Hashable, Sendable, Identifiable {
    public var id: Int64?
    public var occurredAt: Date
    public var kind: StoreErrorKind
    public var account: AccountID?
    public var folder: FolderID?
    public var generation: MailboxGeneration?
    public var uid: IMAPUID?
    public var message: String
    public var detail: String?

    public init(
        id: Int64? = nil,
        occurredAt: Date = Date(),
        kind: StoreErrorKind,
        account: AccountID? = nil,
        folder: FolderID? = nil,
        generation: MailboxGeneration? = nil,
        uid: IMAPUID? = nil,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.account = account
        self.folder = folder
        self.generation = generation
        self.uid = uid
        self.message = message
        self.detail = detail
    }
}

// MARK: - Folder identity (LIST reconcile)

/// A folder as reported by one LIST pass (spec: sync.md mailbox discovery).
///
/// Match by `objectID` when the server provides one; otherwise by `path`.
/// Pass the keys from the current LIST to `MailStore.reconcileFolders`.
public struct FolderKey: Hashable, Sendable {
    public var path: String
    public var objectID: String?

    public init(path: String, objectID: String? = nil) {
        self.path = path
        self.objectID = objectID.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Folder counts

/// Per-folder aggregate counts. Observed independently of any page window.
public struct FolderCounts: Hashable, Sendable {
    public var unread: Int
    public var total: Int

    public init(unread: Int, total: Int) {
        self.unread = unread
        self.total = total
    }
}

// MARK: - FTS

public enum FTSIntegrityResult: Hashable, Sendable {
    case ok
    case rebuilt
}

/// Structural store checks used by sync chaos tests (spec: sync.md storage).
///
/// A clean report means: every message belongs to a live / replacement /
/// retiring generation, FTS row count matches the message table, no backfill
/// cursor sits past the generation's UIDNEXT estimate, and each folder has at
/// most one live and one replacement generation.
public struct StoreInvariantReport: Hashable, Sendable {
    public var messageCount: Int
    public var ftsCount: Int
    public var orphanMessageCount: Int
    public var cursorBeyondUidNextCount: Int
    public var liveGenerations: Int
    public var replacementGenerations: Int
    public var retiringGenerations: Int
    public var seenQueueCount: Int
    public var issues: [String]

    public var isClean: Bool { issues.isEmpty }

    public init(
        messageCount: Int,
        ftsCount: Int,
        orphanMessageCount: Int,
        cursorBeyondUidNextCount: Int,
        liveGenerations: Int,
        replacementGenerations: Int,
        retiringGenerations: Int,
        seenQueueCount: Int,
        issues: [String]
    ) {
        self.messageCount = messageCount
        self.ftsCount = ftsCount
        self.orphanMessageCount = orphanMessageCount
        self.cursorBeyondUidNextCount = cursorBeyondUidNextCount
        self.liveGenerations = liveGenerations
        self.replacementGenerations = replacementGenerations
        self.retiringGenerations = retiringGenerations
        self.seenQueueCount = seenQueueCount
        self.issues = issues
    }
}

// MARK: - Attachment pins

/// In-process pin that excludes a cached file from LRU eviction until `unpin`.
public struct AttachmentPin: Hashable, Sendable {
    public let contentHash: String

    public init(contentHash: String) {
        self.contentHash = contentHash
    }
}

// MARK: - Errors

public enum MailStoreError: Error, Sendable, Equatable {
    case accountNotFound
    case folderNotFound
    case messageNotFound
    case generationNotFound
    case replacementAlreadyExists
    case noReplacementGeneration
    case uidValidityMismatch
}
