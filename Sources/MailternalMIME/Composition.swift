import Foundation
import MailternalInterfaces
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A complete outbound RFC 5322 message before SMTP submission.
///
/// The caller owns every attachment file and must keep it immutable for the
/// duration of ``MIMEComposer/write(_:to:)``. The composer reads attachments
/// incrementally and never removes or changes them. A successful write creates a
/// new private file at the requested destination; a failed write removes its
/// partial output.
public struct MIMEComposition: Sendable {
    /// An immutable staged file to add as a MIME attachment.
    public struct Attachment: Sendable {
        public let fileURL: URL
        public let filename: String
        public let mimeType: String

        public init(fileURL: URL, filename: String, mimeType: String) {
            self.fileURL = fileURL
            self.filename = filename
            self.mimeType = mimeType
        }
    }

    public let from: MailAddress
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let bcc: [MailAddress]
    public let replyTo: [MailAddress]
    public let subject: String
    public let plainText: String
    public let html: String?
    public let messageID: String
    public let date: Date
    public let inReplyTo: String?
    public let references: [String]
    public let attachments: [Attachment]

    public init(
        from: MailAddress,
        to: [MailAddress],
        cc: [MailAddress],
        bcc: [MailAddress],
        replyTo: [MailAddress],
        subject: String,
        plainText: String,
        html: String?,
        messageID: String,
        date: Date,
        inReplyTo: String?,
        references: [String],
        attachments: [Attachment]
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.plainText = plainText
        self.html = html
        self.messageID = messageID
        self.date = date
        self.inReplyTo = inReplyTo
        self.references = references
        self.attachments = attachments
    }
}

/// Failure raised while validating or creating a composed message file.
public enum MIMECompositionError: Error, Sendable, Equatable {
    case destinationIsNotFileURL
    case destinationExists
    case cannotCreateDestination(String)
    case invalidAddress(String)
    case invalidHeaderValue(String)
    case invalidMessageID(String)
    case invalidAttachment(String)
    case attachmentIsNotRegularFile(String)
    case attachmentReadFailed(String)
    case outputWriteFailed(String)
}

/// The SMTP routing envelope and exact size of one successfully composed file.
public struct MIMECompositionResult: Sendable, Hashable {
    public let envelope: SMTPEnvelope
    public let byteCount: Int64

    public init(envelope: SMTPEnvelope, byteCount: Int64) {
        self.envelope = envelope
        self.byteCount = byteCount
    }
}

/// RFC 5322/MIME serializer with bounded attachment streaming.
public enum MIMEComposer: Sendable {
    /// Composes `message` into a newly created private regular file.
    ///
    /// `destination` must not already exist. The destination is created with
    /// mode `0600` before any bytes are written and is never overwritten. If
    /// validation, attachment reading, or output writing fails, the partial
    /// destination is removed. Attachment files are opened read-only and are
    /// expected to remain immutable until this method returns.
    /// Text line endings are canonical CRLF. A single-part text body's final
    /// unterminated line receives CRLF so the file can be submitted as SMTP DATA.
    ///
    /// - Throws: ``MIMECompositionError`` for invalid message data, collisions,
    ///   non-regular attachments, or failed output; underlying Foundation file
    ///   errors may also be propagated for filesystem failures.
    public static func write(
        _ message: MIMEComposition,
        to destination: URL
    ) throws -> MIMECompositionResult {
        guard destination.isFileURL else {
            throw MIMECompositionError.destinationIsNotFileURL
        }

        let prepared = try PreparedComposition(message)
        let descriptor = try destination.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw MIMECompositionError.cannotCreateDestination(destination.path)
            }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                if errno == EEXIST { throw MIMECompositionError.destinationExists }
                throw MIMECompositionError.cannotCreateDestination(destination.path)
            }
            return descriptor
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var writer = MIMEOutputWriter(handle: handle)
            try writer.write(prepared)
            try handle.synchronize()
            try handle.close()
            return MIMECompositionResult(
                envelope: prepared.envelope,
                byteCount: writer.byteCount
            )
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            if let error = error as? MIMECompositionError { throw error }
            throw MIMECompositionError.outputWriteFailed(error.localizedDescription)
        }
    }
}

