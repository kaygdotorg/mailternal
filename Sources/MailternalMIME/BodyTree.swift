import Foundation
import MailternalInterfaces

func parseRFC822(
    _ data: Data,
    specifier: String,
    depth: Int,
    state: ParseState,
    internalDate: Date,
    defaultType: (String, String)
) throws -> (MIMEPart, Envelope) {
    if !state.allowEntity() {
        state.record(.malformedBoundary, specifier: specifier.isEmpty ? nil : specifier, "part budget exceeded")
        let empty = Envelope(
            subject: "", from: [], to: [], cc: [], replyTo: [],
            internalDate: internalDate, headerDate: nil,
            rfcMessageID: nil, inReplyTo: nil, references: []
        )
        return (MIMEPart(specifier: specifier, type: defaultType.0, subtype: defaultType.1), empty)
    }
    let (fields, bodyOffset) = parseHeaderBlock(data, state: state, specifier: specifier)
    let envelope = makeEnvelope(fields: fields, internalDate: internalDate, state: state)
    let body = bodyOffset < data.count ? data.view(bodyOffset..<data.count) : Data()
    let part = try parseEntity(
        headers: fields,
        body: body,
        specifier: specifier,
        depth: depth,
        state: state,
        internalDate: internalDate,
        defaultType: defaultType
    )
    return (part, envelope)
}

func parseEntity(
    headers: [MIMEHeaderField],
    body: Data,
    specifier: String,
    depth: Int,
    state: ParseState,
    internalDate: Date,
    defaultType: (String, String)
) throws -> MIMEPart {
    let ctRaw = firstHeader(headers, "Content-Type")
    if ctRaw == nil {
        state.record(.missingContentType, specifier: specifier.isEmpty ? nil : specifier, "defaulting to \(defaultType.0)/\(defaultType.1)")
    }
    let ct = parseContentType(ctRaw ?? "", state: state, specifier: specifier.isEmpty ? nil : specifier, defaultType: defaultType)

    let encRaw = firstHeader(headers, "Content-Transfer-Encoding")
    var encoding = ContentTransferEncoding(headerValue: encRaw ?? "7bit")
    if let encRaw {
        let known: Set<String> = [
            "7bit", "7-bit", "8bit", "8-bit", "binary",
            "quoted-printable", "quotedprintable", "base64", "",
        ]
        if !known.contains(encRaw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) {
            state.record(.unknownTransferEncoding, specifier: specifier.isEmpty ? nil : specifier, encRaw)
            encoding = .eightBit
        }
    }

    var disposition: String?
    var dispParams: [String: String] = [:]
    if let dispRaw = firstHeader(headers, "Content-Disposition") {
        let parsed = parseContentDisposition(dispRaw, state: state, specifier: specifier.isEmpty ? nil : specifier)
        disposition = parsed.disposition.isEmpty ? nil : parsed.disposition
        dispParams = parsed.parameters
    }

    var filename = dispParams["filename"] ?? ct.parameters["name"]
    if let fn = filename, fn.contains("=?") {
        filename = decodeEncodedWords(fn, state: state, specifier: specifier.isEmpty ? nil : specifier)
    }

    let cid = firstHeader(headers, "Content-ID").flatMap(extractContentID)

    if ct.type == "multipart" {
        return try parseMultipart(
            headers: headers,
            body: body,
            type: ct.type,
            subtype: ct.subtype,
            parameters: ct.parameters,
            encoding: encoding,
            disposition: disposition,
            dispParams: dispParams,
            filename: filename,
            cid: cid,
            specifier: specifier,
            depth: depth,
            state: state,
            internalDate: internalDate
        )
    }

    if ct.type == "message" && ct.subtype == "rfc822" {
        return try parseMessageRFC822(
            headers: headers,
            body: body,
            parameters: ct.parameters,
            encoding: encoding,
            disposition: disposition,
            dispParams: dispParams,
            filename: filename,
            cid: cid,
            specifier: specifier,
            depth: depth,
            state: state,
            internalDate: internalDate
        )
    }

    return try parseLeaf(
        headers: headers,
        body: body,
        type: ct.type,
        subtype: ct.subtype,
        parameters: ct.parameters,
        encoding: encoding,
        disposition: disposition,
        dispParams: dispParams,
        filename: filename,
        cid: cid,
        specifier: specifier,
        state: state
    )
}


