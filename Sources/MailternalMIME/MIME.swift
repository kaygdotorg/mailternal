// MailternalMIME — RFC 5322 / MIME parser (spec: docs/spec/sync.md MIME).
// Cross-platform Foundation-only. Wave-2 sync and the viewer consume this surface.
import Foundation
import MailternalInterfaces

// MARK: - Limits (sync.md, hard)

/// Hard parser limits from the sync spec. Enforced on every parse.
public enum MIMELimits: Sendable {
    /// Single physical header line, bytes.
    public static let headerLine = 64 * 1024
    /// Entire header block (through the blank line), bytes.
    public static let headerBlock = 1 * 1024 * 1024
    /// Decoded text part, bytes. Excess is truncated and flagged.
    public static let decodedTextPart = 8 * 1024 * 1024
    /// Maximum MIME nesting (multipart / message/rfc822). Deeper nodes stay leaves.
    public static let maxNestingDepth = 8
    /// `Task.checkCancellation` runs at least this often, in decoded bytes.
    public static let cancellationCheckpoint = 256 * 1024
    /// Safety bound so a poison multipart cannot create unbounded parts.
    public static let maxParts = 1_024
}


// MARK: - Errors & defects

/// Thrown only when the input cannot yield any result.
public enum MIMEParseError: Error, Sendable, Equatable {
    /// Zero-length input. Anything with at least one byte produces a ``MIMEMessage``.
    case emptyInput
}

/// A recorded irregularity. Partial results always carry the defects that explain them.
public struct MIMEDefect: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case headerLineTooLong
        case headerBlockTooLarge
        case textPartTruncated
        case nestingTooDeep
        case malformedBoundary
        case missingTerminalBoundary
        case brokenQuotedPrintable
        case brokenBase64
        case unknownCharset
        case charsetFallbackISO88591
        case mislabeledCharset
        case missingDate
        case malformedDate
        case eightBitHeader
        case malformedAddress
        case malformedEncodedWord
        case malformedParameter
        case missingContentType
        case invalidHeader
        case unknownTransferEncoding
    }

    public var kind: Kind
    /// IMAP section specifier of the affected part, when known.
    public var specifier: String?
    public var detail: String

    public init(kind: Kind, specifier: String? = nil, detail: String = "") {
        self.kind = kind
        self.specifier = specifier
        self.detail = detail
    }

    public var description: String {
        if let specifier, !specifier.isEmpty {
            return "\(kind.rawValue) [\(specifier)]: \(detail)"
        }
        return detail.isEmpty ? kind.rawValue : "\(kind.rawValue): \(detail)"
    }
}

// MARK: - Transfer encoding

/// `Content-Transfer-Encoding` token. Unknown values are treated as 8bit identity.
public enum ContentTransferEncoding: String, Sendable, Hashable, Codable {
    case sevenBit = "7bit"
    case eightBit = "8bit"
    case binary = "binary"
    case quotedPrintable = "quoted-printable"
    case base64 = "base64"

    public init(headerValue: String) {
        switch headerValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "7bit", "7-bit": self = .sevenBit
        case "8bit", "8-bit": self = .eightBit
        case "binary": self = .binary
        case "quoted-printable", "quotedprintable": self = .quotedPrintable
        case "base64": self = .base64
        default: self = .eightBit
        }
    }
}

// MARK: - Headers / parts / result

/// One unfolded header field. `value` is 8-bit–decoded to a string; RFC 2047 is applied by readers.
public struct MIMEHeaderField: Sendable, Hashable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One MIME entity (message root, multipart child, or leaf), numbered in IMAP section syntax.
public struct MIMEPart: Sendable, Hashable {
    /// IMAP `BODY[section]` specifier: `"1"`, `"1.2"`, `"2.1.1"`. Empty on a multipart root.
    public var specifier: String
    /// Lowercased type (`text`, `multipart`, `message`, …).
    public var type: String
    /// Lowercased subtype (`plain`, `mixed`, `rfc822`, …).
    public var subtype: String
    public var parameters: [String: String]
    public var transferEncoding: ContentTransferEncoding
    public var disposition: String?
    public var dispositionParameters: [String: String]
    public var filename: String?
    /// Content-ID without angle brackets (matches `cid:` URLs).
    public var contentID: String?
    public var headers: [MIMEHeaderField]
    public var children: [MIMEPart]
    /// Decoded Unicode text for `text/*` parts (format=flowed already reflowed).
    public var text: String?
    public var isTruncated: Bool
    /// Raw body octets (post-delimiter, pre-CTE-decode).
    public var octetCount: Int
    /// Post-CTE decoded octets (text parts are capped at ``MIMELimits/decodedTextPart``).
    public var decodedOctetCount: Int
    /// Envelope of a nested `message/rfc822` body, when parsed.
    public var nestedEnvelope: Envelope?

    public init(
        specifier: String,
        type: String,
        subtype: String,
        parameters: [String: String] = [:],
        transferEncoding: ContentTransferEncoding = .sevenBit,
        disposition: String? = nil,
        dispositionParameters: [String: String] = [:],
        filename: String? = nil,
        contentID: String? = nil,
        headers: [MIMEHeaderField] = [],
        children: [MIMEPart] = [],
        text: String? = nil,
        isTruncated: Bool = false,
        octetCount: Int = 0,
        decodedOctetCount: Int = 0,
        nestedEnvelope: Envelope? = nil
    ) {
        self.specifier = specifier
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.transferEncoding = transferEncoding
        self.disposition = disposition
        self.dispositionParameters = dispositionParameters
        self.filename = filename
        self.contentID = contentID
        self.headers = headers
        self.children = children
        self.text = text
        self.isTruncated = isTruncated
        self.octetCount = octetCount
        self.decodedOctetCount = decodedOctetCount
        self.nestedEnvelope = nestedEnvelope
    }

