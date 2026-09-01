#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import MailternalInterfaces

// MARK: - Capabilities

/// Snapshot of the server’s advertised capabilities after the last CAPABILITY
/// (re-fetched after STARTTLS and after AUTH per spec: product.md Transport).
public struct IMAPCapabilities: Sendable, Hashable {
    /// Raw capability tokens as advertised, uppercased.
    public var raw: Set<String>
    /// `STARTTLS` is advertised.
    public var startTLS: Bool
    /// `IDLE` (RFC 2177).
    public var idle: Bool
    /// `CONDSTORE` (RFC 7162).
    public var condstore: Bool
    /// `QRESYNC` (RFC 7162).
    public var qresync: Bool
    /// `ENABLE` (RFC 5161).
    public var enable: Bool
    /// `OBJECTID` (RFC 8474).
    public var objectID: Bool
    /// `SPECIAL-USE` (RFC 6154).
    public var specialUse: Bool
    /// `LIST-STATUS` (RFC 5819).
    public var listStatus: Bool
    /// `AUTH=PLAIN`.
    public var authPlain: Bool
    /// `SASL-IR` (initial response on AUTHENTICATE).
    public var saslIR: Bool
    /// `LOGINDISABLED`.
    public var loginDisabled: Bool
    /// `X-GM-EXT-1`.
    public var gmailExtensions: Bool
    /// `BINARY` (RFC 3516).
    public var binary: Bool
    /// `UIDPLUS` (RFC 4315).
    public var uidPlus: Bool

    /// Empty / unknown capabilities (pre-connect).
    public static let none = IMAPCapabilities(
        raw: [],
        startTLS: false,
        idle: false,
        condstore: false,
        qresync: false,
        enable: false,
        objectID: false,
        specialUse: false,
        listStatus: false,
        authPlain: false,
        saslIR: false,
        loginDisabled: false,
        gmailExtensions: false,
        binary: false,
        uidPlus: false
    )

    /// Creates a snapshot from already-decoded flags. Prefer `IMAPCapabilities(tokens:)`.
    public init(
        raw: Set<String>,
        startTLS: Bool,
        idle: Bool,
        condstore: Bool,
        qresync: Bool,
        enable: Bool,
        objectID: Bool,
        specialUse: Bool,
        listStatus: Bool,
        authPlain: Bool,
        saslIR: Bool,
        loginDisabled: Bool,
        gmailExtensions: Bool,
        binary: Bool,
        uidPlus: Bool
    ) {
        self.raw = raw
        self.startTLS = startTLS
        self.idle = idle
        self.condstore = condstore
        self.qresync = qresync
        self.enable = enable
        self.objectID = objectID
        self.specialUse = specialUse
        self.listStatus = listStatus
        self.authPlain = authPlain
        self.saslIR = saslIR
        self.loginDisabled = loginDisabled
        self.gmailExtensions = gmailExtensions
        self.binary = binary
        self.uidPlus = uidPlus
    }

    /// Parses a CAPABILITY list. Tokens are matched case-insensitively.
    public init(tokens: [String]) {
        let upper = Set(tokens.map { $0.uppercased() })
        self.raw = upper
        self.startTLS = upper.contains("STARTTLS")
        self.idle = upper.contains("IDLE")
        self.condstore = upper.contains("CONDSTORE")
        self.qresync = upper.contains("QRESYNC")
        self.enable = upper.contains("ENABLE")
        self.objectID = upper.contains("OBJECTID")
        self.specialUse = upper.contains("SPECIAL-USE")
        self.listStatus = upper.contains("LIST-STATUS")
        self.authPlain = upper.contains("AUTH=PLAIN")
        self.saslIR = upper.contains("SASL-IR")
        self.loginDisabled = upper.contains("LOGINDISABLED")
        self.gmailExtensions = upper.contains("X-GM-EXT-1")
        self.binary = upper.contains("BINARY")
        self.uidPlus = upper.contains("UIDPLUS")
    }

    /// Best delta path the *server* advertises. The engine still downgrades
    /// per folder on `BAD` / `NO` / `NOMODSEQ` (spec: sync.md Change detection).
    public var recommendedDeltaPath: IMAPDeltaPath {
        if qresync { return .qresync }
        if condstore { return .condstore }
        return .basic
    }

    /// `true` when `token` (case-insensitive) was advertised.
    public func contains(_ token: String) -> Bool {
        raw.contains(token.uppercased())
    }
}

