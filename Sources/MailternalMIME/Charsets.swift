import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

func decodeCharset(
    _ data: Data,
    charset: String?,
    state: ParseState,
    specifier: String?
) -> String {
    if data.isEmpty { return "" }
    let name = (charset ?? "us-ascii").trimmingCharacters(in: .whitespacesAndNewlines)
    let key = normalizeCharsetName(name)

    if key == "us-ascii" || key == "ascii" {
        return decodeASCIIMislabeled(data, declared: name, state: state, specifier: specifier)
    }

    if key == "iso-8859-1" || key == "latin1" || key == "iso-latin-1" {
        return decodeLatin1OrWindows1252(data, declared: name, state: state, specifier: specifier)
    }

    if let encoding = encodingForIANA(key) {
        if encoding == .isoLatin1 {
            return decodeLatin1OrWindows1252(data, declared: name, state: state, specifier: specifier)
        }
        if let s = String(data: data, encoding: encoding) {
            return s
        }
        state.record(.unknownCharset, specifier: specifier, "declared charset '\(name)' failed to decode")
        return decodeLatin1OrWindows1252(data, declared: name, state: state, specifier: specifier, alreadyFailed: true)
    }

    state.record(.unknownCharset, specifier: specifier, "unknown charset '\(name)'")
    state.record(.charsetFallbackISO88591, specifier: specifier, name)
    return decodeLatin1OrWindows1252(data, declared: name, state: state, specifier: specifier, alreadyFailed: true)
}

private func decodeASCIIMislabeled(
    _ data: Data,
    declared: String,
    state: ParseState,
    specifier: String?
) -> String {
    var hasHigh = false
    data.withUnsafeBytes { raw in
        for b in raw.bindMemory(to: UInt8.self) where b >= 0x80 {
            hasHigh = true
            break
        }
    }
    if !hasHigh {
        return String(decoding: data, as: UTF8.self)
    }
    state.record(.mislabeledCharset, specifier: specifier, "us-ascii declared but 8-bit bytes present")
    if let utf8 = String(data: data, encoding: .utf8) {
        return utf8
    }
    return decodeLatin1OrWindows1252(data, declared: declared, state: state, specifier: specifier, alreadyFailed: true)
}

private func decodeLatin1OrWindows1252(
    _ data: Data,
    declared: String,
    state: ParseState,
    specifier: String?,
    alreadyFailed: Bool = false
) -> String {
    var hasC1 = false
    data.withUnsafeBytes { raw in
        for b in raw.bindMemory(to: UInt8.self) where b >= 0x80 && b <= 0x9F {
            hasC1 = true
            break
        }
    }
    if hasC1 {
        state.record(
            .mislabeledCharset,
            specifier: specifier,
            "\(declared) looks like windows-1252 (C1 bytes 0x80-0x9F)"
        )
        if let s = String(data: data, encoding: .windowsCP1252) {
            return s
        }
    }
    if alreadyFailed {
        state.record(.charsetFallbackISO88591, specifier: specifier, declared)
    }
    return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
}

func normalizeCharsetName(_ name: String) -> String {
    var out = String()
    out.reserveCapacity(name.count)
    for ch in name.lowercased() {
        if ch == "_" || ch == " " {
            out.append("-")
        } else {
            out.append(ch)
        }
    }
    // strip trailing/leading hyphens from collapse
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}

func encodingForIANA(_ normalized: String) -> String.Encoding? {
    if let mapped = charsetMap[normalized] {
        return mapped
    }
#if canImport(CoreFoundation)
    let cf = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
    if cf != kCFStringEncodingInvalidId {
        let ns = CFStringConvertEncodingToNSStringEncoding(cf)
        return String.Encoding(rawValue: ns)
    }
#endif
    return nil
}

private let charsetMap: [String: String.Encoding] = {
    var m: [String: String.Encoding] = [:]
    func add(_ names: [String], _ enc: String.Encoding) {
        for n in names { m[n] = enc }
    }
    add(["utf-8", "utf8"], .utf8)
    add(["utf-16", "utf16", "unicode"], .utf16)
    add(["utf-16be", "utf16be"], .utf16BigEndian)
    add(["utf-16le", "utf16le"], .utf16LittleEndian)
    add(["utf-32", "utf32"], .utf32)
    add(["utf-32be"], .utf32BigEndian)
    add(["utf-32le"], .utf32LittleEndian)
    add(["us-ascii", "ascii", "usascii", "iso-646-us", "iso646-us"], .ascii)
    add(["iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1", "ibm819", "cp819", "csisolatin1", "iso-latin-1"], .isoLatin1)
    add(["iso-8859-2", "iso8859-2", "latin2", "latin-2", "csisolatin2"], .isoLatin2)
    add(["windows-1250", "cp1250", "cswindows1250"], .windowsCP1250)
    add(["windows-1251", "cp1251", "cswindows1251"], .windowsCP1251)
    add(["windows-1252", "cp1252", "cswindows1252", "x-cp1252"], .windowsCP1252)
    add(["windows-1253", "cp1253", "cswindows1253"], .windowsCP1253)
    add(["windows-1254", "cp1254", "cswindows1254"], .windowsCP1254)
    add(["shift-jis", "shiftjis", "sjis", "x-sjis", "csshiftjis", "ms-kanji", "windows-31j", "cswindows31j", "cp932"], .shiftJIS)
    add(["iso-2022-jp", "csiso2022jp"], .iso2022JP)
    add(["euc-jp", "eucjp", "x-euc-jp", "cseucpkdfmtjapanese"], .japaneseEUC)
    add(["macintosh", "mac", "macroman", "x-mac-roman", "mac-roman"], .macOSRoman)
    add(["iso-8859-15", "iso8859-15", "latin9", "latin-9"], .isoLatin1)
    return m
}()