private func parseMultipart(
    headers: [MIMEHeaderField],
    body: Data,
    type: String,
    subtype: String,
    parameters: [String: String],
    encoding: ContentTransferEncoding,
    disposition: String?,
    dispParams: [String: String],
    filename: String?,
    cid: String?,
    specifier: String,
    depth: Int,
    state: ParseState,
    internalDate: Date
) throws -> MIMEPart {
    let spec = specifier.isEmpty ? nil : specifier
    guard let boundary = parameters["boundary"], !boundary.isEmpty else {
        state.record(.malformedBoundary, specifier: spec, "multipart missing boundary")
        return MIMEPart(
            specifier: specifier,
            type: type,
            subtype: subtype,
            parameters: parameters,
            transferEncoding: encoding,
            disposition: disposition,
            dispositionParameters: dispParams,
            filename: filename,
            contentID: cid,
            headers: headers,
            octetCount: body.count
        )
    }

    let (decodedBody, _) = try decodeTransferEncoding(
        body, encoding: encoding, state: state, specifier: spec, cap: nil
    )

    var children: [MIMEPart] = []
    if depth >= MIMELimits.maxNestingDepth {
        state.record(.nestingTooDeep, specifier: spec, "multipart children exceed depth \(MIMELimits.maxNestingDepth)")
    } else {
        let split = splitMultipart(decodedBody, boundary: boundary, state: state, specifier: spec)
        let childDefault: (String, String) = subtype == "digest" ? ("message", "rfc822") : ("text", "plain")
        let limit = min(split.parts.count, MIMELimits.maxParts)
        if split.parts.count > MIMELimits.maxParts {
            state.record(.malformedBoundary, specifier: spec, "more than \(MIMELimits.maxParts) parts")
        }
        for idx in 0..<limit {
            let childSpec = childSpecifier(parent: specifier, index: idx + 1)
            if specifierComponentCount(childSpec) > MIMELimits.maxNestingDepth {
                state.record(.nestingTooDeep, specifier: spec, childSpec)
                break
            }
            let (child, _) = try parseRFC822(
                split.parts[idx],
                specifier: childSpec,
                depth: depth + 1,
                state: state,
                internalDate: internalDate,
                defaultType: childDefault
            )
            children.append(child)
        }
    }


    return MIMEPart(
        specifier: specifier,
        type: type,
        subtype: subtype,
        parameters: parameters,
        transferEncoding: encoding,
        disposition: disposition,
        dispositionParameters: dispParams,
        filename: filename,
        contentID: cid,
        headers: headers,
        children: children,
        octetCount: body.count,
        decodedOctetCount: decodedBody.count
    )
}

private func parseMessageRFC822(
    headers: [MIMEHeaderField],
    body: Data,
    parameters: [String: String],
    encoding: ContentTransferEncoding,
    disposition: String?,
    dispParams: [String: String],
    filename: String?,
    cid: String?,
    specifier: String,
    depth: Int,
    state: ParseState,
    internalDate: Date
) throws -> MIMEPart {
    let spec = specifier.isEmpty ? nil : specifier
    let (decoded, _) = try decodeTransferEncoding(
        body, encoding: encoding, state: state, specifier: spec, cap: nil
    )

    var children: [MIMEPart] = []
    var nestedEnvelope: Envelope?
    if depth >= MIMELimits.maxNestingDepth {
        state.record(.nestingTooDeep, specifier: spec, "message/rfc822 nesting exceeds depth \(MIMELimits.maxNestingDepth)")
    } else {
        let (inner, env) = try parseRFC822(
            decoded,
            specifier: specifier,
            depth: depth + 1,
            state: state,
            internalDate: internalDate,
            defaultType: ("text", "plain")
        )
        nestedEnvelope = env
        if inner.isMultipart || inner.isMessageRFC822 {
            children = inner.children
        } else {
            var leaf = inner
            leaf.specifier = childSpecifier(parent: specifier, index: 1)
            children = [leaf]
        }
    }

    return MIMEPart(
        specifier: specifier,
        type: "message",
        subtype: "rfc822",
        parameters: parameters,
        transferEncoding: encoding,
        disposition: disposition,
        dispositionParameters: dispParams,
        filename: filename,
        contentID: cid,
        headers: headers,
        children: children,
        octetCount: body.count,
        decodedOctetCount: decoded.count,
        nestedEnvelope: nestedEnvelope
    )
}