/// The three change-detection paths (spec: sync.md). Selection is per folder
/// and downgradeable; this type is the probe result, not a stored policy.
public enum IMAPDeltaPath: String, Sendable, Hashable {
    /// `ENABLE QRESYNC`, QRESYNC `SELECT`, `VANISHED`, `CHANGEDSINCE`.
    case qresync
    /// `FETCH (FLAGS) (CHANGEDSINCE n)` plus UID reconciliation.
    case condstore
    /// Bounded `UID FETCH <range> (FLAGS)` sweeps plus UID reconciliation.
    case basic
}

// MARK: - UID sets

/// A UID set the session can encode as an IMAP sequence (`1:99,200:*`).
public struct IMAPUIDSet: Sendable, Hashable {
    /// Inclusive ranges. `UInt32.max` encodes as `*`.
    public var ranges: [ClosedRange<UInt32>]

    /// `1:*`.
    public static let all = IMAPUIDSet(ranges: [1...UInt32.max])

    /// Creates a set from already-normalized ranges.
    public init(ranges: [ClosedRange<UInt32>]) {
        self.ranges = ranges.filter { $0.lowerBound >= 1 }
    }

    /// A single contiguous span.
    public init(_ range: ClosedRange<UInt32>) {
        self.init(ranges: [range])
    }

    /// A single UID.
    public init(uid: UInt32) {
        self.init(ranges: [uid...uid])
    }

    /// `true` when there is nothing to fetch/store.
    public var isEmpty: Bool { ranges.isEmpty }
}

// MARK: - Discovery

/// One selectable mailbox from `LIST` (spec: sync.md Mailbox discovery).
public struct IMAPMailbox: Sendable, Hashable {
    /// Wire mailbox name (decoded for display; still usable as a SELECT argument
    /// for ASCII names including `INBOX`).
    public var path: String
    /// Last path component, or `path` when there is no separator.
    public var name: String
    /// Hierarchy delimiter, if the server provided one.
    public var separator: Character?
    /// SPECIAL-USE role, else a name heuristic, else `.none`.
    public var role: FolderRole
    /// RFC 8474 `MAILBOXID` when `OBJECTID` is advertised and the server returned one.
    public var mailboxID: String?
    /// Raw LIST attributes (`\\HasChildren`, `\\Archive`, …).
    public var attributes: [String]

    /// Creates a discovered mailbox.
    public init(
        path: String,
        name: String,
        separator: Character?,
        role: FolderRole,
        mailboxID: String?,
        attributes: [String]
    ) {
        self.path = path
        self.name = name
        self.separator = separator
        self.role = role
        self.mailboxID = mailboxID
        self.attributes = attributes
    }
}

/// Result of `LIST` plus Gmail detection (spec: sync.md Mailbox discovery).
public struct IMAPFolderDiscovery: Sendable, Hashable {
    /// Selectable folders only (`\\Noselect` / `\\NonExistent` already skipped).
    public var folders: [IMAPMailbox]
    /// `X-GM-EXT-1` was advertised **or** the endpoint host is a known Gmail IMAP host.
    /// The engine must warn: Gmail-via-IMAP is unsupported.
    public var isGmail: Bool

    /// Creates a discovery result.
    public init(folders: [IMAPMailbox], isGmail: Bool) {
        self.folders = folders
        self.isGmail = isGmail
    }
}

// MARK: - SELECT

/// Parameters for a QRESYNC SELECT (RFC 7162). Pass `nil` to SELECT without them.
public struct IMAPQResyncSelect: Sendable, Hashable {
    /// Last known `UIDVALIDITY` for this mailbox.
    public var uidValidity: UInt32
    /// Last known `HIGHESTMODSEQ` (or equivalent).
    public var modificationSequence: UInt64
    /// Optional known-UID set so the server can VANISH the rest.
    public var knownUIDs: IMAPUIDSet?

    /// Creates QRESYNC SELECT parameters.
    public init(uidValidity: UInt32, modificationSequence: UInt64, knownUIDs: IMAPUIDSet? = nil) {
        self.uidValidity = uidValidity
        self.modificationSequence = modificationSequence
        self.knownUIDs = knownUIDs
    }
}

