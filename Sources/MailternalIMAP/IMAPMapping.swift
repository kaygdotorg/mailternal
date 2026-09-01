import Foundation
import MailternalInterfaces
import NIO
import NIOIMAP

// MARK: - Role mapping (spec: sync.md Mailbox discovery)

enum IMAPRoleMapping {
    static func role(path: String, name: String, attributes: [MailboxInfo.Attribute]) -> FolderRole {
        // SPECIAL-USE wins over name heuristics.
        for attribute in attributes {
            let use = UseAttribute(attribute)
            if use == .archive { return .archive }
            if use == .trash { return .trash }
            if use == .junk { return .junk }
            if use == .sent { return .sent }
            if use == .drafts { return .drafts }
        }
        // INBOX is defined by name, case-insensitive (RFC 3501).
        if name.compare("INBOX", options: [.caseInsensitive]) == .orderedSame { return .inbox }
        if path.compare("INBOX", options: [.caseInsensitive]) == .orderedSame { return .inbox }
        return heuristic(name: name, path: path)
    }

    static func heuristic(name: String, path: String) -> FolderRole {
        let token = name.split(whereSeparator: { $0 == "/" || $0 == "." || $0 == "\\" }).last
            .map(String.init) ?? name
        let key = token.lowercased()
        switch key {
        case "inbox":
            return .inbox
        case "archive", "archives", "all mail", "allmail":
            return .archive
        case "trash", "bin", "deleted", "deleted items", "deleted messages":
            return .trash
        case "junk", "spam", "bulk", "bulk mail":
            return .junk
        case "sent", "sent items", "sent messages", "sent mail":
            return .sent
        case "drafts", "draft":
            return .drafts
        default:
            let lowerPath = path.lowercased()
            if lowerPath.hasSuffix("/inbox") || lowerPath == "inbox" { return .inbox }
            return .none
        }
    }

    static func isGmailHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "imap.gmail.com" || h == "imap.googlemail.com" { return true }
        if h == "gmail.com" || h == "googlemail.com" { return true }
        if h.hasSuffix(".gmail.com") || h.hasSuffix(".googlemail.com") { return true }
        return false
    }
}

// MARK: - UID / command construction

enum IMAPCommandFactory {
    static func uidSet(_ set: IMAPUIDSet) -> UIDSet? {
        var result = UIDSet()
        for range in set.ranges {
            let lo = max(1, range.lowerBound)
            let hi = range.upperBound
            guard lo <= hi else { continue }
            result.formUnion(UIDSet(UID(rawValue: lo)...UID(rawValue: hi)))
        }
        return result.isEmpty ? nil : result
    }

    static func peekAttribute(_ section: IMAPPeekSection) -> FetchAttribute {
        let partial: ClosedRange<UInt32>? = {
            guard let origin = section.origin else { return nil }
            let start = UInt32(clamping: max(0, origin))
            let length = section.length.map { UInt32(clamping: max(0, $0)) } ?? UInt32.max
            let end = start > UInt32.max - length ? UInt32.max : start + max(0, length) &- 1
            return start...max(start, end)
        }()

        if section.binary {
            return .binary(peek: true, section: binaryPart(from: section.specifier), partial: partial)
        }
        return .bodySection(peek: true, bodySection(from: section.specifier), partial)
    }

    static func fetchAttributes(_ request: IMAPFetchRequest) -> [FetchAttribute] {
        var attributes: [FetchAttribute] = []
        if request.uid { attributes.append(.uid) }
        if request.flags { attributes.append(.flags) }
        if request.internalDate { attributes.append(.internalDate) }
        if request.envelope { attributes.append(.envelope) }
        if request.bodyStructure { attributes.append(.bodyStructure(extensions: true)) }
        if request.rfc822Size { attributes.append(.rfc822Size) }
        if request.modSeq { attributes.append(.modificationSequence) }
        for peek in request.peek {
            attributes.append(peekAttribute(peek))
        }
        if attributes.isEmpty {
            attributes = [.uid, .flags]
        }
        return attributes
    }

    static func fetchModifiers(_ request: IMAPFetchRequest) -> [FetchModifier] {
        guard let changed = request.changedSince else { return [] }
        return [.changedSince(ChangedSinceModifier(modificationSequence: ModificationSequenceValue(changed)))]
    }

    static func bodySection(from specifier: String) -> SectionSpecifier {
        let trimmed = specifier.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return SectionSpecifier() }
        let upper = trimmed.uppercased()
        if upper == "TEXT" { return SectionSpecifier(kind: .text) }
        if upper == "HEADER" { return SectionSpecifier(kind: .header) }
        if upper == "MIME" { return SectionSpecifier(kind: .MIMEHeader) }
        if upper.hasSuffix(".MIME") {
            let head = String(trimmed.dropLast(5))
            return SectionSpecifier(part: part(from: head), kind: .MIMEHeader)
        }
        if upper.hasSuffix(".TEXT") {
            let head = String(trimmed.dropLast(5))
            return SectionSpecifier(part: part(from: head), kind: .text)
        }
        if upper.hasSuffix(".HEADER") {
            let head = String(trimmed.dropLast(7))
            return SectionSpecifier(part: part(from: head), kind: .header)
        }
        return SectionSpecifier(part: part(from: trimmed), kind: .complete)
    }

    static func binaryPart(from specifier: String) -> SectionSpecifier.Part {
        part(from: specifier)
    }

    static func part(from specifier: String) -> SectionSpecifier.Part {
        let numbers = specifier.split(separator: ".").compactMap { Int($0) }.filter { $0 > 0 }
        return SectionSpecifier.Part(numbers)
    }
}