private func parseLeaf(
    headers: [MIMEHeaderField],
    body: Data,
    type: String,
    subtype: String,
    parameters: [String: String],
    encoding: ContentTransferEncoding,
    disposition: String?,
    dispParams: [String: String],
    filename: String?,
    cid: String?,
    specifier: String,
    state: ParseState
) throws -> MIMEPart {
    let spec = specifier.isEmpty ? nil : specifier
    let isText = type == "text"
    let cap = isText ? MIMELimits.decodedTextPart : nil
    let (decoded, truncated) = try decodeTransferEncoding(
        body, encoding: encoding, state: state, specifier: spec, cap: cap
    )
    var text: String?
    var wasTruncated = truncated
    if isText {
        if truncated {
            state.record(.textPartTruncated, specifier: spec, "decoded text part exceeded 8 MiB")
        }
        var decodedText = decodeCharset(
            decoded,
            charset: parameters["charset"],
            state: state,
            specifier: spec
        )
        decodedText = normalizeNewlines(decodedText)
        if subtype == "plain", (parameters["format"] ?? "").lowercased() == "flowed" {
            let delsp = (parameters["delsp"] ?? "").lowercased() == "yes"
            decodedText = reflowFormatFlowed(decodedText, delsp: delsp)
        }
        let utf8Count = decodedText.utf8.count
        if utf8Count > MIMELimits.decodedTextPart {
            decodedText = truncateUTF8(decodedText, maxBytes: MIMELimits.decodedTextPart)
            wasTruncated = true
            if !truncated {
                state.record(.textPartTruncated, specifier: spec, "decoded UTF-8 text exceeded 8 MiB")
            }
        }
        text = decodedText
    }
    return MIMEPart(
        specifier: specifier,
        type: type,
        subtype: subtype,
        parameters: parameters,
        transferEncoding: encoding,
        disposition: disposition,
        dispositionParameters: dispParams,
        filename: filename,
        contentID: cid,
        headers: headers,
        text: text,
        isTruncated: wasTruncated,
        octetCount: body.count,
        decodedOctetCount: decoded.count
    )
}

func childSpecifier(parent: String, index: Int) -> String {
    parent.isEmpty ? "\(index)" : "\(parent).\(index)"
}

func specifierComponentCount(_ spec: String) -> Int {
    if spec.isEmpty { return 0 }
    var n = 1
    for ch in spec where ch == "." { n += 1 }
    return n
}

func truncateUTF8(_ text: String, maxBytes: Int) -> String {
    if text.utf8.count <= maxBytes { return text }
    var count = 0
    var end = text.startIndex
    for i in text.indices {
        let n = text[i].utf8.count
        if count + n > maxBytes { break }
        count += n
        end = text.index(after: i)
    }
    return String(text[..<end])
}

// MARK: - Multipart split

struct MultipartSplit {
    var parts: [Data]
    var sawClose: Bool
}

func splitMultipart(
    _ data: Data,
    boundary: String,
    state: ParseState,
    specifier: String?
) -> MultipartSplit {
    let delim = Array("--\(boundary)".utf8)
    return data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        var parts: [Data] = []
        var sawClose = false
        var extraWSNoted = false

        guard let first = findBoundary(p, from: 0, delim: delim, extraWSNoted: &extraWSNoted) else {
            state.record(.malformedBoundary, specifier: specifier, "opening delimiter not found")
            return MultipartSplit(parts: [], sawClose: false)
        }
        if extraWSNoted {
            state.record(.malformedBoundary, specifier: specifier, "whitespace before boundary")
        }
        if first.close {
            return MultipartSplit(parts: [], sawClose: true)
        }

        var partStart = first.after
        var searchFrom = partStart
        while let next = findBoundary(p, from: searchFrom, delim: delim, extraWSNoted: &extraWSNoted) {
            let bodyEnd = lineDelimiterStart(p, next.start)
            if bodyEnd >= partStart {
                parts.append(data.view(partStart..<bodyEnd))
            } else {
                parts.append(Data())
            }
            if parts.count >= MIMELimits.maxParts {
                state.record(.malformedBoundary, specifier: specifier, "more than \(MIMELimits.maxParts) parts")
                sawClose = true
                break
            }
            if next.close {
                sawClose = true
                break
            }
            partStart = next.after
            searchFrom = partStart
        }
        if !sawClose {
            state.record(.missingTerminalBoundary, specifier: specifier, "missing closing --\(boundary)--")
            if partStart <= p.count {
                if parts.isEmpty || searchFrom == partStart {
                    if findBoundary(p, from: partStart, delim: delim, extraWSNoted: &extraWSNoted) == nil {
                        parts.append(data.view(partStart..<p.count))
                    }
                }
            }
        }
        return MultipartSplit(parts: parts, sawClose: sawClose)
    }
}

private struct BoundaryHit {
    var start: Int
    var close: Bool
    var after: Int
}