/// State returned by `SELECT` (and updated by untagged EXISTS / FLAGS / VANISHED).
public struct IMAPSelectedMailbox: Sendable, Hashable {
    /// Mailbox name as selected.
    public var name: String
    /// Current `EXISTS` count.
    public var exists: Int
    /// `UIDVALIDITY`. `0` if the server omitted it (treat as a generation break).
    public var uidValidity: UInt32
    /// `UIDNEXT` when advertised.
    public var uidNext: UInt32?
    /// `HIGHESTMODSEQ` when advertised.
    public var highestModSeq: UInt64?
    /// `NOMODSEQ` — this folder cannot use CONDSTORE/QRESYNC; downgrade to basic.
    public var noModSeq: Bool
    /// RFC 8474 mailbox id when returned on SELECT.
    public var mailboxID: String?
    /// Flags the mailbox supports.
    public var flags: [String]
    /// UIDs reported `VANISHED (EARLIER)` during QRESYNC SELECT.
    public var vanishedEarlier: [UInt32]
    /// UIDs reported `VANISHED` (not EARLIER) during this selection.
    public var vanished: [UInt32]
    /// `[READ-WRITE]` vs `[READ-ONLY]`.
    public var isReadWrite: Bool

    /// Creates a selected-mailbox snapshot.
    public init(
        name: String,
        exists: Int,
        uidValidity: UInt32,
        uidNext: UInt32?,
        highestModSeq: UInt64?,
        noModSeq: Bool,
        mailboxID: String?,
        flags: [String],
        vanishedEarlier: [UInt32],
        vanished: [UInt32],
        isReadWrite: Bool
    ) {
        self.name = name
        self.exists = exists
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.noModSeq = noModSeq
        self.mailboxID = mailboxID
        self.flags = flags
        self.vanishedEarlier = vanishedEarlier
        self.vanished = vanished
        self.isReadWrite = isReadWrite
    }
}

// MARK: - Fetch (PEEK only)

/// A BODY.PEEK / BINARY.PEEK section. There is no non-peek variant: a plain
/// `BODY[...]` cannot be expressed (spec: sync.md PEEK rule).
public struct IMAPPeekSection: Sendable, Hashable {
    /// IMAP section text: empty string = whole message, `"TEXT"`, `"HEADER"`, `"1"`, `"1.2"`, `"1.MIME"`.
    public var specifier: String
    /// When `true`, encoded as `BINARY.PEEK[<part>]` (RFC 3516). When `false`, `BODY.PEEK[<specifier>]`.
    public var binary: Bool
    /// Optional partial octet range (`<origin.octets>`).
    public var origin: Int?
    /// Optional partial length in octets.
    public var length: Int?

    /// Whole message: `BODY.PEEK[]`.
    public static let complete = IMAPPeekSection(specifier: "", binary: false)
    /// `BODY.PEEK[TEXT]`.
    public static let text = IMAPPeekSection(specifier: "TEXT", binary: false)
    /// `BODY.PEEK[HEADER]`.
    public static let header = IMAPPeekSection(specifier: "HEADER", binary: false)

    /// Creates a peek section. `binary` still peeks; it never sets `\Seen`.
    public init(specifier: String, binary: Bool = false, origin: Int? = nil, length: Int? = nil) {
        self.specifier = specifier
        self.binary = binary
        self.origin = origin
        self.length = length
    }

    /// MIME part `id` (e.g. `"1.2"`) as `BODY.PEEK[id]`.
    public static func part(_ id: String) -> IMAPPeekSection {
        IMAPPeekSection(specifier: id, binary: false)
    }

    /// MIME part `id` as `BINARY.PEEK[id]`.
    public static func binaryPart(_ id: String) -> IMAPPeekSection {
        IMAPPeekSection(specifier: id, binary: true)
    }
}

/// UID FETCH request. Body payload items are always PEEK.
public struct IMAPFetchRequest: Sendable, Hashable {
    /// Messages to fetch.
    public var uids: IMAPUIDSet
    /// Include `ENVELOPE`.
    public var envelope: Bool
    /// Include `BODYSTRUCTURE` (extended).
    public var bodyStructure: Bool
    /// Include `FLAGS`.
    public var flags: Bool
    /// Include `INTERNALDATE`.
    public var internalDate: Bool
    /// Include `UID` (almost always wanted).
    public var uid: Bool
    /// Include `RFC822.SIZE`.
    public var rfc822Size: Bool
    /// Include `MODSEQ` (CONDSTORE).
    public var modSeq: Bool
    /// Zero or more `BODY.PEEK` / `BINARY.PEEK` sections.
    public var peek: [IMAPPeekSection]
    /// Optional `CHANGEDSINCE` modifier (CONDSTORE / QRESYNC flag deltas).
    public var changedSince: UInt64?

