import Foundation
import MailternalInterfaces


func parseHeaderBlock(
    _ data: Data,
    state: ParseState,
    specifier: String?
) -> (fields: [MIMEHeaderField], bodyOffset: Int) {
    data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var i = 0
        var fields: [MIMEHeaderField] = []
        var currentName: [UInt8]?
        var currentValue: [UInt8] = []

        func flush() {
            guard let nameBytes = currentName else { return }
            let name = headerBytesToString(nameBytes, state: state, specifier: specifier)
                .trimmingCharacters(in: .whitespaces)
            let value = headerBytesToString(currentValue, state: state, specifier: specifier)
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                fields.append(MIMEHeaderField(name: name, value: value))
            }
            currentName = nil
            currentValue.removeAll(keepingCapacity: true)
        }

        // Skip UTF-8 BOM.
        if p.count >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF {
            i = 3
        }

        while i < p.count {
            if i >= MIMELimits.headerBlock {
                state.record(.headerBlockTooLarge, specifier: specifier, "header block exceeded 1 MiB")
                flush()
                return (fields, i)
            }

            if isEOL(p[i]) {
                flush()
                return (fields, skipEOL(p, i))
            }

            let lineStart = i
            var j = i
            var hitEOL = false
            let lineCap = min(p.count, i + MIMELimits.headerLine)
            while j < lineCap {
                if isEOL(p[j]) {
                    hitEOL = true
                    break
                }
                j += 1
            }

            if !hitEOL {
                state.record(.headerLineTooLong, specifier: specifier, "header line exceeded 64 KiB")
                var k = j
                let skipCap = min(p.count, MIMELimits.headerBlock)
                while k < skipCap && !isEOL(p[k]) { k += 1 }
                flush()
                if k < p.count && isEOL(p[k]) {
                    return (fields, skipEOL(p, k))
                }
                return (fields, k)
            }

            let lineEnd = j
            let next = skipEOL(p, j)
            let physical = lineEnd - lineStart
            if physical > MIMELimits.headerLine {
                state.record(.headerLineTooLong, specifier: specifier, "header line exceeded 64 KiB")
            }

            // mbox From_ separator
            if currentName == nil && fields.isEmpty && looksLikeMboxFrom(p, lineStart, lineEnd) {
                i = next
                continue
            }

            if lineStart < lineEnd && isWSP(p[lineStart]) {
                if currentName != nil {
                    currentValue.append(contentsOf: p[lineStart..<lineEnd])
                } else {
                    state.record(.invalidHeader, specifier: specifier, "folded line with no preceding field")
                }
                i = next
                continue
            }

            flush()

            var colon = lineStart
            while colon < lineEnd && p[colon] != 58 { colon += 1 }
            if colon >= lineEnd {
                state.record(.invalidHeader, specifier: specifier, "header line missing ':'")
                i = next
                continue
            }

            currentName = Array(p[lineStart..<colon])
            var vs = colon + 1
            if vs < lineEnd && isWSP(p[vs]) { vs += 1 }
            currentValue = Array(p[vs..<lineEnd])
            i = next
        }

        flush()
        return (fields, p.count)
    }
}

private func looksLikeMboxFrom(_ p: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
    guard end - start >= 5 else { return false }
    // "From "
    if p[start] != 70 && p[start] != 102 { return false }
    if p[start + 1] != 114 && p[start + 1] != 82 { return false }
    if p[start + 2] != 111 && p[start + 2] != 79 { return false }
    if p[start + 3] != 109 && p[start + 3] != 77 { return false }
    if p[start + 4] != 32 { return false }
    var i = start
    while i < end {
        if p[i] == 58 { return false }
        i += 1
    }
    return true
}

// MARK: - RFC 2047

func decodeEncodedWords(_ input: String, state: ParseState, specifier: String?) -> String {
    if input.isEmpty { return input }
    var i = input.startIndex
    var out = String()
    out.reserveCapacity(input.count)
    var lastWasEW = false
    var pendingWS = ""
    var byteBuf: [UInt8] = []
    var bufCharset: String?

    func flushBytes() {
        guard !byteBuf.isEmpty else { return }
        out += decodeCharset(Data(byteBuf), charset: bufCharset, state: state, specifier: specifier)
        byteBuf.removeAll(keepingCapacity: true)
        bufCharset = nil
    }

    while i < input.endIndex {
        if input[i] == "=", let ew = scanEncodedWord(input, from: i) {
            if lastWasEW {
                pendingWS = ""
                if let cs = bufCharset, cs.caseInsensitiveCompare(ew.charset) == .orderedSame {
                    byteBuf.append(contentsOf: ew.bytes)
                } else {
                    flushBytes()
                    bufCharset = ew.charset
                    byteBuf = ew.bytes
                }
            } else {
                out += pendingWS
                pendingWS = ""
                flushBytes()
                bufCharset = ew.charset
                byteBuf = ew.bytes
            }
            lastWasEW = true
            i = ew.end
            continue
        }

        let ch = input[i]
        if ch == " " || ch == "\t" {
            pendingWS.append(ch)
        } else {
            flushBytes()
            out += pendingWS
            pendingWS = ""
            out.append(ch)
            lastWasEW = false
        }
        i = input.index(after: i)
    }
    flushBytes()
    out += pendingWS
    return out
}

