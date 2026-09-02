import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalMIME
import MailternalSanitizer
import MailternalStore

enum MessageAssembler: Sendable {
    struct TextNeed: Sendable {
        var specifier: String
        var subtype: String
        var charset: String?
        var encoding: String?
        var octets: Int
    }

    static func textPartOctets(_ node: IMAPBodyStructure) -> Int64 {
        if node.type == "text" {
            return Int64(node.octetCount ?? 0)
        }
        return node.children.reduce(Int64(0)) { $0 + textPartOctets($1) }
    }

    static func textNeeds(_ node: IMAPBodyStructure) -> [TextNeed] {
        var needs: [TextNeed] = []
        collectText(node, into: &needs)
        return needs
    }

    static func attachments(_ node: IMAPBodyStructure) -> [AttachmentInfo] {
        var list: [AttachmentInfo] = []
        collectAttachments(node, into: &list)
        return list
    }

    static func peekSpecifier(_ node: IMAPBodyStructure) -> String {
        node.partSpecifier.isEmpty ? "1" : node.partSpecifier
    }

    static func incoming(
        generation: MailboxGeneration,
        fetched: IMAPFetchedMessage,
        bodyParts: [IMAPPeekedPart],
        now: Date
    ) -> IncomingMessage {
        let uidValue = fetched.uid ?? 0
        let uid = IMAPUID(rawValue: uidValue)
        let date = fetched.internalDate ?? now
        let flags = SyncPolicy.messageFlags(fetched.flags)
        let structure = fetched.bodyStructure
        var attachments = structure.map(Self.attachments) ?? []

        var envelope = fetched.envelope.map { imapEnvelope($0, internalDate: date, references: []) }
            ?? placeholderEnvelope(date: date)
        if let header = headerData(from: fetched.parts) ?? headerData(from: bodyParts) {
            if let parsed = try? MIMEParser.parse(ensureRFC822(header), internalDate: date) {
                envelope = parsed.envelope
                if attachments.isEmpty {
                    attachments = parsed.attachments
                }
            }
        }

        guard uidValue > 0 else {
            return IncomingMessage(
                generation: generation,
                uid: uid,
                envelope: envelope,
                flags: flags,
                isQuarantined: true,
                parseDefect: "FETCH missing UID",
                decodedBytes: 0
            )
        }

        let needs = structure.map(textNeeds) ?? []
        var plain: String?
        var html: String?
        var truncated = false
        var defects: [String] = []
        var decoded = 0

        for need in needs {
            guard let data = partData(specifier: need.specifier, in: bodyParts) ?? partData(specifier: need.specifier, in: fetched.parts) else {
                continue
            }
            do {
                let decodedPart = try MIMEParser.decodeTextPart(
                    data,
                    mediaType: "text/\(need.subtype)",
                    charset: need.charset,
                    encoding: ContentTransferEncoding(headerValue: need.encoding ?? "7bit"),
                    specifier: need.specifier
                )
                decoded += decodedPart.text.utf8.count
                truncated = truncated || decodedPart.isTruncated
                if !decodedPart.defects.isEmpty {
                    defects.append(contentsOf: decodedPart.defects.map(\.description))
                }
                if need.subtype == "html" {
                    html = decodedPart.text
                } else {
                    plain = decodedPart.text
                }
            } catch {
                defects.append("decode \(need.specifier): \(error)")
            }
        }

        var sanitized: String?
        if let html {
            sanitized = HTMLSanitizer.sanitize(html).html
        }

        let missingText = !needs.isEmpty && needs.allSatisfy {
            partData(specifier: $0.specifier, in: bodyParts) == nil
                && partData(specifier: $0.specifier, in: fetched.parts) == nil
        }
        let quarantine = (fetched.envelope == nil && fetched.bodyStructure == nil && bodyParts.isEmpty)
            || missingText
        return IncomingMessage(
            generation: generation,
            uid: uid,
            envelope: envelope,
            flags: flags,
            bodyText: plain,
            sanitizedHTML: sanitized,
            attachments: attachments,
            isTruncated: truncated,
            isQuarantined: quarantine,
            parseDefect: {
                if !defects.isEmpty { return defects.joined(separator: "; ") }
                if missingText { return "missing text parts" }
                if quarantine { return "empty FETCH payload" }
                return nil
            }(),
            decodedBytes: decoded
        )
    }

