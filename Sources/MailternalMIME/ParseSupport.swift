import Foundation

final class ParseState {
    var defects: [MIMEDefect] = []
    var entityCount = 0
    private var decodedBudget = 0

    func record(_ kind: MIMEDefect.Kind, specifier: String? = nil, _ detail: String = "") {
        defects.append(MIMEDefect(kind: kind, specifier: specifier, detail: detail))
    }

    func allowEntity() -> Bool {
        entityCount += 1
        return entityCount <= MIMELimits.maxParts
    }

    /// Count decoded octets and checkpoint cancellation at least every 256 KiB.
    func accountDecoded(_ count: Int) throws {
        guard count > 0 else { return }
        var remaining = count
        while remaining > 0 {
            let room = MIMELimits.cancellationCheckpoint - decodedBudget
            let chunk = remaining < room ? remaining : room
            decodedBudget += chunk
            remaining -= chunk
            if decodedBudget >= MIMELimits.cancellationCheckpoint {
                try Task.checkCancellation()
                decodedBudget = 0
            }
        }
    }
}


func contiguousZeroBased(_ data: Data) -> Data {
    if data.startIndex == 0 && data.endIndex == data.count {
        return data
    }
    return Data(data)
}

extension Data {
    /// 0-based range relative to this view's first byte.
    func view(_ range: Range<Int>) -> Data {
        let a = index(startIndex, offsetBy: range.lowerBound)
        let b = index(startIndex, offsetBy: range.upperBound)
        return self[a..<b]
    }
}

func firstHeader(_ fields: [MIMEHeaderField], _ name: String) -> String? {
    fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
}

func allHeaders(_ fields: [MIMEHeaderField], _ name: String) -> [String] {
    fields.compactMap { $0.name.caseInsensitiveCompare(name) == .orderedSame ? $0.value : nil }
}

func asciiLower(_ s: String) -> String {
    s.lowercased()
}

func trimWS(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func isWSP(_ b: UInt8) -> Bool {
    b == 32 || b == 9
}

func isEOL(_ b: UInt8) -> Bool {
    b == 10 || b == 13
}

/// Advance `i` over a CR, LF, or CRLF. Returns the index after the line ending.
func skipEOL(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
    guard i < p.count else { return i }
    if p[i] == 13 {
        let n = i + 1
        if n < p.count && p[n] == 10 { return n + 1 }
        return n
    }
    if p[i] == 10 { return i + 1 }
    return i
}

/// Index of the CR/LF that precedes `i`, or `i` if `i` is not preceded by a line ending.
func lineDelimiterStart(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
    if i >= 2 && p[i - 2] == 13 && p[i - 1] == 10 { return i - 2 }
    if i >= 1 && (p[i - 1] == 10 || p[i - 1] == 13) { return i - 1 }
    return i
}

func headerBytesToString(_ bytes: [UInt8], state: ParseState, specifier: String?) -> String {
    if bytes.isEmpty { return "" }
    var hasHigh = false
    for b in bytes where b >= 0x80 {
        hasHigh = true
        break
    }
    if hasHigh {
        state.record(.eightBitHeader, specifier: specifier, "header field contains 8-bit bytes")
        if let utf8 = String(data: Data(bytes), encoding: .utf8) {
            return utf8
        }
        return String(data: Data(bytes), encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }
    return String(decoding: bytes, as: UTF8.self)
}

func hexNibble(_ b: UInt8) -> Int? {
    switch b {
    case 48...57: return Int(b - 48)
    case 65...70: return Int(b - 65 + 10)
    case 97...102: return Int(b - 97 + 10)
    default: return nil
    }
}

func isTokenChar(_ b: UInt8) -> Bool {
    // RFC 2045 token minus SPACE / CTL / tspecials
    switch b {
    case 33, 35...39, 42, 43, 45, 46, 48...57, 65...90, 94...126:
        return true
    default:
        return false
    }
}
