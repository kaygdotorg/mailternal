import Foundation

/// A durable identity shared by devices for one account's non-secret metadata.
/// This UUID transfers with metadata and is not a credential.
public struct AccountLinkID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public static func random() -> Self {
        Self(rawValue: UUID())
    }

    public var uuidString: String {
        rawValue.uuidString.lowercased()
    }
}

/// The server-stable locator for a mailbox. Object IDs survive renames; paths
/// are the conservative fallback when the server has no mailbox object ID.
public struct FolderLocator: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case object
        case path
    }

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A cross-device destination. It intentionally contains no local database
/// identifiers, credentials, mailbox display names, or message content.
public enum MailternalDeepLink: Hashable, Sendable {
    case folder(accountLinkID: AccountLinkID, folderLocator: FolderLocator)
    case message(
        accountLinkID: AccountLinkID,
        folderLocator: FolderLocator,
        uidValidity: UInt32,
        uid: IMAPUID
    )

    public static let scheme = "mailternal"
    public static let host = "open"
    public static let version = "v1"
    public static let maximumLength = 2048

    /// Parses a complete URL only when its spelling is already canonical.
    public init?(url: URL) {
        guard url.scheme == Self.scheme,
              url.host == Self.host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return nil }
        self.init(string: url.absoluteString)
    }

    /// Convenience parser for URL text received from platform open-URL events.
    public init?(string: String) {
        guard string.utf8.count <= Self.maximumLength,
              let parsed = Self.parse(string),
              parsed.formattedString == string else { return nil }
        self = parsed.link
    }

    /// Canonical URL text, or `nil` when a manually-created link is invalid.
    public var formattedString: String? {
        guard let path = pathString else { return nil }
        let string = "\(Self.scheme)://\(Self.host)\(path)"
        return string.utf8.count <= Self.maximumLength ? string : nil
    }

    /// Canonical URL, or `nil` when a manually-created link is invalid.
    public var formattedURL: URL? {
        guard let string = formattedString else { return nil }
        return URL(string: string)
    }

    public var accountLinkID: AccountLinkID {
        switch self {
        case .folder(let accountLinkID, _), .message(let accountLinkID, _, _, _):
            accountLinkID
        }
    }

    public var folderLocator: FolderLocator {
        switch self {
        case .folder(_, let folderLocator), .message(_, let folderLocator, _, _):
            folderLocator
        }
    }

    public var messageLocator: (uidValidity: UInt32, uid: IMAPUID)? {
        guard case .message(_, _, let uidValidity, let uid) = self else { return nil }
        return (uidValidity, uid)
    }

    private var pathString: String? {
        guard let account = Self.validAccount(accountLinkID),
              Self.validLocator(folderLocator) else { return nil }
        let encodedLocator = Self.encode(folderLocator.value)
        let base = "/\(Self.version)/account/\(account)/folder/\(folderLocator.kind.rawValue)/\(encodedLocator)"
        switch self {
        case .folder:
            return base
        case .message(_, _, let uidValidity, let uid):
            guard uidValidity > 0, uid.rawValue > 0 else { return nil }
            return "\(base)/message/\(uidValidity)/\(uid.rawValue)"
        }
    }

    private static func parse(_ raw: String) -> (link: MailternalDeepLink, formattedString: String)? {
        guard raw.utf8.count <= maximumLength,
              raw.hasPrefix("\(scheme)://\(host)/"),
              !raw.contains("?"),
              !raw.contains("#"),
              let url = URL(string: raw),
              url.scheme == scheme,
              url.host == host,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return nil }

        let path = String(raw.dropFirst((scheme + "://" + host).count))
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.first == "",
              segments.count == 7 || segments.count == 10,
              segments[1] == version,
              segments[2] == "account",
              let account = decodeAccount(segments[3]),
              segments[4] == "folder",
              let kind = FolderLocator.Kind(rawValue: segments[5]),
              let locator = decodeLocator(segments[6]) else { return nil }

        let folderLocator = FolderLocator(kind: kind, value: locator)
        let link: MailternalDeepLink
        if segments.count == 7 {
            link = .folder(
                accountLinkID: account,
                folderLocator: folderLocator
            )
        } else {
            guard segments[7] == "message",
                  let uidValidity = parsePositiveUInt32(segments[8]),
                  let uid = parsePositiveUInt32(segments[9]) else { return nil }
            link = .message(
                accountLinkID: account,
                folderLocator: folderLocator,
                uidValidity: uidValidity,
                uid: IMAPUID(rawValue: uid)
            )
        }
        guard let formatted = link.formattedString else { return nil }
        return (link, formatted)
    }

    private static func decodeAccount(_ encoded: String) -> AccountLinkID? {
        guard encoded.count == 36,
              let account = AccountLinkID(uuidString: encoded),
              account.uuidString == encoded else { return nil }
        return account
    }

    private static func validAccount(_ account: AccountLinkID) -> String? {
        let value = account.uuidString
        return value.count == 36 ? value : nil
    }

    private static func validLocator(_ locator: FolderLocator) -> Bool {
        let bytes = Array(locator.value.utf8)
        guard !bytes.isEmpty, bytes.count <= 1024,
              let value = String(bytes: bytes, encoding: .utf8),
              value == locator.value else { return false }
        // Links are cross-app attacker-controllable input: besides C0/C1
        // controls, reject format characters (Cf: bidi overrides/isolates,
        // zero-width, BOM) and line/paragraph separators, which exist only
        // to spoof how a folder label renders.
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || $0.value == 0
                || $0.properties.generalCategory == .format
                || $0.value == 0x2028 || $0.value == 0x2029
        }
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
                  ($0 >= 0x41 && $0 <= 0x5A) ||
                  ($0 >= 0x61 && $0 <= 0x7A) ||
                  ($0 >= 0x30 && $0 <= 0x39) ||
                  $0 == 0x2D || $0 == 0x5F
              }),
              encoded.utf8.count % 4 != 1 else { return nil }
        let standard = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let value = String(data: data, encoding: .utf8),
              encode(value) == encoded,
              validLocator(FolderLocator(kind: .path, value: value)) else { return nil }
        return value
    }

    private static func parsePositiveUInt32(_ text: String) -> UInt32? {
        guard !text.isEmpty,
              text.first != "0",
              text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = UInt64(text),
              value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }
}

public enum MailternalDeepLinkResolution: Hashable, Sendable {
    case folder(FolderID)
    case message(folderID: FolderID, messageID: MessageID, row: MessageRow)
}

/// Deep-link routing seam. Implementations retain account isolation and
/// generation guards while callers deal only in typed destinations.
@MainActor
public protocol MailFacadeDeepLinking: AnyObject {
    func makeDeepLink(for folder: FolderID) async throws -> MailternalDeepLink?
    func makeDeepLink(for message: MessageID) async throws -> MailternalDeepLink?
    func resolve(_ link: MailternalDeepLink) async throws -> MailternalDeepLinkResolution?
}