private struct PreparedComposition: Sendable {
    let message: MIMEComposition
    let from: String
    let to: [String]
    let cc: [String]
    let replyTo: [String]
    let messageID: String
    let inReplyTo: String?
    let references: [String]
    let envelope: SMTPEnvelope
    let boundary: String?
    let alternativeBoundary: String?

    init(_ message: MIMEComposition) throws {
        self.message = message
        self.from = try renderAddress(message.from)
        self.to = try renderVisibleAddresses(message.to)
        self.cc = try renderVisibleAddresses(message.cc)
        self.replyTo = try renderVisibleAddresses(message.replyTo)
        self.messageID = try normalizeMessageID(message.messageID, field: "Message-ID")
        self.inReplyTo = try message.inReplyTo.map {
            try normalizeMessageID($0, field: "In-Reply-To")
        }
        self.references = try message.references.map {
            try normalizeMessageID($0, field: "References")
        }
        try validateHeaderSafe(message.subject, field: "Subject")
        for attachment in message.attachments {
            try validateAttachment(attachment)
        }
        for address in message.bcc {
            _ = try splitAndValidateAddress(address.address)
        }

        let envelopeAddresses = deduplicateRoutingAddresses(
            Array([message.to, message.cc, message.bcc].joined())
        )
        let envelopeRecipients = envelopeAddresses.map(\.address)
        self.envelope = SMTPEnvelope(
            sender: message.from.address,
            recipients: envelopeRecipients,
            requiresSMTPUTF8: containsNonASCII(from)
                || envelopeRecipients.contains(where: containsNonASCII)
                || replyTo.contains(where: containsNonASCII)
                || containsNonASCII(messageID)
                || inReplyTo.map(containsNonASCII) == true
                || references.contains(where: containsNonASCII)
        )
        self.alternativeBoundary = message.html != nil && !message.attachments.isEmpty ? makeBoundary() : nil
        if message.attachments.isEmpty {
            self.boundary = message.html == nil ? nil : makeBoundary()
        } else {
            self.boundary = makeBoundary()
        }
    }
}

private struct MIMEOutputWriter {
    private let handle: FileHandle
    private(set) var byteCount: Int64 = 0
    private let preferredLineLength = 78
    private let hardLineLength = 998

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func write(_ prepared: PreparedComposition) throws {
        let message = prepared.message
        try writeHeader("Date", formatRFC5322Date(message.date))
        try writeHeader("From", prepared.from)
        if !prepared.to.isEmpty {
            try writeHeader("To", prepared.to.joined(separator: ", "))
        }
        if !prepared.cc.isEmpty {
            try writeHeader("Cc", prepared.cc.joined(separator: ", "))
        }
        if !prepared.replyTo.isEmpty {
            try writeHeader("Reply-To", prepared.replyTo.joined(separator: ", "))
        }
        try writeHeader("Subject", renderSubject(message.subject))
        try writeHeader("Message-ID", prepared.messageID)
        if let inReplyTo = prepared.inReplyTo {
            try writeHeader("In-Reply-To", inReplyTo)
        }
        if !prepared.references.isEmpty {
            try writeHeader("References", prepared.references.joined(separator: " "))
        }
        try writeHeader("MIME-Version", "1.0")

        if message.attachments.isEmpty {
            if let boundary = prepared.boundary {
                try writeHeader("Content-Type", "multipart/alternative; boundary=\"\(boundary)\"")
                try writeCRLF()
                try writeAlternativeBody(boundary: boundary, message: message)
            } else {
                try writeHeader("Content-Type", "text/plain; charset=utf-8")
                try writeHeader("Content-Transfer-Encoding", "quoted-printable")
                try writeCRLF()
                try writeQuotedPrintable(message.plainText)
                if let last = message.plainText.utf8.last, last != 13 && last != 10 {
                    try writeCRLF()
                }
            }
        } else {
            let boundary = prepared.boundary!
            try writeHeader("Content-Type", "multipart/mixed; boundary=\"\(boundary)\"")
            try writeCRLF()
            try writeBoundary(boundary, closing: false)
            if let html = message.html {
                let alternativeBoundary = prepared.alternativeBoundary!
                try writeAlternativeEntity(
                    boundary: alternativeBoundary,
                    plainText: message.plainText,
                    html: html
                )
            } else {
                try writeTextPart(message.plainText, subtype: "plain")
            }
            for attachment in message.attachments {
                try writeBoundary(boundary, closing: false)
                try writeAttachmentPart(attachment)
            }
            try writeBoundary(boundary, closing: true)
        }
    }