// MARK: - FETCH assembly

struct IMAPFetchAssembler {
    private var current = IMAPFetchedMessage(
        uid: nil,
        sequence: nil,
        flags: [],
        internalDate: nil,
        envelope: nil,
        bodyStructure: nil,
        rfc822Size: nil,
        modSeq: nil,
        parts: []
    )
    private var finished: [IMAPFetchedMessage] = []
    private var streamingKind: StreamingKind?
    private var streamingBytes = ByteBuffer()
    private var inMessage = false

    mutating func apply(_ response: FetchResponse) {
        switch response {
        case .start(let sequence):
            begin(sequence: sequence.rawValue, uid: nil)
        case .startUID(let uid):
            begin(sequence: nil, uid: uid.rawValue)
        case .simpleAttribute(let attribute):
            apply(attribute)
        case .streamingBegin(let kind, _):
            streamingKind = kind
            streamingBytes.clear()
        case .streamingBytes(var buffer):
            streamingBytes.writeBuffer(&buffer)
        case .streamingEnd:
            if let kind = streamingKind {
                current.parts.append(IMAPPeekedPart(
                    specifier: specifier(for: kind),
                    binary: isBinary(kind),
                    data: Data(streamingBytes.readableBytesView)
                ))
            }
            streamingKind = nil
            streamingBytes.clear()
        case .finish:
            if inMessage {
                finished.append(current)
                inMessage = false
            }
        }
    }

    mutating func take() -> [IMAPFetchedMessage] {
        if inMessage {
            finished.append(current)
            inMessage = false
        }
        let result = finished
        finished = []
        return result
    }

    private mutating func begin(sequence: UInt32?, uid: UInt32?) {
        if inMessage {
            finished.append(current)
        }
        current = IMAPFetchedMessage(
            uid: uid,
            sequence: sequence,
            flags: [],
            internalDate: nil,
            envelope: nil,
            bodyStructure: nil,
            rfc822Size: nil,
            modSeq: nil,
            parts: []
        )
        inMessage = true
    }

    private mutating func apply(_ attribute: MessageAttribute) {
        switch attribute {
        case .uid(let uid):
            current.uid = uid.rawValue
        case .flags(let flags):
            current.flags = flags.map(flagString)
        case .internalDate(let date):
            current.internalDate = Foundation.Date(date)
        case .envelope(let envelope):
            current.envelope = IMAPEnvelope(envelope)
        case .body(let structure, hasExtensionData: _):
            if case .valid(let body) = structure {
                current.bodyStructure = IMAPBodyStructure(body, prefix: [])
            }
        case .rfc822Size(let size):
            current.rfc822Size = size
        case .fetchModificationSequence(let value):
            current.modSeq = UInt64(value)
        case .nilBody(let kind):
            current.parts.append(IMAPPeekedPart(
                specifier: specifier(for: kind),
                binary: isBinary(kind),
                data: Data()
            ))
        default:
            break
        }
    }
}

// MARK: - Envelope / body / date conversion

extension IMAPEnvelope {
    init(_ envelope: NIOIMAPCore.Envelope) {
        self.init(
            date: envelope.date.map { String($0) },
            subject: string(envelope.subject),
            from: addresses(envelope.from),
            sender: addresses(envelope.sender),
            replyTo: addresses(envelope.reply),
            to: addresses(envelope.to),
            cc: addresses(envelope.cc),
            bcc: addresses(envelope.bcc),
            inReplyTo: envelope.inReplyTo.map { String($0) },
            messageID: envelope.messageID.map { String($0) }
        )
    }
}

private func string(_ buffer: ByteBuffer?) -> String? {
    guard var buffer, buffer.readableBytes > 0 else { return nil }
    return buffer.readString(length: buffer.readableBytes)
}

private func addresses(_ list: [EmailAddressListElement]) -> [IMAPAddress] {
    list.flatMap { element -> [IMAPAddress] in
        switch element {
        case .singleAddress(let address):
            let mailbox = string(address.mailbox) ?? ""
            let host = string(address.host) ?? ""
            if mailbox.isEmpty && host.isEmpty && string(address.personName) == nil {
                return []
            }
            return [IMAPAddress(
                displayName: string(address.personName),
                mailbox: mailbox,
                host: host
            )]
        case .group(let group):
            return addresses(group.children)
        }
    }
}

