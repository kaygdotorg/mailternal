import Foundation
import MailternalInterfaces

func parseAddressList(_ value: String, state: ParseState, specifier: String?) -> [MailAddress] {
    let decoded = decodeEncodedWords(value, state: state, specifier: specifier)
    if trimWS(decoded).isEmpty { return [] }
    var scan = AddressScan(decoded)
    var out: [MailAddress] = []
    scan.skipCFWS()
    while !scan.atEnd {
        if scan.peek() == "," {
            scan.advance()
            scan.skipCFWS()
            continue
        }
        if let group = scan.tryGroup(state: state, specifier: specifier) {
            out.append(contentsOf: group)
            scan.skipCFWS()
            continue
        }
        if let box = scan.takeMailbox(state: state, specifier: specifier) {
            out.append(box)
        } else {
            state.record(.malformedAddress, specifier: specifier, "unparseable address token")
            scan.skipToCommaOrSemicolon()
        }
        scan.skipCFWS()
        if scan.peek() == "," { scan.advance() }
        scan.skipCFWS()
    }
    return out
}

private struct AddressScan {
    let s: String
    var i: String.Index

    init(_ s: String) {
        self.s = s
        self.i = s.startIndex
    }

    var atEnd: Bool { i >= s.endIndex }

    func peek() -> Character? { atEnd ? nil : s[i] }

    mutating func advance() {
        if !atEnd { i = s.index(after: i) }
    }