    private mutating func writeAlternativeBody(
        boundary: String,
        message: MIMEComposition
    ) throws {
        try writeBoundary(boundary, closing: false)
        try writeTextPart(message.plainText, subtype: "plain")
        try writeBoundary(boundary, closing: false)
        try writeTextPart(message.html!, subtype: "html")
        try writeBoundary(boundary, closing: true)
    }

    private mutating func writeAlternativeEntity(
        boundary: String,
        plainText: String,
        html: String
    ) throws {
        try writeHeader("Content-Type", "multipart/alternative; boundary=\"\(boundary)\"")
        try writeCRLF()
        try writeBoundary(boundary, closing: false)
        try writeTextPart(plainText, subtype: "plain")
        try writeBoundary(boundary, closing: false)
        try writeTextPart(html, subtype: "html")
        try writeBoundary(boundary, closing: true)
    }

    private mutating func writeTextPart(_ text: String, subtype: String) throws {
        try writeHeader("Content-Type", "text/\(subtype); charset=utf-8")
        try writeHeader("Content-Transfer-Encoding", "quoted-printable")
        try writeCRLF()
        try writeQuotedPrintable(text)
        try writeCRLF()
    }

    private mutating func writeAttachmentPart(_ attachment: MIMEComposition.Attachment) throws {
        let type = try normalizedMIMEType(attachment.mimeType)
        let filename = renderFilenameParameters(attachment.filename)
        // MIME must not repeat a parameter as both filename and filename*:
        // clients may keep the first value and lose the Unicode filename.
        let parameter = filename.extended.map { "*=\($0)" } ?? "=\"\(filename.fallback)\""
        try writeHeader(
            "Content-Type",
            "\(type); name\(parameter)"
        )
        try writeHeader(
            "Content-Disposition",
            "attachment; filename\(parameter)"
        )
        try writeHeader("Content-Transfer-Encoding", "base64")
        try writeCRLF()
        try writeBase64Attachment(attachment.fileURL)
        try writeCRLF()
    }

    private mutating func writeHeader(_ name: String, _ value: String) throws {
        guard !name.isEmpty,
              !name.contains("\r"),
              !name.contains("\n"),
              !value.contains("\r"),
              !value.contains("\n") else {
            throw MIMECompositionError.invalidHeaderValue(name)
        }

        let prefix = Array("\(name): ".utf8)
        var remaining = Array(value.utf8)[...]
        var first = true
        while true {
            let indent = first ? prefix.count : 1
            let preferred = preferredLineLength - indent
            let hard = hardLineLength - indent
            var cut: ArraySlice<UInt8>.Index?
            if remaining.count > preferred {
                cut = remaining.prefix(preferred + 1).lastIndex(of: 32)
                if cut == remaining.startIndex { cut = nil }
                if cut == nil, remaining.count > hard {
                    cut = remaining.prefix(hard + 1).lastIndex(of: 32)
                    guard let cut, cut > remaining.startIndex else {
                        throw MIMECompositionError.invalidHeaderValue(name)
                    }
                }
            }
            try writeBytes(first ? prefix : [32])
            guard let cut else {
                try writeBytes(remaining)
                try writeCRLF()
                return
            }
            try writeBytes(remaining[..<cut])
            try writeCRLF()
            remaining = remaining[remaining.index(after: cut)...]
            first = false
        }
    }


