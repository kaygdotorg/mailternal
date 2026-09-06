import Foundation

/// Wire protocol and persistence limits shared by the iPhone and Watch.
///
/// The companion never receives local SQLite identifiers or credentials. Every
/// message and folder is addressed by the canonical `mailternal://open/v1/...`
/// link produced by MailternalCore.
public enum CompanionProtocol {
    public static let schema = "mailternal.companion.v1"
    public static let version = 1
    public static let maximumMessageCount = 160
    public static let maximumMessageCharacters = 180_000
    public static let maximumCacheCharacters = 2_000_000
    public static let maximumCommandCount = 512
    public static let maximumLinkLength = 2_048
    /// Keep each WatchConnectivity packet below its documented user-info limit.
    public static let maximumTransferBytes = 60_000
}

public enum CompanionLinkKind: String, Codable, Hashable, Sendable {
    case folder
    case message
}

public struct CompanionPhoneInstallation: Codable, Hashable, Sendable {
    public let epoch: String

    public init(epoch: String) {
        self.epoch = String(epoch.prefix(128))
    }
}

public enum CompanionHandoffStatus: String, Codable, Hashable, Sendable {
    case pending
    case accepted
    case failed
}

public struct CompanionHandoffRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let messageLink: String
    public var status: CompanionHandoffStatus
    public var failureReason: String?
    /// Non-nil while the phone has durably claimed routing but has not sent a result.
    public var routingStartedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), messageLink: String,
                status: CompanionHandoffStatus = .pending, failureReason: String? = nil,
                routingStartedAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.messageLink = messageLink
        self.status = status
        self.failureReason = failureReason
        self.routingStartedAt = routingStartedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CompanionHandoffRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let messageLink: String
    public let createdAt: Date

    public init(id: String, messageLink: String, createdAt: Date = Date()) {
        self.id = id
        self.messageLink = messageLink
        self.createdAt = createdAt
    }
    public var isSyntacticallyValid: Bool {
        id.count <= 128 && UUID(uuidString: id) != nil
            && CompanionDeepLink(rawValue: messageLink)?.kind == .message
    }
}

public struct CompanionHandoffAck: Codable, Hashable, Sendable {
    public let requestID: String
    public let messageLink: String
    public let status: CompanionHandoffStatus
    public let reason: String?
    public let receivedAt: Date

    public init(requestID: String, messageLink: String, status: CompanionHandoffStatus,
                reason: String? = nil, receivedAt: Date = Date()) {
        self.requestID = requestID
        self.messageLink = messageLink
        self.status = status
        self.reason = reason
        self.receivedAt = receivedAt
    }
}

public struct CompanionTransportNotice: Codable, Hashable, Sendable {
    public let message: String
    public let createdAt: Date

    public init(message: String, createdAt: Date = Date()) {
        self.message = String(message.prefix(512))
        self.createdAt = createdAt
    }
}


/// A strict, dependency-free parser for canonical Mailternal deep links.
///
/// The Watch target cannot link MailternalCore, so it uses this value to reject
/// malformed or portable-looking IDs before putting data on disk. The iPhone
/// validates the same spelling again through `MailternalDeepLink`.
public struct CompanionDeepLink: Codable, Hashable, Sendable {
    public let rawValue: String
    public let kind: CompanionLinkKind
    public let accountLinkID: String
    public let folderLocatorKind: String
    public let folderLocator: String
    public let uidValidity: UInt32?
    public let uid: UInt32?

    public init?(rawValue: String) {
        guard rawValue.utf8.count <= CompanionProtocol.maximumLinkLength,
              rawValue.hasPrefix("mailternal://open/v1/account/"),
              !rawValue.contains("?") && !rawValue.contains("#"),
              let url = URL(string: rawValue),
              url.scheme == "mailternal", url.host == "open",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }

        let prefix = "mailternal://open"
        let path = String(rawValue.dropFirst(prefix.count))
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (segments.count == 7 || segments.count == 10),
              segments[0].isEmpty,
              segments[1] == "v1",
              segments[2] == "account",
              segments[3].count == 36,
              let uuid = UUID(uuidString: segments[3]),
              segments[3] == uuid.uuidString.lowercased(),
              segments[4] == "folder",
              segments[5] == "object" || segments[5] == "path",
              let locator = Self.decodeLocator(segments[6]) else { return nil }