private struct EncodedWord {
    var charset: String
    var bytes: [UInt8]
    var end: String.Index
}

private func scanEncodedWord(_ input: String, from start: String.Index) -> EncodedWord? {
    // =?charset?encoding?text?=
    guard input[start] == "=" else { return nil }
    let afterEq = input.index(after: start)
    guard afterEq < input.endIndex, input[afterEq] == "?" else { return nil }
    var i = input.index(after: afterEq)
    guard let q1 = input[i...].firstIndex(of: "?") else { return nil }
    let charset = String(input[i..<q1])
    guard !charset.isEmpty else { return nil }
    i = input.index(after: q1)
    guard let q2 = input[i...].firstIndex(of: "?") else { return nil }
    let encoding = String(input[i..<q2])
    i = input.index(after: q2)
    guard let q3 = input[i...].firstIndex(of: "?") else { return nil }
    let text = String(input[i..<q3])
    let afterQ3 = input.index(after: q3)
    guard afterQ3 < input.endIndex, input[afterQ3] == "=" else { return nil }
    let end = input.index(after: afterQ3)

    let enc = encoding.uppercased()
    let bytes: [UInt8]
    if enc == "B" {
        bytes = decodeBase64Bytes(Array(text.utf8), recordDefects: false, specifier: nil, state: nil)
    } else if enc == "Q" {
        bytes = decodeQWord(text)
    } else {
        return nil
    }
    return EncodedWord(charset: charset, bytes: bytes, end: end)
}