    static func quarantined(
        generation: MailboxGeneration,
        uid: IMAPUID,
        fetched: IMAPFetchedMessage?,
        reason: String,
        now: Date
    ) -> IncomingMessage {
        let date = fetched?.internalDate ?? now
        let envelope = fetched?.envelope.map { imapEnvelope($0, internalDate: date, references: []) }
            ?? placeholderEnvelope(date: date)
        return IncomingMessage(
            generation: generation,
            uid: uid,
            envelope: envelope,
            flags: SyncPolicy.messageFlags(fetched?.flags ?? []),
            isQuarantined: true,
            parseDefect: reason,
            decodedBytes: 0
        )
    }

    static func escapeRaw(_ data: Data) -> String {
        let slice = data.prefix(SyncPolicy.rawSourceCap)
        let text = String(decoding: slice, as: UTF8.self)
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func senderDisplay(_ envelope: Envelope) -> String {
        guard let first = envelope.from.first else { return "" }
        if let name = first.displayName, !name.isEmpty { return name }
        return first.address
    }

    // MARK: - private

    private static func collectText(_ node: IMAPBodyStructure, into out: inout [TextNeed]) {
        if node.type == "multipart" {
            for child in node.children { collectText(child, into: &out) }
            return
        }
        if node.type == "message" {
            for child in node.children { collectText(child, into: &out) }
            return
        }
        let subtype = node.subtype
        if node.type == "text", (subtype == "plain" || subtype == "html"), node.filename == nil {
            out.append(TextNeed(
                specifier: peekSpecifier(node),
                subtype: subtype,
                charset: node.charset,
                encoding: node.encoding,
                octets: node.octetCount ?? 0
            ))
        }
    }

    private static func collectAttachments(_ node: IMAPBodyStructure, into out: inout [AttachmentInfo]) {
        if node.type == "multipart" {
            for child in node.children { collectAttachments(child, into: &out) }
            return
        }
        if node.type == "message" {
            for child in node.children { collectAttachments(child, into: &out) }
            return
        }
        let isBodyText = node.type == "text"
            && (node.subtype == "plain" || node.subtype == "html")
            && node.filename == nil
        if isBodyText { return }
        out.append(AttachmentInfo(
            id: peekSpecifier(node),
            filename: node.filename,
            mimeType: "\(node.type)/\(node.subtype)",
            sizeEstimate: node.octetCount,
            contentID: stripAngles(node.contentID),
            transferEncoding: node.encoding
        ))
    }

    private static func imapEnvelope(_ imap: IMAPEnvelope, internalDate: Date, references: [String]) -> Envelope {
        Envelope(
            subject: imap.subject ?? "",
            from: imap.from.map(mailAddress),
            to: imap.to.map(mailAddress),
            cc: imap.cc.map(mailAddress),
            replyTo: imap.replyTo.map(mailAddress),
            internalDate: internalDate,
            headerDate: nil,
            rfcMessageID: imap.messageID,
            inReplyTo: imap.inReplyTo,
            references: references
        )
    }

    private static func mailAddress(_ address: IMAPAddress) -> MailAddress {
        MailAddress(displayName: address.displayName, address: address.rfc822)
    }

    private static func placeholderEnvelope(date: Date) -> Envelope {
        Envelope(
            subject: "",
            from: [],
            to: [],
            cc: [],
            replyTo: [],
            internalDate: date,
            headerDate: nil,
            rfcMessageID: nil,
            inReplyTo: nil,
            references: []
        )
    }

    private static func headerData(from parts: [IMAPPeekedPart]) -> Data? {
        parts.first(where: { $0.specifier.uppercased() == "HEADER" || $0.specifier.isEmpty && $0.data.starts(with: [UInt8]("From:".utf8)) })?.data
    }

    private static func partData(specifier: String, in parts: [IMAPPeekedPart]) -> Data? {
        let want = specifier.uppercased()
        if let exact = parts.first(where: { $0.specifier.uppercased() == want }) {
            return exact.data
        }
        if want == "1" {
            return parts.first(where: { $0.specifier.uppercased() == "TEXT" || $0.specifier.isEmpty })?.data
        }
        return nil
    }

    private static func ensureRFC822(_ header: Data) -> Data {
        if header.isEmpty { return Data("From: unknown\r\n\r\n".utf8) }
        if header.suffix(4) == Data("\r\n\r\n".utf8) || header.suffix(2) == Data("\n\n".utf8) {
            return header
        }
        var data = header
        data.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
        return data
    }

    private static func stripAngles(_ value: String?) -> String? {
        guard var value else { return nil }
        if value.first == "<" { value.removeFirst() }
        if value.last == ">" { value.removeLast() }
        return value.isEmpty ? nil : value
    }
}
