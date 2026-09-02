import Foundation
import MailternalInterfaces

/// What the reader may honestly say about a message envelope and its raw
/// headers.
///
/// `Envelope` stores From, Reply-To, To, Cc, both dates, and the threading
/// headers. The on-demand raw-source path supplies the complete header block
/// when the reader's Details disclosure is expanded.
enum MessageHeaderPolicy {
    static let noSubjectPlaceholder = "(No Subject)"

    /// A raw header is returned as one logical line. Field names retain the
    /// source spelling and values are unfolded, trimmed field bodies. The
    /// sync facade escapes raw bytes for safe source rendering; decode that
    /// transport escaping once here, without touching RFC 2047 encoded words.
    static func rawHeaders(from rawSource: String) -> [(name: String, value: String)] {
        let normalized = rawSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var headers: [(name: String, value: String)] = []
        var currentName: String?
        var currentValue = ""

        func appendCurrent() {
            guard let currentName else { return }
            headers.append((name: currentName, value: currentValue))
        }

        for lineSlice in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSlice)
            if line.isEmpty {
                break
            }

            if line.first == " " || line.first == "\t" {
                guard currentName != nil else { continue }
                let continuation = unescapeRawValue(
                    line.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if !continuation.isEmpty {
                    if !currentValue.isEmpty { currentValue.append(" ") }
                    currentValue.append(contentsOf: continuation)
                }
                continue
            }

            guard let colon = line.firstIndex(of: ":") else {
                appendCurrent()
                currentName = nil
                currentValue = ""
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                appendCurrent()
                currentName = nil
                currentValue = ""
                continue
            }
            appendCurrent()
            currentName = name
            currentValue = unescapeRawValue(
                line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        appendCurrent()
        return headers
    }

    /// `MessageAssembler.escapeRaw` escapes the source before crossing the
    /// facade boundary. Decode only the entities that transport uses, once:
    /// an original literal `&lt;` arrives as `&amp;lt;` and becomes `&lt;`.
    /// RFC 2047 encoded-words contain no matching entity and remain untouched.
    private static func unescapeRawValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The copy/display representation of the complete unfolded header block.
    static func rawHeaderBlock(from rawSource: String) -> String {
        rawHeaders(from: rawSource)
            .map { header in
                header.value.isEmpty
                    ? "\(header.name):"
                    : "\(header.name): \(header.value)"
            }
            .joined(separator: "\n")
    }

    struct DetailRow: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { label }
    }

    /// Subject as shown. An empty subject is a real state, so it gets a marked
    /// placeholder instead of a blank line in the strongest contrast role.
    static func subject(_ raw: String) -> (text: String, isPlaceholder: Bool) {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (noSubjectPlaceholder, true)
            : (raw, false)
    }

    /// Display name when the message carries one, otherwise the address itself.
    static func name(of address: MailAddress) -> String {
        guard let name = address.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return address.address }
        return name
    }

    /// Name and address together. A reader is where a recipient checks whether
    /// the two agree, so the address is never dropped for a display name.
    static func full(_ address: MailAddress) -> String {
        let displayName = name(of: address)
        return displayName == address.address
            ? address.address
            : "\(displayName) <\(address.address)>"
    }

    static func list(_ addresses: [MailAddress]) -> String {
        addresses.map(full).joined(separator: ", ")
    }

    /// Compact recipient line: the first recipient plus a count of the rest.
    /// `nil` for an empty group — an absent group gets no row at all rather
    /// than an invented "undisclosed recipients".
    static func summary(_ addresses: [MailAddress]) -> String? {
        guard let first = addresses.first else { return nil }
        let rest = addresses.count - 1
        return rest > 0 ? "\(name(of: first)) +\(rest)" : name(of: first)
    }

    /// The same summary as speech: "+3" is a visual abbreviation, not a label.
    static func spokenSummary(_ addresses: [MailAddress]) -> String? {
        guard let first = addresses.first else { return nil }
        let rest = addresses.count - 1
        return rest > 0 ? "\(name(of: first)) and \(rest) more" : name(of: first)
    }

    /// Every stored envelope field that carries a real value, in reading order.
    static func detailRows(for envelope: Envelope) -> [DetailRow] {
        var rows: [DetailRow] = []
        if !envelope.from.isEmpty {
            rows.append(DetailRow(label: "From", value: list(envelope.from)))
        }
        // A Reply-To that repeats From is noise, not a header the reader needs.
        if !envelope.replyTo.isEmpty, envelope.replyTo != envelope.from {
            rows.append(DetailRow(label: "Reply-To", value: list(envelope.replyTo)))
        }
        if !envelope.to.isEmpty {
            rows.append(DetailRow(label: "To", value: list(envelope.to)))
        }
        if !envelope.cc.isEmpty {
            rows.append(DetailRow(label: "Cc", value: list(envelope.cc)))
        }
        rows += dateRows(for: envelope)
        if let messageID = trimmed(envelope.rfcMessageID) {
            rows.append(DetailRow(label: "Message-ID", value: messageID))
        }
        if let inReplyTo = trimmed(envelope.inReplyTo) {
            rows.append(DetailRow(label: "In-Reply-To", value: inReplyTo))
        }
        let references = envelope.references.compactMap(trimmed)
        if !references.isEmpty {
            rows.append(DetailRow(label: "References", value: references.joined(separator: "\n")))
        }
        return rows
    }

    /// When the message was written and when the server took delivery are two
    /// different facts; they collapse into one row only when they agree.
    private static func dateRows(for envelope: Envelope) -> [DetailRow] {
        guard let headerDate = envelope.headerDate,
              abs(headerDate.timeIntervalSince(envelope.internalDate)) >= 1
        else {
            return [DetailRow(label: "Date", value: MailDateFormat.envelope(envelope.internalDate))]
        }
        return [
            DetailRow(label: "Sent", value: MailDateFormat.envelope(headerDate)),
            DetailRow(label: "Received", value: MailDateFormat.envelope(envelope.internalDate)),
        ]
    }

    /// Attachment name as shown. The IMAP part specifier is the honest fallback
    /// when a part carries no filename.
    static func attachmentName(_ attachment: AttachmentInfo) -> String {
        trimmed(attachment.filename) ?? attachment.id
    }

    static func attachmentSize(_ attachment: AttachmentInfo) -> String? {
        guard let size = attachment.sizeEstimate, size > 0 else { return nil }
        return Int64(size).formatted(.byteCount(style: .file))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}