        let parsedKind: CompanionLinkKind
        let parsedUIDValidity: UInt32?
        let parsedUID: UInt32?
        if segments.count == 7 {
            parsedKind = .folder
            parsedUIDValidity = nil
            parsedUID = nil
        } else {
            guard segments[7] == "message",
                  let validity = Self.positiveUInt32(segments[8]),
                  let uid = Self.positiveUInt32(segments[9]) else { return nil }
            parsedKind = .message
            parsedUIDValidity = validity
            parsedUID = uid
        }

        let canonicalBase = "/v1/account/\(segments[3])/folder/\(segments[5])/\(Self.encode(locator))"
        let canonical = parsedKind == .folder
            ? "mailternal://open\(canonicalBase)"
            : "mailternal://open\(canonicalBase)/message/\(parsedUIDValidity!)/\(parsedUID!)"
        guard canonical == rawValue else { return nil }

        self.rawValue = rawValue
        self.kind = parsedKind
        self.accountLinkID = segments[3]
        self.folderLocatorKind = segments[5]
        self.folderLocator = locator
        self.uidValidity = parsedUIDValidity
        self.uid = parsedUID
    }

    public var isMessage: Bool { kind == .message }

    public var folderLink: String? {
        guard let link = Self.folderLink(accountLinkID: accountLinkID, kind: folderLocatorKind, locator: folderLocator) else {
            return nil
        }
        return link
    }

    public static func folderLink(accountLinkID: String, kind: String, locator: String) -> String? {
        guard accountLinkID.count == 36,
              let uuid = UUID(uuidString: accountLinkID),
              accountLinkID == uuid.uuidString.lowercased(),
              (kind == "object" || kind == "path"),
              let validLocator = validLocator(locator) else { return nil }
        return "mailternal://open/v1/account/\(accountLinkID)/folder/\(kind)/\(encode(validLocator))"
    }

    private static func positiveUInt32(_ value: String) -> UInt32? {
        guard let number = UInt32(value), number > 0 else { return nil }
        return number
    }

    private static func validLocator(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 1_024,
              let decoded = String(bytes: bytes, encoding: .utf8), decoded == value else { return nil }
        guard !decoded.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
                || $0.value == 0
                || $0.properties.generalCategory == .format
                || $0.value == 0x2028 || $0.value == 0x2029
        }) else { return nil }
        return decoded
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeLocator(_ encoded: String) -> String? {
        guard !encoded.isEmpty,
              !encoded.contains("="),
              encoded.utf8.allSatisfy({
                  ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                      || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F
              }) else { return nil }
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: base64),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return validLocator(value)
    }
}

public struct CompanionFolderSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String { canonicalLink }
    public let canonicalLink: String
    public let accountLinkID: String
    public let name: String
    public let role: String
    public let unreadCount: Int
    public let totalCount: Int

    public init(canonicalLink: String, accountLinkID: String, name: String, role: String,
                unreadCount: Int, totalCount: Int) {
        self.canonicalLink = String(canonicalLink.prefix(CompanionProtocol.maximumLinkLength))
        self.accountLinkID = String(accountLinkID.prefix(36))
        self.name = Self.clip(name, to: 256)
        self.role = Self.clip(role, to: 32)
        self.unreadCount = max(0, unreadCount)
        self.totalCount = max(0, totalCount)
    }

    private static func clip(_ value: String, to count: Int) -> String { String(value.prefix(count)) }
}