    /// Creates a fetch request. Every body section in `peek` is encoded with PEEK.
    public init(
        uids: IMAPUIDSet,
        envelope: Bool = false,
        bodyStructure: Bool = false,
        flags: Bool = false,
        internalDate: Bool = false,
        uid: Bool = true,
        rfc822Size: Bool = false,
        modSeq: Bool = false,
        peek: [IMAPPeekSection] = [],
        changedSince: UInt64? = nil
    ) {
        self.uids = uids
        self.envelope = envelope
        self.bodyStructure = bodyStructure
        self.flags = flags
        self.internalDate = internalDate
        self.uid = uid
        self.rfc822Size = rfc822Size
        self.modSeq = modSeq
        self.peek = peek
        self.changedSince = changedSince
    }

    /// Envelopes + BODYSTRUCTURE + FLAGS + INTERNALDATE for a UID window (backfill metadata).
    public static func metadata(uids: IMAPUIDSet) -> IMAPFetchRequest {
        IMAPFetchRequest(
            uids: uids,
            envelope: true,
            bodyStructure: true,
            flags: true,
            internalDate: true,
            uid: true
        )
    }

    /// `UID FETCH <set> (FLAGS UID)` — basic path flag sweep.
    public static func flags(uids: IMAPUIDSet) -> IMAPFetchRequest {
        IMAPFetchRequest(uids: uids, flags: true, uid: true)
    }

    /// `UID FETCH <set> (FLAGS UID) (CHANGEDSINCE n)` — CONDSTORE flag deltas.
    public static func flagsChangedSince(uids: IMAPUIDSet, modSeq: UInt64) -> IMAPFetchRequest {
        IMAPFetchRequest(uids: uids, flags: true, uid: true, modSeq: true, changedSince: modSeq)
    }

    /// A single peeked body/part fetch (on-demand text, cid, capped raw).
    public static func peek(uids: IMAPUIDSet, section: IMAPPeekSection) -> IMAPFetchRequest {
        IMAPFetchRequest(uids: uids, uid: true, peek: [section])
    }
}

/// One address from an IMAP ENVELOPE.
public struct IMAPAddress: Sendable, Hashable {
    /// Phrase / display name, if present.
    public var displayName: String?
    /// Local part.
    public var mailbox: String
    /// Domain. Empty when the server sent NIL host (group syntax).
    public var host: String

    /// Creates an envelope address.
    public init(displayName: String?, mailbox: String, host: String) {
        self.displayName = displayName
        self.mailbox = mailbox
        self.host = host
    }

    /// `mailbox@host` when host is non-empty, else `mailbox`.
    public var rfc822: String {
        host.isEmpty ? mailbox : "\(mailbox)@\(host)"
    }
}

/// IMAP ENVELOPE payload (not `MailternalInterfaces.Envelope` — INTERNALDATE is separate).
public struct IMAPEnvelope: Sendable, Hashable {
    /// Envelope `Date` header as the server sent it (unparsed).
    public var date: String?
    /// Subject, decoded as UTF-8 best-effort (MIME encoded-words stay as-is).
    public var subject: String?
    /// `From`.
    public var from: [IMAPAddress]
    /// `Sender`.
    public var sender: [IMAPAddress]
    /// `Reply-To`.
    public var replyTo: [IMAPAddress]
    /// `To`.
    public var to: [IMAPAddress]
    /// `Cc`.
    public var cc: [IMAPAddress]
    /// `Bcc`.
    public var bcc: [IMAPAddress]
    /// `In-Reply-To`.
    public var inReplyTo: String?
    /// `Message-ID`.
    public var messageID: String?

    /// Creates an IMAP envelope.
    public init(
        date: String?,
        subject: String?,
        from: [IMAPAddress],
        sender: [IMAPAddress],
        replyTo: [IMAPAddress],
        to: [IMAPAddress],
        cc: [IMAPAddress],
        bcc: [IMAPAddress],
        inReplyTo: String?,
        messageID: String?
    ) {
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.messageID = messageID
    }
}

