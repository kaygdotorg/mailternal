import Foundation

/// A cid: inline part or a remote HTTP(S) image, rewritten to `mailternal-part://`.
public enum PartReference: Hashable, Sendable {
    /// Content-ID without the `cid:` prefix (angle brackets stripped).
    case cid(String)
    /// Remote image; blocked by default until the caller consents.
    case remote(URL)

    public var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }

    /// String passed to `MessageWebView`'s `partProvider`: `cid:…` or an absolute URL.
    public var providerKey: String {
        switch self {
        case .cid(let cid): return "cid:\(cid)"
        case .remote(let url): return url.absoluteString
        }
    }
}

/// One rewritten subresource in a sanitized document.
public struct ResourceEntry: Hashable, Sendable {
    public var reference: PartReference
    /// Remote images are rewritten but must not be fetched until consent.
    public var blockedByDefault: Bool

    public init(reference: PartReference, blockedByDefault: Bool) {
        self.reference = reference
        self.blockedByDefault = blockedByDefault
    }
}

/// Token → original reference map produced by ``HTMLSanitizer``.
///
/// Tokens are the path component of `mailternal-part://part/<token>` and are
/// self-describing (kind + base64url payload), so a second sanitize pass
/// reconstructs the same manifest without side storage.
public struct ResourceManifest: Hashable, Sendable {
    public var entries: [String: ResourceEntry]

    public init(entries: [String: ResourceEntry] = [:]) {
        self.entries = entries
    }

    public subscript(token: String) -> ResourceEntry? {
        entries[token]
    }
}

/// Sanitizer output: allowlisted markup plus the part-token manifest.
public struct SanitizedHTML: Hashable, Sendable {
    public var html: String
    public var manifest: ResourceManifest

    public init(html: String, manifest: ResourceManifest) {
        self.html = html
        self.manifest = manifest
    }
}

/// Encoding of ``PartReference`` as the app-controlled `mailternal-part` URL.
///
/// Form: `mailternal-part://part/<kind>.<base64url(utf8 value)>` where `kind`
/// is `cid` or `remote`. The token is the path (no leading slash). Host is
/// the literal `part` so the token is not a URL-host (hosts are case-folded).
public enum PartURL: Sendable {
    public static let scheme = "mailternal-part"
    public static let host = "part"

    public static func url(for reference: PartReference) -> URL {
        let token = token(for: reference)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + token
        guard let url = components.url else {
            preconditionFailure("PartURL encoding must produce a valid URL")
        }
        return url
    }

    public static func token(for reference: PartReference) -> String {
        let kind: String
        let value: String
        switch reference {
        case .cid(let cid):
            kind = "cid"
            value = cid
        case .remote(let url):
            kind = "remote"
            value = url.absoluteString
        }
        return kind + "." + base64URLEncode(value)
    }

    public static func decode(_ url: URL) -> PartReference? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return decode(token: token(from: url))
    }

    public static func token(from url: URL) -> String {
        let path = url.path
        if path.hasPrefix("/") {
            return String(path.dropFirst())
        }
        return path
    }

    public static func decode(token: String) -> PartReference? {
        guard let dot = token.firstIndex(of: ".") else { return nil }
        let kind = token[..<dot]
        let payload = String(token[token.index(after: dot)...])
        guard let value = base64URLDecode(payload), !value.isEmpty else { return nil }
        switch kind {
        case "cid":
            return .cid(value)
        case "remote":
            guard let url = URL(string: value) else { return nil }
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" else { return nil }
            return .remote(url)
        default:
            return nil
        }
    }

    static func base64URLEncode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - base64.count % 4) % 4
        if pad > 0 {
            base64 += String(repeating: "=", count: pad)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