public struct CompanionMessageSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: String { canonicalLink }
    public let canonicalLink: String
    public let folderLink: String
    public let accountLinkID: String
    public let sender: String
    public let senderAddress: String?
    public let subject: String
    public let preview: String
    public let receivedAt: Date
    public var isRead: Bool
    public var isFlagged: Bool
    public let hasAttachments: Bool
    public var bodyText: String?
    /// True while a local archive/trash/move remains unresolved by the phone.
    public var isPendingRemoval: Bool

    public init(canonicalLink: String, folderLink: String, accountLinkID: String, sender: String,
                senderAddress: String? = nil, subject: String, preview: String, receivedAt: Date,
                isRead: Bool, isFlagged: Bool, hasAttachments: Bool, bodyText: String? = nil,
                isPendingRemoval: Bool = false) {
        self.canonicalLink = String(canonicalLink.prefix(CompanionProtocol.maximumLinkLength))
        self.folderLink = String(folderLink.prefix(CompanionProtocol.maximumLinkLength))
        self.accountLinkID = String(accountLinkID.prefix(36))
        self.sender = Self.clip(sender, to: 512)
        self.senderAddress = senderAddress.map { Self.clip($0, to: 512) }
        self.subject = Self.clip(subject, to: 1_024)
        self.preview = Self.clip(preview, to: 4_096)
        self.receivedAt = receivedAt
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
        self.bodyText = bodyText.map { Self.clip($0, to: CompanionProtocol.maximumMessageCharacters) }
        self.isPendingRemoval = isPendingRemoval
    }

    private static func clip(_ value: String, to count: Int) -> String { String(value.prefix(count)) }
}

public struct CompanionSnapshot: Codable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    /// Monotonic phone-side sequence used to discard delayed user-info packets.
    public let revision: Int
    /// Persisted installation identity. A new value means the phone store was reset.
    public let phoneStoreEpoch: String
    public let generatedAt: Date
    public let lastSyncAt: Date?
    public let folders: [CompanionFolderSnapshot]
    public let messages: [CompanionMessageSnapshot]

    public init(revision: Int = 0, phoneStoreEpoch: String = "", generatedAt: Date = Date(),
                lastSyncAt: Date? = Date(), folders: [CompanionFolderSnapshot],
                messages: [CompanionMessageSnapshot]) {
        self.schema = CompanionProtocol.schema
        self.version = CompanionProtocol.version
        self.revision = max(0, revision)
        self.phoneStoreEpoch = String(phoneStoreEpoch.prefix(128))
        self.generatedAt = generatedAt
        self.lastSyncAt = lastSyncAt
        self.folders = Array(folders.prefix(256))
        self.messages = Array(messages.prefix(CompanionProtocol.maximumMessageCount))
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, revision, phoneStoreEpoch, generatedAt, lastSyncAt, folders, messages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        version = try container.decode(Int.self, forKey: .version)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        phoneStoreEpoch = try container.decodeIfPresent(String.self, forKey: .phoneStoreEpoch) ?? ""
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        folders = try container.decode([CompanionFolderSnapshot].self, forKey: .folders)
        messages = try container.decode([CompanionMessageSnapshot].self, forKey: .messages)
    }

    /// Rejects untrusted wire values before they reach the persistent cache.
    public func validated() -> CompanionSnapshot? {
        guard schema == CompanionProtocol.schema, version == CompanionProtocol.version,
              revision >= 0, phoneStoreEpoch.utf8.count <= 128, folders.count <= 256,
              messages.count <= CompanionProtocol.maximumMessageCount,
              messages.allSatisfy({ ($0.bodyText?.count ?? 0) <= CompanionProtocol.maximumMessageCharacters }) else { return nil }
        let validFolders = folders.filter { folder in
            guard let link = CompanionDeepLink(rawValue: folder.canonicalLink), link.kind == .folder,
                  link.accountLinkID == folder.accountLinkID else { return false }
            return true
        }
        let folderLinks = Set(validFolders.map(\.canonicalLink))
        guard validFolders.count == folders.count else { return nil }
        let validMessages = messages.filter { message in
            guard let link = CompanionDeepLink(rawValue: message.canonicalLink), link.kind == .message,
                  link.accountLinkID == message.accountLinkID,
                  link.folderLink == message.folderLink,
                  folderLinks.contains(message.folderLink) else { return false }
            return true
        }
        guard validMessages.count == messages.count else { return nil }
        return CompanionSnapshot(revision: revision, phoneStoreEpoch: phoneStoreEpoch,
                                 generatedAt: generatedAt, lastSyncAt: lastSyncAt,
                                 folders: validFolders, messages: validMessages)
    }
}
public enum CompanionMutation: Codable, Hashable, Sendable {
    case markRead
    case markUnread
    case setFlagged(Bool)
    case archive
    case trash
    case move(destinationFolderLink: String)