    private mutating func writeBoundary(_ boundary: String, closing: Bool) throws {
        try writeBytes(Array("--\(boundary)\(closing ? "--" : "")\r\n".utf8))
    }

    private mutating func writeCRLF() throws {
        try writeBytes([13, 10])
    }


    private mutating func writeBytes<S: Sequence>(_ bytes: S) throws where S.Element == UInt8 {
        let data = Data(bytes)
        do {
            try handle.write(contentsOf: data)
            byteCount += Int64(data.count)
        } catch {
            throw MIMECompositionError.outputWriteFailed(error.localizedDescription)
        }
    }

    private mutating func writeQuotedPrintable(_ text: String) throws {
        var output: [UInt8] = []
        output.reserveCapacity(64 * 1024)
        var column = 0
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 13 || byte == 10 {
                if byte == 13 || !previousWasCR {
                    output.append(contentsOf: [13, 10])
                }
                previousWasCR = byte == 13
                column = 0
            } else {
                previousWasCR = false
                let isPrintable = (33...60).contains(byte) || (62...126).contains(byte)
                let tokenLength = isPrintable ? 1 : 3
                if column + tokenLength > 75 {
                    output.append(contentsOf: [61, 13, 10])
                    column = 0
                }
                if isPrintable {
                    output.append(byte)
                } else {
                    output.append(61)
                    let high = byte >> 4
                    let low = byte & 0x0F
                    output.append(high < 10 ? high + 48 : high + 55)
                    output.append(low < 10 ? low + 48 : low + 55)
                }
                column += tokenLength
            }
            if output.count >= 64 * 1024 {
                try writeBytes(output)
                output.removeAll(keepingCapacity: true)
            }
        }
        if !output.isEmpty { try writeBytes(output) }
    }

    private mutating func writeBase64Attachment(_ url: URL) throws {
        let fileManager = FileManager.default
        guard url.isFileURL else {
            throw MIMECompositionError.attachmentIsNotRegularFile(url.path)
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular else {
                throw MIMECompositionError.attachmentIsNotRegularFile(url.path)
            }
        } catch let error as MIMECompositionError {
            throw error
        } catch {
            throw MIMECompositionError.attachmentReadFailed(url.path)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw MIMECompositionError.attachmentReadFailed(url.path)
        }
        defer { try? handle.close() }

        var carry: [UInt8] = []
        var output: [UInt8] = []
        output.reserveCapacity(64 * 1024)
        var column = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                throw MIMECompositionError.attachmentReadFailed(url.path)
            }
            guard let chunk, !chunk.isEmpty else { break }

            var bytes = carry
            bytes.append(contentsOf: chunk)
            let completeCount = (bytes.count / 3) * 3
            var index = 0
            while index < completeCount {
                let a = bytes[index]
                let b = bytes[index + 1]
                let c = bytes[index + 2]
                try appendBase64Quartet(
                    base64Alphabet[Int(a >> 2)],
                    base64Alphabet[Int(((a & 0x03) << 4) | (b >> 4))],
                    base64Alphabet[Int(((b & 0x0F) << 2) | (c >> 6))],
                    base64Alphabet[Int(c & 0x3F)],
                    output: &output,
                    column: &column
                )
                index += 3
            }
            carry = index < bytes.count ? Array(bytes[index...]) : []
        }

        if !carry.isEmpty {
            let a = carry[0]
            let b = carry.count > 1 ? carry[1] : 0
            let second = base64Alphabet[Int(((a & 0x03) << 4) | (b >> 4))]
            if carry.count == 1 {
                try appendBase64Quartet(
                    base64Alphabet[Int(a >> 2)], second, 61, 61,
                    output: &output, column: &column
                )
            } else {
                try appendBase64Quartet(
                    base64Alphabet[Int(a >> 2)],
                    second,
                    base64Alphabet[Int((b & 0x0F) << 2)],
                    61,
                    output: &output,
                    column: &column
                )
            }
        }
        if !output.isEmpty {
            try writeBytes(output)
        }
    }
    private mutating func appendBase64Quartet(
        _ first: UInt8,
        _ second: UInt8,
        _ third: UInt8,
        _ fourth: UInt8,
        output: inout [UInt8],
        column: inout Int
    ) throws {
        if column + 4 > 76 {
            output.append(contentsOf: [13, 10])
            column = 0
        }
        output.append(first)
        output.append(second)
        output.append(third)
        output.append(fourth)
        column += 4
        if output.count >= 64 * 1024 {
            try writeBytes(output)
            output.removeAll(keepingCapacity: true)
        }
    }
}

