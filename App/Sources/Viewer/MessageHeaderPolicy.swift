import Foundation
import MailternalInterfaces

/// What the reader may honestly say about a message envelope and its raw
/// headers.
///
/// `Envelope` stores From, Reply-To, To, Cc, both dates, and the threading
/// headers. The on-demand raw-source path supplies the complete ordered header
/// item list when source mode is shown.
enum MessageHeaderPolicy {
    static let noSubjectPlaceholder = "(No Subject)"

    /// A raw header is returned as one logical line. Field names retain the
    /// source spelling and values are unfolded, trimmed field bodies. The
    /// sync facade escapes raw bytes for safe source rendering; decode that
    /// transport escaping once here, without touching RFC 2047 encoded words.
    static func rawHeaders(from rawSource: String) -> [HeaderItem] {
        let normalized = rawSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var headers: [HeaderItem] = []
        var currentName: String?
        var currentValue = ""

        func appendCurrent() {
            guard let currentName else { return }
            headers.append(
                HeaderItem(id: headers.count, name: currentName, value: currentValue)
            )
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

    /// One stable, ordered item for every unfolded header. The index is part
    /// of the identity because fields such as Received may occur repeatedly.
    struct HeaderItem: Identifiable, Equatable, Sendable {
        let id: Int
        let name: String
        let value: String

        /// The independently copyable header-name field.
        var keyCopyText: String {
            name
        }

        /// The independently copyable unfolded header-value field.
        var valueCopyText: String {
            value
        }

        var copyText: String {
            value.isEmpty ? "\(name):" : "\(name): \(value)"
        }
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
        rawHeaderBlock(from: rawHeaders(from: rawSource))
    }

    /// The envelope fields already available with message detail. This
    /// provisional list keeps Source useful while the complete raw source is
    /// fetched; a loaded raw header list always supersedes it in the viewer.
    static func detailHeaders(for envelope: Envelope) -> [HeaderItem] {
        var headers: [HeaderItem] = []

        func append(_ name: String, _ value: String) {
            guard !value.isEmpty else { return }
            headers.append(HeaderItem(id: headers.count, name: name, value: value))
        }

        func addressList(_ addresses: [MailAddress]) -> String {
            addresses.map(full).joined(separator: ", ")
        }

        if !envelope.from.isEmpty {
            append("From", addressList(envelope.from))
        }
        if !envelope.replyTo.isEmpty, envelope.replyTo != envelope.from {
            append("Reply-To", addressList(envelope.replyTo))
        }
        if !envelope.to.isEmpty {
            append("To", addressList(envelope.to))
        }
        if !envelope.cc.isEmpty {
            append("Cc", addressList(envelope.cc))
        }

        if let headerDate = envelope.headerDate,
           abs(headerDate.timeIntervalSince(envelope.internalDate)) >= 1 {
            append("Sent", MailDateFormat.envelope(headerDate))
            append("Received", MailDateFormat.envelope(envelope.internalDate))
        } else {
            append("Date", MailDateFormat.envelope(envelope.internalDate))
        }

        if let messageID = trimmed(envelope.rfcMessageID) {
            append("Message-ID", messageID)
        }
        if let inReplyTo = trimmed(envelope.inReplyTo) {
            append("In-Reply-To", inReplyTo)
        }
        let references = envelope.references.compactMap(trimmed)
        if !references.isEmpty {
            append("References", references.joined(separator: "\n"))
        }
        return headers
    }

    /// The copy/display representation of an already unfolded header list.
    static func rawHeaderBlock(from headers: [HeaderItem]) -> String {
        headers.map(\.copyText).joined(separator: "\n")
    }


    /// The first Received field is the server's topmost delivery hop. Its
    /// semicolon-delimited trailing date is the only delivery date we expose.
    static func deliveredDate(from headers: [HeaderItem]) -> Date? {
        guard let received = headers.first(where: {
            $0.name.caseInsensitiveCompare("Received") == .orderedSame
        }) else {
            return nil
        }
        let candidate = received.value
            .split(separator: ";", omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? received.value
        return parseHeaderDate(candidate)
    }

    static func deliveredDate(from rawSource: String) -> Date? {
        deliveredDate(from: rawHeaders(from: rawSource))
    }

    private static func parseHeaderDate(_ raw: String) -> Date? {
        var candidate = raw
        if let commentStart = candidate.firstIndex(of: "(") {
            candidate = String(candidate[..<commentStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: candidate) {
                return date
            }
        }
        return nil
    }

    /// Two-letter monograms use the first two words in a display name. A
    /// one-word name uses its first two letters; bare addresses use one.
    static func initials(for address: MailAddress) -> String {
        guard let rawName = address.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty
        else {
            return String(address.address.first ?? "?").uppercased()
        }
        let words = rawName.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2,
           let first = words[0].first,
           let second = words[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String(rawName.prefix(2)).uppercased()
    }

    /// Copying an identity always copies its address, never its display name.
    static func copyPayload(for address: MailAddress) -> String {
        address.address
    }

    struct CollapsedRecipients: Equatable, Sendable {
        let first: MailAddress
        let additionalCount: Int

        var summary: String {
            let firstName = name(of: first)
            return additionalCount > 0 ? "\(firstName) +\(additionalCount)" : firstName
        }
    }

    static func collapseRecipients(_ addresses: [MailAddress]) -> CollapsedRecipients? {
        guard let first = addresses.first else { return nil }
        return CollapsedRecipients(first: first, additionalCount: max(addresses.count - 1, 0))
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

    /// Name and address together for accessibility and identity inspection.
    static func full(_ address: MailAddress) -> String {
        let displayName = name(of: address)
        return displayName == address.address
            ? address.address
            : "\(displayName) <\(address.address)>"
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