    private enum CodingKeys: String, CodingKey { case kind, flagged, destinationFolderLink }
    private enum Kind: String, Codable { case markRead, markUnread, setFlagged, archive, trash, move }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markRead: try container.encode(Kind.markRead, forKey: .kind)
        case .markUnread: try container.encode(Kind.markUnread, forKey: .kind)
        case .setFlagged(let value):
            try container.encode(Kind.setFlagged, forKey: .kind)
            try container.encode(value, forKey: .flagged)
        case .archive: try container.encode(Kind.archive, forKey: .kind)
        case .trash: try container.encode(Kind.trash, forKey: .kind)
        case .move(let link):
            try container.encode(Kind.move, forKey: .kind)
            try container.encode(link, forKey: .destinationFolderLink)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .markRead: self = .markRead
        case .markUnread: self = .markUnread
        case .setFlagged: self = .setFlagged(try container.decode(Bool.self, forKey: .flagged))
        case .archive: self = .archive
        case .trash: self = .trash
        case .move: self = .move(destinationFolderLink: try container.decode(String.self, forKey: .destinationFolderLink))
        }
    }

    public var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}

public struct CompanionCommand: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sequence: Int64
    public let createdAt: Date
    public let accountLinkID: String
    public let messageLink: String
    public let mutation: CompanionMutation
    public let previousIsRead: Bool?
    public let previousIsFlagged: Bool?

    public init(id: String = UUID().uuidString.lowercased(), sequence: Int64 = 0,
                createdAt: Date = Date(), accountLinkID: String, messageLink: String,
                mutation: CompanionMutation, previousIsRead: Bool? = nil,
                previousIsFlagged: Bool? = nil) {
        self.id = id
        self.sequence = max(0, sequence)
        // Wire and disk dates use milliseconds. Canonicalize before hashing or
        // duplicate comparison so JSON round trips cannot change command identity.
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        self.accountLinkID = accountLinkID
        self.messageLink = messageLink
        self.mutation = mutation
        self.previousIsRead = previousIsRead
        self.previousIsFlagged = previousIsFlagged
    }

    private enum CodingKeys: String, CodingKey {
        case id, sequence, createdAt, accountLinkID, messageLink, mutation, previousIsRead, previousIsFlagged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            sequence: try container.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            accountLinkID: try container.decode(String.self, forKey: .accountLinkID),
            messageLink: try container.decode(String.self, forKey: .messageLink),
            mutation: try container.decode(CompanionMutation.self, forKey: .mutation),
            previousIsRead: try container.decodeIfPresent(Bool.self, forKey: .previousIsRead),
            previousIsFlagged: try container.decodeIfPresent(Bool.self, forKey: .previousIsFlagged)
        )
    }

    public func withSequence(_ sequence: Int64) -> CompanionCommand {
        CompanionCommand(id: id, sequence: sequence, createdAt: createdAt,
                         accountLinkID: accountLinkID, messageLink: messageLink,
                         mutation: mutation, previousIsRead: previousIsRead,
                         previousIsFlagged: previousIsFlagged)
    }

    public var isSyntacticallyValid: Bool {
        guard id.count <= 128, UUID(uuidString: id) != nil, sequence >= 0,
              let link = CompanionDeepLink(rawValue: messageLink), link.kind == .message,
              link.accountLinkID == accountLinkID else { return false }
        if case .move(let destination) = mutation {
            guard let destinationLink = CompanionDeepLink(rawValue: destination), destinationLink.kind == .folder,
                  destinationLink.accountLinkID == accountLinkID else { return false }
        }
        return true
    }
}

public enum CompanionCommandStatus: String, Codable, Hashable, Sendable {
    case pendingOnWatch
    case acceptedByPhone
    case submittedToMailQueue
    /// The phone stopped after claiming execution but before proving that
    /// MailFacade accepted the operation. This outcome is reviewable and must
    /// never be replayed automatically.
    case needsReview
    case failed
}

public enum CompanionExecutionState: String, Codable, Hashable, Sendable {
    case notStarted
    /// Durable marker written before invoking MailFacade. If it survives a
    /// restart, delivery is ambiguous rather than safely retryable.
    case inFlight
    case submittedToFacade
}