    public var mediaType: String { "\(type)/\(subtype)" }
    public var isMultipart: Bool { type == "multipart" }
    public var isMessageRFC822: Bool { type == "message" && subtype == "rfc822" }

    /// Depth-first walk including this node.
    public var enumerated: [MIMEPart] {
        var out: [MIMEPart] = []
        collect(into: &out)
        return out
    }

    public func part(specifiedBy specifier: String) -> MIMEPart? {
        if self.specifier == specifier { return self }
        for child in children {
            if let found = child.part(specifiedBy: specifier) { return found }
        }
        return nil
    }

    fileprivate func collect(into out: inout [MIMEPart]) {
        out.append(self)
        for child in children { child.collect(into: &out) }
    }
}

/// Decode of a single IMAP body section (`BODY.PEEK[1.2]` payload).
public struct MIMEDecodedText: Sendable, Hashable {
    public var text: String
    public var isTruncated: Bool
    public var defects: [MIMEDefect]
    public init(text: String, isTruncated: Bool, defects: [MIMEDefect]) {
        self.text = text
        self.isTruncated = isTruncated
        self.defects = defects
    }
}

/// Envelope + part tree + defects. Never silently lossy: every recovery is in `defects`.
public struct MIMEMessage: Sendable, Hashable {
    public var envelope: Envelope
    public var root: MIMEPart
    public var defects: [MIMEDefect]
    /// Preferred `text/plain` (non-attachment), format=flowed already reflowed.
    public var plainText: String?
    /// Preferred `text/html` (non-attachment). Not sanitized — the sanitizer owns that.
    public var html: String?
    /// Leaf attachments and every part that carries a Content-ID.
    public var attachments: [AttachmentInfo]

    public init(
        envelope: Envelope,
        root: MIMEPart,
        defects: [MIMEDefect],
        plainText: String?,
        html: String?,
        attachments: [AttachmentInfo]
    ) {
        self.envelope = envelope
        self.root = root
        self.defects = defects
        self.plainText = plainText
        self.html = html
        self.attachments = attachments
    }

    /// BODYSTRUCTURE-equivalent walk (root and descendants) in depth-first order.
    public var parts: [MIMEPart] { root.enumerated }

    public func part(specifiedBy specifier: String) -> MIMEPart? {
        root.part(specifiedBy: specifier)
    }
}

// MARK: - Parser

/// Pure-Swift RFC 5322 / MIME parser.
///
/// Call ``parse(_:internalDate:)`` on a complete `message/rfc822` buffer (IMAP
/// `BODY.PEEK[]`). Wave-2 fetches individual sections with ``decodeTextPart``.
public enum MIMEParser: Sendable {
    /// Parse a complete RFC 5322 message.
    ///
    /// - Parameters:
    ///   - rfc822: Raw message bytes (CRLF or LF). Must be non-empty.
    ///   - internalDate: IMAP `INTERNALDATE` (stored on ``Envelope/internalDate``).
    /// - Throws: ``MIMEParseError/emptyInput`` when `rfc822` is empty;
    ///   `CancellationError` when the current task is cancelled (checked at
    ///   start and at least every 256 KiB decoded).
    /// - Returns: Envelope, part tree, preferred bodies, attachments, and defects.
    public static func parse(_ rfc822: Data, internalDate: Date = Date()) throws -> MIMEMessage {
        try Task.checkCancellation()
        guard !rfc822.isEmpty else { throw MIMEParseError.emptyInput }

        let data = contiguousZeroBased(rfc822)
        let state = ParseState()
        let (root, envelope) = try parseRFC822(
            data,
            specifier: "",
            depth: 0,
            state: state,
            internalDate: internalDate,
            defaultType: ("text", "plain")
        )
        var tree = root
        if !tree.isMultipart && !tree.isMessageRFC822 && tree.specifier.isEmpty {
            tree.specifier = "1"
        }
        let (plain, html) = selectPreferredBodies(tree)
        let attachments = collectAttachments(tree)
        return MIMEMessage(
            envelope: envelope,
            root: tree,
            defects: state.defects,
            plainText: plain,
            html: html,
            attachments: attachments
        )
    }

    /// Decode one text body section (IMAP `BODY.PEEK[section]` bytes).
    ///
    /// Applies CTE decode, charset conversion (ISO-8859-1 fallback), the 8 MiB
    /// cap, and `format=flowed` when `parameters` say so. Checkpoints cancellation
    /// the same way as ``parse(_:internalDate:)``.
    public static func decodeTextPart(
        _ data: Data,
        mediaType: String,
        charset: String? = nil,
        encoding: ContentTransferEncoding = .sevenBit,
        parameters: [String: String] = [:],
        specifier: String? = nil
    ) throws -> MIMEDecodedText {
        try Task.checkCancellation()
        let state = ParseState()
        let (decoded, truncated) = try decodeTransferEncoding(
            data,
            encoding: encoding,
            state: state,
            specifier: specifier,
            cap: MIMELimits.decodedTextPart
        )
        if truncated {
            state.record(.textPartTruncated, specifier: specifier, "decoded text part exceeded 8 MiB")
        }
        var text = decodeCharset(decoded, charset: charset, state: state, specifier: specifier)
        let subtype = mediaType.split(separator: "/", maxSplits: 1).dropFirst().first
            .map { String($0).lowercased() } ?? ""
        if subtype == "plain", (parameters["format"] ?? "").lowercased() == "flowed" {
            let delsp = (parameters["delsp"] ?? "").lowercased() == "yes"
            text = reflowFormatFlowed(text, delsp: delsp)
        }
        return MIMEDecodedText(text: text, isTruncated: truncated, defects: state.defects)
    }
}