private let base64Alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

private func renderVisibleAddresses(_ addresses: [MailAddress]) throws -> [String] {
    try addresses.map(renderAddress)
}

private func renderAddress(_ address: MailAddress) throws -> String {
    _ = try splitAndValidateAddress(address.address)
    if let displayName = address.displayName, !displayName.isEmpty {
        try validateHeaderSafe(displayName, field: "display name")
        let renderedName: String
        if containsNonASCII(displayName) {
            renderedName = encode2047(displayName)
        } else if displayName.unicodeScalars.allSatisfy(isPhraseCharacter) {
            renderedName = displayName
        } else {
            let escaped = displayName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            renderedName = "\"\(escaped)\""
        }
        return "\(renderedName) <\(address.address)>"
    }
    return address.address
}

private func isPhraseCharacter(_ scalar: UnicodeScalar) -> Bool {
    if scalar == " " { return true }
    if scalar.value >= 65 && scalar.value <= 90 { return true }
    if scalar.value >= 97 && scalar.value <= 122 { return true }
    if scalar.value >= 48 && scalar.value <= 57 { return true }
    return "!#$%&'*+-/=?^_`{|}~".unicodeScalars.contains(scalar)
}

private func renderSubject(_ subject: String) -> String {
    containsNonASCII(subject) ? encode2047(subject) : subject
}

private func encode2047(_ value: String) -> String {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty else { return "" }
    var words: [String] = []
    var start = 0
    while start < bytes.count {
        var end = min(start + 45, bytes.count)
        while end > start, end < bytes.count, (bytes[end] & 0xC0) == 0x80 {
            end -= 1
        }
        if end == start { end = min(start + 45, bytes.count) }
        let encoded = Data(bytes[start..<end]).base64EncodedString()
        words.append("=?UTF-8?B?\(encoded)?=")
        start = end
    }
    return words.joined(separator: " ")
}

private func validateHeaderSafe(_ value: String, field: String) throws {
    for scalar in value.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F {
            throw MIMECompositionError.invalidHeaderValue(field)
        }
    }
}