private func decodeQWord(_ text: String) -> [UInt8] {
    let u = Array(text.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(u.count)
    var i = 0
    while i < u.count {
        if u[i] == 95 {
            out.append(32)
            i += 1
        } else if u[i] == 61, i + 2 < u.count, let h1 = hexNibble(u[i + 1]), let h2 = hexNibble(u[i + 2]) {
            out.append(UInt8(h1 * 16 + h2))
            i += 3
        } else {
            out.append(u[i])
            i += 1
        }
    }
    return out
}

// MARK: - Content-Type / Disposition / RFC 2231

func parseContentType(
    _ value: String,
    state: ParseState,
    specifier: String?,
    defaultType: (String, String)
) -> (type: String, subtype: String, parameters: [String: String]) {
    let trimmed = trimWS(value)
    if trimmed.isEmpty {
        return (defaultType.0, defaultType.1, [:])
    }
    var scan = StringScan(trimmed)
    scan.skipCFWS()
    let typeTok = scan.takeToken()
    if scan.peek() == "/" {
        scan.advance()
    }
    let subTok = scan.takeToken()
    let params = parseParameterList(&scan, state: state, specifier: specifier)
    let type = typeTok.isEmpty ? defaultType.0 : typeTok.lowercased()
    let subtype = subTok.isEmpty ? defaultType.1 : subTok.lowercased()
    return (type, subtype, params)
}

func parseContentDisposition(
    _ value: String,
    state: ParseState,
    specifier: String?
) -> (disposition: String, parameters: [String: String]) {
    var scan = StringScan(trimWS(value))
    scan.skipCFWS()
    let disp = scan.takeToken().lowercased()
    let params = parseParameterList(&scan, state: state, specifier: specifier)
    return (disp, params)
}

func parseParameterList(
    _ scan: inout StringScan,
    state: ParseState,
    specifier: String?
) -> [String: String] {
    struct Piece {
        var index: Int
        var encoded: Bool
        var value: String
    }
    var groups: [String: [Piece]] = [:]
    var simple: [String: String] = [:]

    while true {
        scan.skipCFWS()
        if scan.peek() != ";" { break }
        scan.advance()
        scan.skipCFWS()
        let rawName = scan.takeParameterName()
        if rawName.isEmpty {
            state.record(.malformedParameter, specifier: specifier, "empty parameter name")
            scan.skipUntilSemicolon()
            continue
        }
        scan.skipCFWS()
        if scan.peek() != "=" {
            state.record(.malformedParameter, specifier: specifier, "parameter missing '='")
            scan.skipUntilSemicolon()
            continue
        }
        scan.advance()
        scan.skipCFWS()
        let rawValue: String
        if scan.peek() == "\"" {
            rawValue = scan.takeQuotedString()
        } else {
            rawValue = scan.takeTokenOrExtended()
        }

        let parsed = splitParameterName(rawName)
        if parsed.index != nil || parsed.encoded {
            groups[parsed.base, default: []].append(
                Piece(index: parsed.index ?? 0, encoded: parsed.encoded, value: rawValue)
            )
        } else {
            simple[parsed.base] = maybeDecode2047Filename(rawValue, state: state, specifier: specifier)
        }
    }

    var out = simple
    for (base, pieces) in groups {
        let ordered = pieces.sorted { $0.index < $1.index }
        var charset = "us-ascii"
        var bytes: [UInt8] = []
        var text = ""
        var anyEncoded = false
        for (offset, piece) in ordered.enumerated() {
            if piece.encoded {
                anyEncoded = true
                var payload = piece.value
                if offset == 0, let parsed = splitExtendedValue(piece.value) {
                    charset = parsed.charset
                    payload = parsed.encoded
                }
                bytes.append(contentsOf: percentDecode(payload, state: state, specifier: specifier))
            } else {
                text += piece.value
            }
        }
        if anyEncoded {
            if !text.isEmpty {
                bytes.insert(contentsOf: Array(text.utf8), at: 0)
            }
            out[base] = decodeCharset(Data(bytes), charset: charset, state: state, specifier: specifier)
        } else if !text.isEmpty {
            out[base] = maybeDecode2047Filename(text, state: state, specifier: specifier)
        }
    }
    return out
}

private func splitParameterName(_ raw: String) -> (base: String, index: Int?, encoded: Bool) {
    let lower = raw.lowercased()
    guard let star = lower.firstIndex(of: "*") else {
        return (lower, nil, false)
    }
    let base = String(lower[..<star])
    var rest = lower[lower.index(after: star)...]
    if rest.isEmpty {
        return (base, nil, true)
    }
    var encoded = false
    if rest.hasSuffix("*") {
        encoded = true
        rest = rest.dropLast()
    }
    if rest.isEmpty {
        return (base, 0, encoded)
    }
    return (base, Int(rest), encoded)
}

private func splitExtendedValue(_ value: String) -> (charset: String, encoded: String)? {
    // charset'language'value
    guard let first = value.firstIndex(of: "'") else { return nil }
    let charset = String(value[..<first])
    let after = value.index(after: first)
    guard let second = value[after...].firstIndex(of: "'") else { return nil }
    return (charset.isEmpty ? "us-ascii" : charset, String(value[value.index(after: second)...]))
}

private func percentDecode(_ value: String, state: ParseState, specifier: String?) -> [UInt8] {
    let u = Array(value.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(u.count)
    var i = 0
    while i < u.count {
        if u[i] == 37, i + 2 < u.count, let h1 = hexNibble(u[i + 1]), let h2 = hexNibble(u[i + 2]) {
            out.append(UInt8(h1 * 16 + h2))
            i += 3
        } else if u[i] == 37 {
            state.record(.malformedParameter, specifier: specifier, "invalid percent-encoding")
            out.append(u[i])
            i += 1
        } else {
            out.append(u[i])
            i += 1
        }
    }
    return out
}

private func maybeDecode2047Filename(_ value: String, state: ParseState, specifier: String?) -> String {
    if value.contains("=?") {
        return decodeEncodedWords(value, state: state, specifier: specifier)
    }
    return value
}

func extractContentID(_ value: String) -> String? {
    let ids = extractMessageIDs(value)
    guard let first = ids.first else {
        let t = trimWS(value)
        return t.isEmpty ? nil : t
    }
    if first.hasPrefix("<"), first.hasSuffix(">"), first.count >= 2 {
        return String(first.dropFirst().dropLast())
    }
    return first
}

/// Angle-bracket extraction; results are stored as `<id>` (normalized).
func extractMessageIDs(_ value: String) -> [String] {
    var result: [String] = []
    var i = value.startIndex
    while i < value.endIndex {
        if value[i] == "<" {
            if let close = value[i...].firstIndex(of: ">") {
                let inner = value[value.index(after: i)..<close]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !inner.isEmpty {
                    result.append("<\(inner)>")
                }
                i = value.index(after: close)
                continue
            }
        }
        i = value.index(after: i)
    }
    if result.isEmpty {
        let t = trimWS(value)
        if !t.isEmpty && t.contains("@") {
            result.append(t.hasPrefix("<") && t.hasSuffix(">") ? t : "<\(t)>")
        }
    }
    return result
}

// MARK: - String scanner (headers are small)

struct StringScan {
    let s: String
    var i: String.Index

    init(_ s: String) {
        self.s = s
        self.i = s.startIndex
    }

    func peek() -> Character? {
        i < s.endIndex ? s[i] : nil
    }

    mutating func advance() {
        if i < s.endIndex { i = s.index(after: i) }
    }

    mutating func skipCFWS() {
        while i < s.endIndex {
            let ch = s[i]
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                advance()
                continue
            }
            if ch == "(" {
                _ = takeComment()
                continue
            }
            break
        }
    }

    mutating func takeComment() -> String {
        guard peek() == "(" else { return "" }
        advance()
        var depth = 1
        var out = ""
        while i < s.endIndex && depth > 0 {
            let ch = s[i]
            if ch == "\\" {
                advance()
                if i < s.endIndex {
                    out.append(s[i])
                    advance()
                }
                continue
            }
            if ch == "(" {
                depth += 1
                advance()
                continue
            }
            if ch == ")" {
                depth -= 1
                advance()
                continue
            }
            if depth == 1 { out.append(ch) }
            advance()
        }
        return out
    }

    mutating func takeToken() -> String {
        skipCFWS()
        let start = i
        while i < s.endIndex {
            let ch = s[i]
            if ch == ";" || ch == "=" || ch == "/" || ch == "\"" || ch == "("
                || ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "<" || ch == ">"
                || ch == "," || ch == ":" {
                break
            }
            advance()
        }
        return String(s[start..<i])
    }

    mutating func takeParameterName() -> String {
        skipCFWS()
        let start = i
        while i < s.endIndex {
            let ch = s[i]
            if ch == "=" || ch == ";" || ch == " " || ch == "\t" || ch == "\r" || ch == "\n"
                || ch == "(" || ch == "\"" {
                break
            }
            advance()
        }
        return String(s[start..<i])
    }

    mutating func takeTokenOrExtended() -> String {
        skipCFWS()
        let start = i
        while i < s.endIndex {
            let ch = s[i]
            if ch == ";" || ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "(" {
                break
            }
            advance()
        }
        return String(s[start..<i])
    }

    mutating func takeQuotedString() -> String {
        guard peek() == "\"" else { return takeTokenOrExtended() }
        advance()
        var out = ""
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\" {
                advance()
                if i < s.endIndex {
                    out.append(s[i])
                    advance()
                }
                continue
            }
            if ch == "\"" {
                advance()
                break
            }
            out.append(ch)
            advance()
        }
        return out
    }

    mutating func skipUntilSemicolon() {
        while i < s.endIndex && s[i] != ";" { advance() }
    }
}

