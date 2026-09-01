import Foundation

func decodeTransferEncoding(
    _ data: Data,
    encoding: ContentTransferEncoding,
    state: ParseState,
    specifier: String?,
    cap: Int?
) throws -> (Data, truncated: Bool) {
    switch encoding {
    case .quotedPrintable:
        return try decodeQuotedPrintable(data, state: state, specifier: specifier, cap: cap)
    case .base64:
        return try decodeBase64(data, state: state, specifier: specifier, cap: cap)
    case .sevenBit, .eightBit, .binary:
        if let cap, data.count > cap {
            try state.accountDecoded(cap)
            return (contiguousZeroBased(data.view(0..<cap)), true)
        }
        try state.accountDecoded(data.count)
        return (contiguousZeroBased(data), false)
    }
}

func decodeQuotedPrintable(
    _ data: Data,
    state: ParseState,
    specifier: String?,
    cap: Int?
) throws -> (Data, truncated: Bool) {
    var out = [UInt8]()
    let reserve = cap ?? data.count
    out.reserveCapacity(min(data.count, reserve))
    var truncated = false
    var broken = false
    var producedSinceCheck = 0

    func emit(_ b: UInt8) -> Bool {
        if let cap, out.count >= cap {
            truncated = true
            return false
        }
        out.append(b)
        producedSinceCheck += 1
        return true
    }

    try data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i < p.count {
            if truncated { break }
            if producedSinceCheck >= MIMELimits.cancellationCheckpoint {
                try state.accountDecoded(producedSinceCheck)
                producedSinceCheck = 0
            }
            let b = p[i]
            if b == 61 { // '='
                let n1 = i + 1
                if n1 >= p.count {
                    // trailing '=' — treat as soft EOF
                    break
                }
                if isEOL(p[n1]) {
                    i = skipEOL(p, n1)
                    continue
                }
                // broken: "= " before EOL (tolerate as soft break)
                if isWSP(p[n1]) {
                    var k = n1
                    while k < p.count && isWSP(p[k]) { k += 1 }
                    if k >= p.count || isEOL(p[k]) {
                        if !broken {
                            state.record(.brokenQuotedPrintable, specifier: specifier, "whitespace after '='")
                            broken = true
                        }
                        i = k < p.count ? skipEOL(p, k) : k
                        continue
                    }
                }
                if n1 + 1 < p.count, let h1 = hexNibble(p[n1]), let h2 = hexNibble(p[n1 + 1]) {
                    if !emit(UInt8(h1 * 16 + h2)) { break }
                    i += 3
                    continue
                }
                if !broken {
                    state.record(.brokenQuotedPrintable, specifier: specifier, "invalid =XX sequence")
                    broken = true
                }
                if !emit(61) { break }
                i += 1
                continue
            }
            if !emit(b) { break }
            i += 1
        }
    }
    if producedSinceCheck > 0 {
        try state.accountDecoded(producedSinceCheck)
    }
    return (Data(out), truncated)
}

func decodeBase64(
    _ data: Data,
    state: ParseState,
    specifier: String?,
    cap: Int?
) throws -> (Data, truncated: Bool) {
    let bytes: [UInt8] = data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: UInt8.self))
    }
    var broken = false
    let decoded = decodeBase64Bytes(bytes, recordDefects: true, specifier: specifier, state: state, broken: &broken)
    if let cap, decoded.count > cap {
        try state.accountDecoded(cap)
        return (Data(decoded.prefix(cap)), true)
    }
    try state.accountDecoded(decoded.count)
    return (Data(decoded), false)
}

/// Shared by CTE base64 and RFC 2047 B encoding.
func decodeBase64Bytes(
    _ input: [UInt8],
    recordDefects: Bool,
    specifier: String?,
    state: ParseState?,
    broken: inout Bool
) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(input.count * 3 / 4 + 4)
    var acc: UInt32 = 0
    var n = 0
    var sawInvalid = false

    func flushQuad() {
        guard n > 0 else { return }
        acc <<= UInt32(6 * (4 - n))
        if n >= 2 { out.append(UInt8((acc >> 16) & 0xFF)) }
        if n >= 3 { out.append(UInt8((acc >> 8) & 0xFF)) }
        if n >= 4 { out.append(UInt8(acc & 0xFF)) }
        acc = 0
        n = 0
    }

    for b in input {
        if b == 61 { // pad — finish
            flushQuad()
            break
        }
        if b == 32 || b == 9 || b == 10 || b == 13 { continue }
        let v = base64Value(b)
        if v < 0 {
            if recordDefects && !sawInvalid {
                state?.record(.brokenBase64, specifier: specifier, "invalid base64 alphabet")
                sawInvalid = true
                broken = true
            }
            continue
        }
        acc = (acc << 6) | UInt32(v)
        n += 1
        if n == 4 { flushQuad() }
    }

    if n > 0 { flushQuad() }
    if recordDefects && sawInvalid { broken = true }
    return out
}

func decodeBase64Bytes(
    _ input: [UInt8],
    recordDefects: Bool,
    specifier: String?,
    state: ParseState?
) -> [UInt8] {
    var broken = false
    return decodeBase64Bytes(input, recordDefects: recordDefects, specifier: specifier, state: state, broken: &broken)
}

private func base64Value(_ b: UInt8) -> Int {
    switch b {
    case 65...90: return Int(b - 65)            // A-Z
    case 97...122: return Int(b - 97 + 26)      // a-z
    case 48...57: return Int(b - 48 + 52)       // 0-9
    case 43, 45: return 62                      // + or URL-safe -
    case 47, 95: return 63                      // / or URL-safe _
    default: return -1
    }
}