    mutating func skipCFWS() {
        while !atEnd {
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
        while !atEnd && depth > 0 {
            let ch = s[i]
            if ch == "\\" {
                advance()
                if !atEnd {
                    out.append(s[i])
                    advance()
                }
                continue
            }
            if ch == "(" { depth += 1; advance(); continue }
            if ch == ")" { depth -= 1; advance(); continue }
            if depth == 1 { out.append(ch) }
            advance()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    mutating func takeQuotedString() -> String {
        guard peek() == "\"" else { return "" }
        advance()
        var out = ""
        while !atEnd {
            let ch = s[i]
            if ch == "\\" {
                advance()
                if !atEnd {
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

    mutating func tryGroup(state: ParseState, specifier: String?) -> [MailAddress]? {
        let saved = i
        skipCFWS()
        _ = collectPhraseAndPeek(stopAtColon: true)
        skipCFWS()
        guard peek() == ":" else {
            i = saved
            return nil
        }
        advance()
        var members: [MailAddress] = []
        skipCFWS()
        while !atEnd && peek() != ";" {
            if peek() == "," {
                advance()
                skipCFWS()
                continue
            }
            if let box = takeMailbox(state: state, specifier: specifier) {
                members.append(box)
            } else {
                state.record(.malformedAddress, specifier: specifier, "unparseable group member")
                skipToCommaOrSemicolon()
            }
            skipCFWS()
        }
        if peek() == ";" { advance() }
        return members
    }

    mutating func takeMailbox(state: ParseState, specifier: String?) -> MailAddress? {
        skipCFWS()
        if peek() == "<" {
            guard let addr = takeAngleAddr() else {
                state.record(.malformedAddress, specifier: specifier, "broken angle-addr")
                return nil
            }
            skipCFWS()
            var commentName: String?
            if peek() == "(" {
                let c = takeComment()
                if !c.isEmpty { commentName = c }
            }
            return MailAddress(displayName: emptyToNil(commentName), address: addr)
        }

        let saved = i
        var comments: [String] = []
        let phrase = collectPhrase(comments: &comments)
        skipCFWS()
        if peek() == "<" {
            guard let addr = takeAngleAddr() else {
                state.record(.malformedAddress, specifier: specifier, "broken name-addr")
                return nil
            }
            let name = emptyToNil(phrase) ?? emptyToNil(comments.last)
            return MailAddress(displayName: name, address: addr)
        }

        // Bare addr-spec: rewind and read it from the phrase region.
        i = saved
        skipCFWS()
        if let spec = takeAddrSpec() {
            skipOnlyWS()
            var name: String?
            if peek() == "(" {
                let c = takeComment()
                if !c.isEmpty { name = c }
            }
            return MailAddress(displayName: emptyToNil(name), address: spec)
        }

        i = saved
        return nil
    }

    mutating func takeAngleAddr() -> String? {
        guard peek() == "<" else { return nil }
        advance()
        skipCFWS()
        // obs-route: @domain[,@domain]:
        if peek() == "@" {
            while !atEnd && peek() != ":" {
                advance()
            }
            if peek() == ":" { advance() }
            skipCFWS()
        }
        guard let spec = takeAddrSpec() else {
            while !atEnd && peek() != ">" { advance() }
            if peek() == ">" { advance() }
            return nil
        }
        skipCFWS()
        if peek() == ">" { advance() }
        return spec
    }

    mutating func takeAddrSpec() -> String? {
        skipCFWS()
        let local: String
        if peek() == "\"" {
            let q = takeQuotedString()
            local = "\"\(q)\""
        } else {
            let start = i
            while !atEnd {
                let ch = s[i]
                if ch == "@" || ch == ">" || ch == "," || ch == ";" || ch == " " || ch == "\t"
                    || ch == "\r" || ch == "\n" || ch == "(" || ch == "<" {
                    break
                }
                advance()
            }
            local = String(s[start..<i])
        }
        skipCFWS()
        guard peek() == "@" else { return local.isEmpty ? nil : nil }
        advance()
        skipCFWS()
        let domain: String
        if peek() == "[" {
            let start = i
            advance()
            while !atEnd && peek() != "]" { advance() }
            if peek() == "]" { advance() }
            domain = String(s[start..<i])
        } else {
            let start = i
            while !atEnd {
                let ch = s[i]
                if ch == ">" || ch == "," || ch == ";" || ch == " " || ch == "\t"
                    || ch == "\r" || ch == "\n" || ch == "(" || ch == "<" {
                    break
                }
                advance()
            }
            domain = String(s[start..<i])
        }
        if local.isEmpty || domain.isEmpty { return nil }
        return "\(local)@\(domain)"
    }

    mutating func collectPhrase(comments: inout [String]) -> String {
        var parts: [String] = []
        while !atEnd {
            skipOnlyWS()
            let ch = peek()
            if ch == nil || ch == "<" || ch == "," || ch == ";" || ch == ":" {
                break
            }
            if ch == "(" {
                let c = takeComment()
                if !c.isEmpty { comments.append(c) }
                continue
            }
            if ch == "\"" {
                parts.append(takeQuotedString())
                continue
            }
            let start = i
            while !atEnd {
                let c = s[i]
                if c == "<" || c == "," || c == ";" || c == ":" || c == "("
                    || c == "\"" || c == " " || c == "\t" || c == "\r" || c == "\n" {
                    break
                }
                advance()
            }
            let word = String(s[start..<i])
            if !word.isEmpty { parts.append(word) }
            if peek() == " " || peek() == "\t" {
                // keep looping; skipOnlyWS next
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    mutating func collectPhraseAndPeek(stopAtColon: Bool) -> String {
        var comments: [String] = []
        let saved = i
        let phrase = collectPhrase(comments: &comments)
        if stopAtColon && peek() != ":" {
            i = saved
        }
        return phrase
    }

    mutating func skipOnlyWS() {
        while !atEnd {
            let ch = s[i]
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                advance()
            } else {
                break
            }
        }
    }

    mutating func skipToCommaOrSemicolon() {
        while !atEnd {
            let ch = s[i]
            if ch == "," || ch == ";" { break }
            if ch == "\"" {
                _ = takeQuotedString()
                continue
            }
            if ch == "(" {
                _ = takeComment()
                continue
            }
            advance()
        }
    }
}

private func emptyToNil(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}