private func splitAndValidateAddress(_ value: String) throws -> (local: String, domain: String) {
    guard !value.isEmpty else { throw MIMECompositionError.invalidAddress(value) }
    let scalars = Array(value.unicodeScalars)
    var quoted = false
    var escaped = false
    var at: Int?
    for (index, scalar) in scalars.enumerated() {
        if scalar.value < 0x20 || scalar.value == 0x7F {
            if !(quoted && scalar == "\t") {
                throw MIMECompositionError.invalidAddress(value)
            }
        }
        if (scalar == " " || scalar == "\t") && !quoted {
            throw MIMECompositionError.invalidAddress(value)
        }
        if escaped {
            escaped = false
            continue
        }
        if quoted && scalar == "\\" {
            escaped = true
            continue
        }
        if scalar == "\"" {
            quoted.toggle()
        } else if scalar == "@" && !quoted {
            guard at == nil else { throw MIMECompositionError.invalidAddress(value) }
            at = index
        }
    }
    guard !quoted, !escaped, let at, at > 0, at + 1 < scalars.count else {
        throw MIMECompositionError.invalidAddress(value)
    }

    let local = String(String.UnicodeScalarView(scalars[..<at]))
    let domain = String(String.UnicodeScalarView(scalars[(at + 1)...]))
    try validateLocalPart(local, original: value)
    try validateDomain(domain, original: value)
    return (local, domain)
}

private func validateLocalPart(_ local: String, original: String) throws {
    let scalars = Array(local.unicodeScalars)
    guard !scalars.isEmpty else { throw MIMECompositionError.invalidAddress(original) }
    if scalars.first == "\"" || scalars.last == "\"" {
        guard scalars.count >= 2, scalars.first == "\"", scalars.last == "\"" else {
            throw MIMECompositionError.invalidAddress(original)
        }
        var escaped = false
        for scalar in scalars.dropFirst().dropLast() {
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == "\"" || scalar.value < 0x20 || scalar.value == 0x7F {
                throw MIMECompositionError.invalidAddress(original)
            }
        }
        guard !escaped else { throw MIMECompositionError.invalidAddress(original) }
        return
    }

    let allowed = "!#$%&'*+-/=?^_`{|}~".unicodeScalars
    var atomLength = 0
    for scalar in scalars {
        let isASCIIAtom = scalar.value < 128 &&
            ((scalar.value >= 65 && scalar.value <= 90) ||
             (scalar.value >= 97 && scalar.value <= 122) ||
             (scalar.value >= 48 && scalar.value <= 57) ||
             allowed.contains(scalar))
        if scalar == "." {
            guard atomLength > 0 else { throw MIMECompositionError.invalidAddress(original) }
            atomLength = 0
        } else if isASCIIAtom || scalar.value >= 128 {
            atomLength += 1
        } else {
            throw MIMECompositionError.invalidAddress(original)
        }
    }
    guard atomLength > 0 else { throw MIMECompositionError.invalidAddress(original) }
}

private func validateDomain(_ domain: String, original: String) throws {
    let scalars = Array(domain.unicodeScalars)
    guard !scalars.isEmpty else { throw MIMECompositionError.invalidAddress(original) }
    if scalars.first == "[" || scalars.last == "]" {
        guard scalars.count >= 3, scalars.first == "[", scalars.last == "]" else {
            throw MIMECompositionError.invalidAddress(original)
        }
        for scalar in scalars.dropFirst().dropLast() {
            guard scalar.value >= 0x21, scalar.value <= 0x7E, scalar != "[", scalar != "]" else {
                throw MIMECompositionError.invalidAddress(original)
            }
        }
        return
    }
    var labelLength = 0
    var previous: UnicodeScalar?
    for scalar in scalars {
        if scalar == "." {
            guard labelLength > 0, previous != "-" else {
                throw MIMECompositionError.invalidAddress(original)
            }
            labelLength = 0
            previous = nil
            continue
        }
        guard scalar.value >= 128 || scalar.value == 45 || scalar.value == 95 ||
            (scalar.value >= 65 && scalar.value <= 90) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) else {
            throw MIMECompositionError.invalidAddress(original)
        }
        if labelLength == 0, scalar == "-" {
            throw MIMECompositionError.invalidAddress(original)
        }
        labelLength += 1
        previous = scalar
    }
    guard labelLength > 0, previous != "-" else {
        throw MIMECompositionError.invalidAddress(original)
    }
}

