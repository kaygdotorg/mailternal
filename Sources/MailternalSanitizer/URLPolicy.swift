import Foundation

/// Classification of a URL found in markup.
enum ClassifiedURL: Sendable {
    case drop
    case keep(String)
    case rewrite(PartReference)
}

enum URLPolicy {
    /// Image-bearing attributes (`src`, `background`, SVG `href` on `<image>`).
    static func classifyImage(_ raw: String) -> ClassifiedURL {
        switch parse(raw) {
        case .cid(let cid):
            return .rewrite(.cid(cid))
        case .http(let url):
            return .rewrite(.remote(url))
        case .part(let reference):
            return .rewrite(reference)
        case .dataImage(let kept):
            return .keep(kept)
        case .mailto, .fragment, .reject:
            return .drop
        }
    }

    /// User-activated hyperlinks (`<a href>`). Never auto-fetched.
    static func classifyHyperlink(_ raw: String) -> ClassifiedURL {
        switch parse(raw) {
        case .http(let url):
            return .keep(url.absoluteString)
        case .mailto(let kept), .fragment(let kept):
            return .keep(kept)
        case .cid, .part, .dataImage, .reject:
            return .drop
        }
    }

    private enum Parsed {
        case cid(String)
        case http(URL)
        case mailto(String)
        case fragment(String)
        case part(PartReference)
        case dataImage(String)
        case reject
    }

    private static let allowedDataImageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/gif",
        "image/webp", "image/bmp", "image/x-icon", "image/vnd.microsoft.icon",
        "image/avif", "image/apng",
    ]

    private static func parse(_ raw: String) -> Parsed {
        let trimmed = stripUnsafe(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .reject }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let compact = stripUnsafe(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.isEmpty { return .reject }

        if compact.hasPrefix("#") {
            if compact.lowercased().hasPrefix("#javascript") { return .reject }
            return .fragment(compact)
        }

        if compact.hasPrefix("//") {
            guard let url = URL(string: "https:" + compact), isHTTP(url) else { return .reject }
            return .http(url)
        }

        guard let (scheme, rest) = splitScheme(compact) else {
            return .reject
        }

        switch scheme {
        case "cid":
            let cid = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return cid.isEmpty ? .reject : .cid(cid)
        case "http", "https":
            guard let url = URL(string: scheme + ":" + rest), isHTTP(url) else { return .reject }
            return .http(url)
        case "mailto":
            let address = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            return address.isEmpty ? .reject : .mailto("mailto:" + address)
        case "data":
            return classifyData(rest, original: compact)
        case PartURL.scheme:
            guard let url = URL(string: compact), let reference = PartURL.decode(url) else {
                return .reject
            }
            return .part(reference)
        default:
            return .reject
        }
    }

    private static func classifyData(_ rest: String, original: String) -> Parsed {
        let payload = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let mimePart = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
            ?? payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first
            ?? Substring(payload)
        let mime = mimePart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowedDataImageTypes.contains(mime) else { return .reject }
        return .dataImage(original)
    }

    private static func isHTTP(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func splitScheme(_ string: String) -> (String, String)? {
        var index = string.startIndex
        guard index < string.endIndex, string[index].isLetter else { return nil }
        index = string.index(after: index)
        while index < string.endIndex {
            let ch = string[index]
            if ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == "." {
                index = string.index(after: index)
                continue
            }
            break
        }
        guard index < string.endIndex, string[index] == ":" else { return nil }
        let scheme = string[string.startIndex..<index].lowercased()
        let rest = String(string[string.index(after: index)...])
        return (scheme, rest)
    }

    /// Strip C0/C1 controls and bidi overrides used to smuggle schemes.
    private static func stripUnsafe(_ string: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F { continue }
            if (0x200B...0x200F).contains(value) { continue }
            if (0x202A...0x202E).contains(value) { continue }
            if (0x2066...0x2069).contains(value) { continue }
            if value == 0xFEFF { continue }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
