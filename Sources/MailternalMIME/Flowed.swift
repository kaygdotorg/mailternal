import Foundation

/// RFC 3676 `format=flowed` reflow. Input may use CRLF or LF.
func reflowFormatFlowed(_ text: String, delsp: Bool) -> String {
    if text.isEmpty { return text }
    let lines = splitLines(text)
    var out = String()
    out.reserveCapacity(text.count)
    var i = 0
    while i < lines.count {
        let (quote, destuffed, flowed, isSig) = classifyFlowedLine(lines[i])
        if isSig || !flowed {
            appendQuoted(&out, quote: quote, body: destuffed)
            if i + 1 < lines.count || textHasTrailingNewline(text) {
                out.append("\n")
            }
            i += 1
            continue
        }
        var paragraph = destuffed
        if delsp, paragraph.hasSuffix(" ") {
            paragraph.removeLast()
        }
        var j = i + 1
        while j < lines.count {
            let next = classifyFlowedLine(lines[j])
            if next.isSig || next.quote != quote { break }
            var piece = next.destuffed
            if next.flowed && delsp && piece.hasSuffix(" ") {
                piece.removeLast()
            }
            paragraph += piece
            if !next.flowed {
                j += 1
                break
            }
            j += 1
        }
        appendQuoted(&out, quote: quote, body: paragraph)
        if j < lines.count || textHasTrailingNewline(text) {
            out.append("\n")
        }
        i = j
    }
    return out
}

private func textHasTrailingNewline(_ text: String) -> Bool {
    guard let last = text.last else { return false }
    return last == "\n" || last == "\r"
}

private func appendQuoted(_ out: inout String, quote: Int, body: String) {
    if quote > 0 {
        out.append(String(repeating: ">", count: quote))
        if !body.isEmpty { out.append(" ") }
    }
    out.append(body)
}

private func classifyFlowedLine(_ line: String) -> (quote: Int, destuffed: String, flowed: Bool, isSig: Bool) {
    var i = line.startIndex
    var quote = 0
    while i < line.endIndex, line[i] == ">" {
        quote += 1
        i = line.index(after: i)
    }
    var restStart = i
    if restStart < line.endIndex, line[restStart] == " " {
        restStart = line.index(after: restStart)
    }
    let destuffed = String(line[restStart...])
    let isSig = destuffed == "-- "
    let flowed = !isSig && destuffed.hasSuffix(" ")
    return (quote, destuffed, flowed, isSig)
}

func splitLines(_ text: String) -> [String] {
    var lines: [String] = []
    var start = text.startIndex
    var i = text.startIndex
    while i < text.endIndex {
        let ch = text[i]
        if ch == "\r" {
            lines.append(String(text[start..<i]))
            let next = text.index(after: i)
            if next < text.endIndex, text[next] == "\n" {
                i = text.index(after: next)
            } else {
                i = next
            }
            start = i
            continue
        }
        if ch == "\n" {
            lines.append(String(text[start..<i]))
            i = text.index(after: i)
            start = i
            continue
        }
        i = text.index(after: i)
    }
    if start < text.endIndex || (start == text.endIndex && !text.isEmpty && !textHasTrailingNewline(text)) {
        lines.append(String(text[start...]))
    } else if start == text.endIndex && lines.isEmpty {
        lines.append("")
    }
    return lines
}

func normalizeNewlines(_ text: String) -> String {
    if !text.contains("\r") { return text }
    var out = String()
    out.reserveCapacity(text.count)
    var i = text.startIndex
    while i < text.endIndex {
        let ch = text[i]
        if ch == "\r" {
            out.append("\n")
            let next = text.index(after: i)
            if next < text.endIndex, text[next] == "\n" {
                i = text.index(after: next)
            } else {
                i = next
            }
            continue
        }
        out.append(ch)
        i = text.index(after: i)
    }
    return out
}