extension IMAPBodyStructure {
    init(_ body: BodyStructure, prefix: [Int]) {
        let spec = prefix.map(String.init).joined(separator: ".")
        switch body {
        case .singlepart(let part):
            let (type, subtype) = media(part.kind)
            let fields = part.fields
            let children: [IMAPBodyStructure]
            if case .message(let message) = part.kind {
                let childPrefix = prefix.isEmpty ? [1] : prefix
                children = [IMAPBodyStructure(message.body, prefix: childPrefix)]
            } else {
                children = []
            }
            self.init(
                partSpecifier: spec,
                type: type,
                subtype: subtype,
                encoding: fields.encoding.map { String($0).lowercased() },
                octetCount: fields.octetCount,
                charset: lookupParam(fields.parameters, "charset"),
                filename: partFilename(from: part),
                contentID: fields.id,
                children: children
            )
        case .multipart(let part):
            var kids: [IMAPBodyStructure] = []
            kids.reserveCapacity(part.parts.count)
            for (index, child) in part.parts.enumerated() {
                kids.append(IMAPBodyStructure(child, prefix: prefix + [index + 1]))
            }
            self.init(
                partSpecifier: spec,
                type: "multipart",
                subtype: String(part.mediaSubtype).lowercased(),
                encoding: nil,
                octetCount: nil,
                charset: nil,
                filename: nil,
                contentID: nil,
                children: kids
            )
        }
    }
}

private func media(_ kind: BodyStructure.Singlepart.Kind) -> (String, String) {
    switch kind {
    case .basic(let basic):
        return (String(basic.topLevel).lowercased(), String(basic.sub).lowercased())
    case .text(let text):
        return ("text", String(text.mediaSubtype).lowercased())
    case .message:
        return ("message", "rfc822")
    }
}

private func lookupParam(
    _ parameters: some Sequence<(key: String, value: String)>,
    _ key: String
) -> String? {
    let lower = key.lowercased()
    for (name, value) in parameters where name.lowercased() == lower {
        return value
    }
    return nil
}

private func partFilename(from part: BodyStructure.Singlepart) -> String? {
    if let disposition = part.extension?.dispositionAndLanguage?.disposition {
        if let file = lookupParam(disposition.parameters, "filename") { return file }
        if let file = lookupParam(disposition.parameters, "name") { return file }
    }
    return lookupParam(part.fields.parameters, "name")
}

private func flagString(_ flag: Flag) -> String {
    String(flag)
}

private func specifier(for kind: StreamingKind) -> String {
    switch kind {
    case .binary(let section, _):
        return section.debugDescription
    case .body(let section, _):
        return section.debugDescription
            .replacingOccurrences(of: "BODY[", with: "")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    case .rfc822:
        return ""
    case .rfc822Text:
        return "TEXT"
    case .rfc822Header:
        return "HEADER"
    }
}

private func isBinary(_ kind: StreamingKind) -> Bool {
    if case .binary = kind { return true }
    return false
}

extension Foundation.Date {
    fileprivate init?(_ date: ServerMessageDate) {
        let components = date.components
        var dc = DateComponents()
        dc.year = components.year
        dc.month = components.month
        dc.day = components.day
        dc.hour = components.hour
        dc.minute = components.minute
        dc.second = components.second
        dc.timeZone = TimeZone(secondsFromGMT: components.zoneMinutes * 60)
        if let value = Calendar(identifier: .gregorian).date(from: dc) {
            self = value
        } else {
            return nil
        }
    }
}

func mailboxIDString(_ id: MailboxID) -> String {
    String(id)
}

func uidValues(_ set: UIDSet) -> [UInt32] {
    var values: [UInt32] = []
    for range in set.ranges {
        let lo = range.range.lowerBound.rawValue
        let hi = range.range.upperBound.rawValue
        if hi == UInt32.max && lo == 1 {
            continue
        }
        let last = min(hi, lo &+ 10_000)
        if last >= lo {
            for uid in lo...last {
                values.append(uid)
            }
        }
    }
    return values
}

func responseCodeName(_ code: ResponseTextCode?) -> String? {
    guard let code else { return nil }
    switch code {
    case .alert: return "ALERT"
    case .parse: return "PARSE"
    case .readOnly: return "READ-ONLY"
    case .readWrite: return "READ-WRITE"
    case .tryCreate: return "TRYCREATE"
    case .noModificationSequence: return "NOMODSEQ"
    case .authenticationFailed: return "AUTHENTICATIONFAILED"
    case .privacyRequired: return "PRIVACYREQUIRED"
    case .cannot: return "CANNOT"
    case .clientBug: return "CLIENTBUG"
    case .serverBug: return "SERVERBUG"
    case .unavailable: return "UNAVAILABLE"
    case .other(let atom, _): return atom
    default: return String(describing: code)
    }
}

func imapCapabilities(from nio: [Capability]) -> IMAPCapabilities {
    IMAPCapabilities(tokens: nio.map { String($0) })
}