func makeEnvelope(fields: [MIMEHeaderField], internalDate: Date, state: ParseState) -> Envelope {
    let subjectRaw = firstHeader(fields, "Subject") ?? ""
    let subject = decodeEncodedWords(subjectRaw, state: state, specifier: nil)

    let from = parseAddressList(firstHeader(fields, "From") ?? "", state: state, specifier: nil)
    let to = parseAddressList(allHeaders(fields, "To").joined(separator: ", "), state: state, specifier: nil)
    let cc = parseAddressList(allHeaders(fields, "Cc").joined(separator: ", "), state: state, specifier: nil)
    let replyTo = parseAddressList(firstHeader(fields, "Reply-To") ?? "", state: state, specifier: nil)

    var headerDate: Date?
    if let raw = firstHeader(fields, "Date") {
        let trimmed = trimWS(raw)
        if trimmed.isEmpty {
            state.record(.missingDate, "Date header is empty")
        } else if let parsed = parseRFC5322Date(trimmed) {
            headerDate = parsed
        } else {
            state.record(.malformedDate, trimmed)
        }
    } else {
        state.record(.missingDate, "no Date header")
    }

    let mid = extractMessageIDs(firstHeader(fields, "Message-ID") ?? "").first
    let irt = extractMessageIDs(firstHeader(fields, "In-Reply-To") ?? "").first
    let refs = allHeaders(fields, "References").flatMap { extractMessageIDs($0) }

    return Envelope(
        subject: subject,
        from: from,
        to: to,
        cc: cc,
        replyTo: replyTo,
        internalDate: internalDate,
        headerDate: headerDate,
        rfcMessageID: mid,
        inReplyTo: irt,
        references: refs
    )
}