public struct CompanionCommandRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let command: CompanionCommand
    public var status: CompanionCommandStatus
    public var execution: CompanionExecutionState
    public var failureReason: String?
    /// The phone installation that accepted this command, if known.
    public var phoneStoreEpoch: String?
    public let enqueuedAt: Date
    public var updatedAt: Date

    public init(command: CompanionCommand, status: CompanionCommandStatus = .pendingOnWatch,
                execution: CompanionExecutionState = .notStarted, failureReason: String? = nil,
                phoneStoreEpoch: String? = nil, enqueuedAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = command.id
        self.command = command
        self.status = status
        self.execution = execution
        self.failureReason = failureReason
        self.phoneStoreEpoch = phoneStoreEpoch
        self.enqueuedAt = enqueuedAt
        self.updatedAt = updatedAt
    }
}

public struct CompanionState: Codable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public var revision: Int
    public var lastSnapshotRevision: Int
    public var phoneStoreEpoch: String
    public var phoneEpochConfirmed: Bool
    public var commandSequence: Int64
    public var generatedAt: Date?
    public var lastSyncAt: Date?
    public var folders: [CompanionFolderSnapshot]
    public var messages: [CompanionMessageSnapshot]
    public var commands: [CompanionCommandRecord]
    public var handoffs: [CompanionHandoffRecord]
    public var lastError: String?

    public init(revision: Int = 0, lastSnapshotRevision: Int = 0, phoneStoreEpoch: String = "",
                phoneEpochConfirmed: Bool = false, commandSequence: Int64 = 0,
                generatedAt: Date? = nil, lastSyncAt: Date? = nil,
                folders: [CompanionFolderSnapshot] = [], messages: [CompanionMessageSnapshot] = [],
                commands: [CompanionCommandRecord] = [], handoffs: [CompanionHandoffRecord] = [],
                lastError: String? = nil) {
        self.schema = CompanionProtocol.schema
        self.version = CompanionProtocol.version
        self.revision = revision
        self.lastSnapshotRevision = max(0, lastSnapshotRevision)
        self.phoneStoreEpoch = String(phoneStoreEpoch.prefix(128))
        self.phoneEpochConfirmed = phoneEpochConfirmed
        self.commandSequence = max(0, commandSequence)
        self.generatedAt = generatedAt
        self.lastSyncAt = lastSyncAt
        self.folders = folders
        self.messages = messages
        self.commands = commands
        self.handoffs = handoffs
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, revision, lastSnapshotRevision, phoneStoreEpoch, phoneEpochConfirmed
        case commandSequence, generatedAt, lastSyncAt, folders, messages, commands, handoffs, lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(String.self, forKey: .schema)
        version = try container.decode(Int.self, forKey: .version)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        lastSnapshotRevision = try container.decodeIfPresent(Int.self, forKey: .lastSnapshotRevision) ?? 0
        phoneStoreEpoch = try container.decodeIfPresent(String.self, forKey: .phoneStoreEpoch) ?? ""
        phoneEpochConfirmed = try container.decodeIfPresent(Bool.self, forKey: .phoneEpochConfirmed) ?? false
        commandSequence = try container.decodeIfPresent(Int64.self, forKey: .commandSequence) ?? 0
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
        lastSyncAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        folders = try container.decodeIfPresent([CompanionFolderSnapshot].self, forKey: .folders) ?? []
        messages = try container.decodeIfPresent([CompanionMessageSnapshot].self, forKey: .messages) ?? []
        commands = try container.decodeIfPresent([CompanionCommandRecord].self, forKey: .commands) ?? []
        handoffs = try container.decodeIfPresent([CompanionHandoffRecord].self, forKey: .handoffs) ?? []
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}


public enum CompanionAckStatus: String, Codable, Hashable, Sendable {
    case acceptedByPhone
    case submittedToMailQueue
    /// The phone could not prove whether execution reached MailFacade. The
    /// Watch must expose this for review rather than replaying the command.
    case needsReview
    case failed
}

public struct CompanionCommandAck: Codable, Hashable, Sendable {
    public let commandID: String
    public let accountLinkID: String
    public let status: CompanionAckStatus
    public let reason: String?
    public let phoneStoreEpoch: String?
    public let receivedAt: Date

    public init(commandID: String, accountLinkID: String, status: CompanionAckStatus,
                reason: String? = nil, phoneStoreEpoch: String? = nil, receivedAt: Date = Date()) {
        self.commandID = commandID
        self.accountLinkID = accountLinkID
        self.status = status
        self.reason = reason
        self.phoneStoreEpoch = phoneStoreEpoch
        self.receivedAt = receivedAt
    }
}

