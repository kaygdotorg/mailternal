/// Typed IMAP session failure. Every case is `Sendable` so the sync engine can
/// hop it across actors and log it without re-wrapping.
public enum IMAPError: Error, Sendable, Hashable {
    /// TCP, EOF, or other I/O failure before an IMAP tagged response.
    case transport(String)
    /// Certificate, hostname, STARTTLS, or “would have been plaintext” failure.
    /// There is never an insecure fallback (spec: product.md Transport).
    case tls(String)
    /// LOGIN / AUTHENTICATE rejected, or no usable mechanism under TLS.
    case auth(String)
    /// Tagged `NO` from the server. Terminal for `\Seen` ops (spec: sync.md).
    case taggedNO(tag: String, message: String, code: String?)
    /// Tagged `BAD` from the server (protocol / capability mismatch).
    case taggedBAD(tag: String, message: String, code: String?)
    /// Wire bytes the NIOIMAP parser could not accept.
    case parse(String)

    /// Convenience: TLS-class failures the engine should treat as “do not retry as plaintext”.
    public var isTLS: Bool {
        if case .tls = self { return true }
        return false
    }

    /// Convenience: tagged `NO`.
    public var isTaggedNO: Bool {
        if case .taggedNO = self { return true }
        return false
    }

    /// Convenience: tagged `BAD`.
    public var isTaggedBAD: Bool {
        if case .taggedBAD = self { return true }
        return false
    }
}

extension IMAPError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .transport(let message):
            return "IMAP transport: \(message)"
        case .tls(let message):
            return "IMAP TLS: \(message)"
        case .auth(let message):
            return "IMAP auth: \(message)"
        case .taggedNO(let tag, let message, let code):
            let extra = code.map { " [\($0)]" } ?? ""
            return "IMAP \(tag) NO\(extra): \(message)"
        case .taggedBAD(let tag, let message, let code):
            let extra = code.map { " [\($0)]" } ?? ""
            return "IMAP \(tag) BAD\(extra): \(message)"
        case .parse(let message):
            return "IMAP parse: \(message)"
        }
    }
}