private func findBoundary(
    _ p: UnsafeBufferPointer<UInt8>,
    from: Int,
    delim: [UInt8],
    extraWSNoted: inout Bool
) -> BoundaryHit? {
    var i = from
    while i < p.count {
        if i > 0 && !isEOL(p[i - 1]) {
            while i < p.count && !isEOL(p[i]) { i += 1 }
            if i < p.count { i = skipEOL(p, i) }
            continue
        }

        var j = i
        var ws = false
        while j < p.count && isWSP(p[j]) {
            ws = true
            j += 1
        }
        if matchBytes(p, at: j, delim) {
            var k = j + delim.count
            var close = false
            if k + 1 < p.count && p[k] == 45 && p[k + 1] == 45 {
                close = true
                k += 2
            }
            while k < p.count && isWSP(p[k]) { k += 1 }
            if k >= p.count || isEOL(p[k]) {
                if ws { extraWSNoted = true }
                let after = k < p.count ? skipEOL(p, k) : k
                return BoundaryHit(start: i, close: close, after: after)
            }
        }

        while i < p.count && !isEOL(p[i]) { i += 1 }
        if i < p.count { i = skipEOL(p, i) }
    }
    return nil
}

private func matchBytes(_ p: UnsafeBufferPointer<UInt8>, at i: Int, _ needle: [UInt8]) -> Bool {
    guard i + needle.count <= p.count else { return false }
    var k = 0
    while k < needle.count {
        if p[i + k] != needle[k] { return false }
        k += 1
    }
    return true
}

// MARK: - Preferred bodies & attachments

func selectPreferredBodies(_ root: MIMEPart) -> (String?, String?) {
    var plain: String?
    var html: String?
    walkBodies(root, plain: &plain, html: &html, inAlternative: false)
    return (plain, html)
}

private func walkBodies(_ part: MIMEPart, plain: inout String?, html: inout String?, inAlternative: Bool) {
    if part.isMultipart {
        let alternative = part.subtype == "alternative"
        if part.subtype == "related" {
            let startCID = part.parameters["start"].map { extractContentID($0) ?? $0 }
            if let startCID, let start = findRelatedStart(part, cid: startCID) {
                walkBodies(start, plain: &plain, html: &html, inAlternative: inAlternative)
                return
            }
            if let first = part.children.first {
                walkBodies(first, plain: &plain, html: &html, inAlternative: inAlternative)
                return
            }
        }
        for child in part.children {
            walkBodies(child, plain: &plain, html: &html, inAlternative: alternative || inAlternative)
        }
        return
    }
    if part.isMessageRFC822 {
        for child in part.children {
            walkBodies(child, plain: &plain, html: &html, inAlternative: inAlternative)
        }
        return
    }
    guard part.disposition != "attachment" else { return }
    guard part.type == "text", let text = part.text else { return }
    if part.subtype == "plain" {
        if inAlternative || plain == nil { plain = text }
    } else if part.subtype == "html" {
        if inAlternative || html == nil { html = text }
    }
}

private func findRelatedStart(_ related: MIMEPart, cid: String) -> MIMEPart? {
    related.children.first { child in
        if let c = child.contentID, c.caseInsensitiveCompare(cid) == .orderedSame {
            return true
        }
        return false
    }
}

func collectAttachments(_ root: MIMEPart) -> [AttachmentInfo] {
    var out: [AttachmentInfo] = []
    collectAttachments(root, into: &out)
    return out
}

private func collectAttachments(_ part: MIMEPart, into out: inout [AttachmentInfo]) {
    if part.isMultipart {
        for child in part.children { collectAttachments(child, into: &out) }
        return
    }
    if part.isMessageRFC822 {
        for child in part.children { collectAttachments(child, into: &out) }
        return
    }
    let isBodyText = part.type == "text"
        && (part.subtype == "plain" || part.subtype == "html")
        && part.disposition != "attachment"
    if part.contentID != nil || part.disposition == "attachment" || !isBodyText {
        let spec = part.specifier.isEmpty ? "1" : part.specifier
        let size: Int?
        if part.decodedOctetCount > 0 {
            size = part.decodedOctetCount
        } else if part.octetCount > 0 {
            size = estimatedDecodedSize(raw: part.octetCount, encoding: part.transferEncoding)
        } else {
            size = nil
        }
        out.append(
            AttachmentInfo(
                id: spec,
                filename: part.filename,
                mimeType: part.mediaType,
                sizeEstimate: size,
                contentID: part.contentID,
                transferEncoding: part.transferEncoding.rawValue
            )
        )
    }
}

private func estimatedDecodedSize(raw: Int, encoding: ContentTransferEncoding) -> Int {
    switch encoding {
    case .base64: return raw * 3 / 4
    default: return raw
    }
}