/// Flattened BODYSTRUCTURE node. The session does not parse MIME; it only
/// re-speaks the IMAP tree so the engine can decide which peek sections to fetch.
public struct IMAPBodyStructure: Sendable, Hashable {
    /// IMAP part specifier (`""` for the top-level single part, `"1"`, `"1.2"`, …).
    public var partSpecifier: String
    /// Lowercased type (`text`, `multipart`, `application`, …).
    public var type: String
    /// Lowercased subtype (`plain`, `html`, `mixed`, …).
    public var subtype: String
    /// Content-Transfer-Encoding when advertised.
    public var encoding: String?
    /// Octet count when advertised.
    public var octetCount: Int?
    /// `charset` parameter when advertised.
    public var charset: String?
    /// Disposition filename when advertised.
    public var filename: String?
    /// Content-ID (cid) when advertised.
    public var contentID: String?
    /// Child parts (empty for leafs).
    public var children: [IMAPBodyStructure]

    /// Creates a BODYSTRUCTURE node.
    public init(
        partSpecifier: String,
        type: String,
        subtype: String,
        encoding: String?,
        octetCount: Int?,
        charset: String?,
        filename: String?,
        contentID: String?,
        children: [IMAPBodyStructure]
    ) {
        self.partSpecifier = partSpecifier
        self.type = type
        self.subtype = subtype
        self.encoding = encoding
        self.octetCount = octetCount
        self.charset = charset
        self.filename = filename
        self.contentID = contentID
        self.children = children
    }
}

/// One peeked body section as returned by FETCH.
public struct IMAPPeekedPart: Sendable, Hashable {
    /// Section the bytes correspond to (`""`, `"TEXT"`, `"1"`, …).
    public var specifier: String
    /// `true` when the server streamed `BINARY[...]`.
    public var binary: Bool
    /// Payload bytes (already decoded from the IMAP literal).
    public var data: Data

    /// Creates a peeked part.
    public init(specifier: String, binary: Bool, data: Data) {
        self.specifier = specifier
        self.binary = binary
        self.data = data
    }
}

/// One message’s worth of FETCH data.
public struct IMAPFetchedMessage: Sendable, Hashable {
    /// UID when the server sent it.
    public var uid: UInt32?
    /// Sequence number from the FETCH start, if known.
    public var sequence: UInt32?
    /// Current flags (`\\Seen`, `\\Flagged`, keywords, …).
    public var flags: [String]
    /// `INTERNALDATE` as a `Date` when it could be parsed.
    public var internalDate: Date?
    /// IMAP ENVELOPE when requested.
    public var envelope: IMAPEnvelope?
    /// BODYSTRUCTURE when requested and valid.
    public var bodyStructure: IMAPBodyStructure?
    /// `RFC822.SIZE`.
    public var rfc822Size: Int?
    /// `MODSEQ` when advertised.
    public var modSeq: UInt64?
    /// Peeked body sections.
    public var parts: [IMAPPeekedPart]

    /// Creates a fetch result.
    public init(
        uid: UInt32?,
        sequence: UInt32?,
        flags: [String],
        internalDate: Date?,
        envelope: IMAPEnvelope?,
        bodyStructure: IMAPBodyStructure?,
        rfc822Size: Int?,
        modSeq: UInt64?,
        parts: [IMAPPeekedPart]
    ) {
        self.uid = uid
        self.sequence = sequence
        self.flags = flags
        self.internalDate = internalDate
        self.envelope = envelope
        self.bodyStructure = bodyStructure
        self.rfc822Size = rfc822Size
        self.modSeq = modSeq
        self.parts = parts
    }
}

// MARK: - Untagged events / IDLE

/// Untagged mailbox events. During IDLE these are hints only: leave IDLE and
/// run the folder’s delta path (spec: sync.md Live updates).
public enum IMAPMailboxEvent: Sendable, Hashable {
    /// `* n EXISTS`.
    case exists(Int)
    /// `* n EXPUNGE` (sequence number).
    case expunge(sequence: UInt32)
    /// `* VANISHED` UIDs.
    case vanished(uids: [UInt32])
    /// `* VANISHED (EARLIER)` UIDs.
    case vanishedEarlier(uids: [UInt32])
    /// `* n FETCH …` (flag / annotation change; treat as a hint).
    case fetchHint
    /// Server `BYE` / fatal. The session is no longer usable.
    case bye(String)
}

/// A live IDLE session. The caller drives renewal (default 25 minutes per spec)
/// via ``IMAPSession/renewIdle()``, and tears down with ``IMAPSession/endIdle()``.
public struct IMAPIdle: Sendable {
    /// Untagged events while idling. The stream finishes when IDLE ends or the connection drops.
    public var events: AsyncStream<IMAPMailboxEvent>

    /// Creates an IDLE handle. Produced by `IMAPSession.beginIdle()`.
    public init(events: AsyncStream<IMAPMailboxEvent>) {
        self.events = events
    }
}