/// One Codable envelope is used for durable user-info transfers and reachable
/// request/reply messages. Property-list dictionaries only carry its Data blob.
public enum CompanionWireMessage: Codable, Hashable, Sendable {
    case snapshot(CompanionSnapshot)
    case phoneInstallation(CompanionPhoneInstallation)
    case command(CompanionCommand)
    case acknowledgment(CompanionCommandAck)
    case handoff(CompanionHandoffRequest)
    case handoffAcknowledgment(CompanionHandoffAck)
    case notice(CompanionTransportNotice)

    private enum CodingKeys: String, CodingKey {
        case schema, version, kind, snapshot, phoneInstallation, command, acknowledgment
        case handoff, handoffAcknowledgment, notice
    }
    private enum Kind: String, Codable {
        case snapshot, phoneInstallation, command, acknowledgment, handoff, handoffAcknowledgment, notice
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CompanionProtocol.schema, forKey: .schema)
        try container.encode(CompanionProtocol.version, forKey: .version)
        switch self {
        case .snapshot(let value):
            try container.encode(Kind.snapshot, forKey: .kind)
            try container.encode(value, forKey: .snapshot)
        case .phoneInstallation(let value):
            try container.encode(Kind.phoneInstallation, forKey: .kind)
            try container.encode(value, forKey: .phoneInstallation)
        case .command(let value):
            try container.encode(Kind.command, forKey: .kind)
            try container.encode(value, forKey: .command)
        case .acknowledgment(let value):
            try container.encode(Kind.acknowledgment, forKey: .kind)
            try container.encode(value, forKey: .acknowledgment)
        case .handoff(let value):
            try container.encode(Kind.handoff, forKey: .kind)
            try container.encode(value, forKey: .handoff)
        case .handoffAcknowledgment(let value):
            try container.encode(Kind.handoffAcknowledgment, forKey: .kind)
            try container.encode(value, forKey: .handoffAcknowledgment)
        case .notice(let value):
            try container.encode(Kind.notice, forKey: .kind)
            try container.encode(value, forKey: .notice)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .schema) == CompanionProtocol.schema,
              try container.decode(Int.self, forKey: .version) == CompanionProtocol.version else {
            throw CompanionCodecError.unsupportedMessage
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .snapshot: self = .snapshot(try container.decode(CompanionSnapshot.self, forKey: .snapshot))
        case .phoneInstallation: self = .phoneInstallation(try container.decode(CompanionPhoneInstallation.self, forKey: .phoneInstallation))
        case .command: self = .command(try container.decode(CompanionCommand.self, forKey: .command))
        case .acknowledgment: self = .acknowledgment(try container.decode(CompanionCommandAck.self, forKey: .acknowledgment))
        case .handoff: self = .handoff(try container.decode(CompanionHandoffRequest.self, forKey: .handoff))
        case .handoffAcknowledgment: self = .handoffAcknowledgment(try container.decode(CompanionHandoffAck.self, forKey: .handoffAcknowledgment))
        case .notice: self = .notice(try container.decode(CompanionTransportNotice.self, forKey: .notice))
        }
    }
}

public enum CompanionCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public static func encode(_ message: CompanionWireMessage) throws -> Data {
        try makeEncoder().encode(message)
    }

    public static func decode(_ data: Data) throws -> CompanionWireMessage {
        let message = try makeDecoder().decode(CompanionWireMessage.self, from: data)
        if case .snapshot(let snapshot) = message, snapshot.validated() == nil {
            throw CompanionCodecError.invalidSnapshot
        }
        if case .command(let command) = message, !command.isSyntacticallyValid {
            throw CompanionCodecError.invalidCommand
        }
        if case .handoff(let request) = message, !request.isSyntacticallyValid {
            throw CompanionCodecError.invalidHandoff
        }
        return message
    }
}

public enum CompanionCodecError: Error, LocalizedError, Sendable {
    case invalidSnapshot
    case invalidCommand
    case invalidHandoff
    case unsupportedMessage

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "The companion snapshot is malformed."
        case .invalidCommand: "The companion command is malformed."
        case .invalidHandoff: "The companion handoff is malformed."
        case .unsupportedMessage: "The companion message type is unsupported."
        }
    }
}