private func normalizeMessageID(_ raw: String, field: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw MIMECompositionError.invalidMessageID(field) }
    try validateHeaderSafe(value, field: field)
    guard !value.unicodeScalars.contains(where: { isIDWhitespace($0) }) else {
        throw MIMECompositionError.invalidMessageID(field)
    }
    let identifier: String
    if value.first == "<" || value.last == ">" {
        guard value.first == "<", value.last == ">" else {
            throw MIMECompositionError.invalidMessageID(field)
        }
        identifier = String(value.dropFirst().dropLast())
    } else {
        identifier = value
    }
    guard !identifier.contains("<"), !identifier.contains(">"),
          (try? splitAndValidateAddress(identifier)) != nil else {
        throw MIMECompositionError.invalidMessageID(field)
    }
    return "<\(identifier)>"
}

private func isIDWhitespace(_ scalar: UnicodeScalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
}
private func validateAttachment(_ attachment: MIMEComposition.Attachment) throws {
    guard attachment.fileURL.isFileURL else {
        throw MIMECompositionError.invalidAttachment(attachment.filename)
    }
    try validateHeaderSafe(attachment.filename, field: "attachment filename")
    _ = try normalizedMIMEType(attachment.mimeType)
    guard !attachment.filename.isEmpty else {
        throw MIMECompositionError.invalidAttachment("empty filename")
    }
}

private func normalizedMIMEType(_ raw: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
          parts.allSatisfy({ $0.unicodeScalars.allSatisfy(isTokenCharacter) }) else {
        throw MIMECompositionError.invalidAttachment(raw)
    }
    return value
}

private func isTokenCharacter(_ scalar: UnicodeScalar) -> Bool {
    guard scalar.value >= 0x21, scalar.value <= 0x7E else { return false }
    return !"()<>@,;:\\\"/[]?=".unicodeScalars.contains(scalar)
}

private func renderFilenameParameters(_ raw: String) -> (fallback: String, extended: String?) {
    let fallbackScalars = raw.unicodeScalars.map { scalar -> Character in
        if scalar.value >= 0x20 && scalar.value <= 0x7E && scalar != "\"" && scalar != "\\" {
            return Character(String(scalar))
        }
        return "_"
    }
    let fallback = fallbackScalars.isEmpty ? "attachment" : String(fallbackScalars)
    let allowed = "!#$&+-.^_`|~".unicodeScalars
    let needsExtended = raw.utf8.contains { byte in
        !((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
          (byte >= 48 && byte <= 57) ||
          allowed.contains(UnicodeScalar(Int(byte))!))
    }
    guard needsExtended else { return (fallback, nil) }
    let encoded = raw.utf8.map { byte -> String in
        let scalar = UnicodeScalar(Int(byte))!
        if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) || allowed.contains(scalar) {
            return String(scalar)
        }
        return String(format: "%%%02X", byte)
    }.joined()
    return (fallback, "UTF-8''\(encoded)")
}

private func deduplicateRoutingAddresses(_ addresses: [MailAddress]) -> [MailAddress] {
    var seen = Set<String>()
    var result: [MailAddress] = []
    for address in addresses {
        guard let split = try? splitAndValidateAddress(address.address) else { continue }
        let key = "\(split.local)@\(split.domain.lowercased())"
        if seen.insert(key).inserted {
            result.append(address)
        }
    }
    return result
}

private func containsNonASCII(_ value: String) -> Bool {
    value.utf8.contains { $0 >= 128 }
}

private func makeBoundary() -> String {
    "=_Mailternal_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
}

private func formatRFC5322Date(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][calendar.component(.weekday, from: date) - 1]
    let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][calendar.component(.month, from: date) - 1]
    let day = calendar.component(.day, from: date)
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    let second = calendar.component(.second, from: date)
    let year = calendar.component(.year, from: date)
    return String(format: "%@, %02d %@ %04d %02d:%02d:%02d +0000", weekday, day, month, year, hour, minute, second)
}
