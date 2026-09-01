/// CSS sanitizer for `style` attributes and `<style>` blocks.
///
/// Removes every request-bearing construct: `@import`, `url()`, `image-set()`,
/// `expression()`, IE `behavior` / `-moz-binding`, and `javascript:`/`vbscript:`.
///
/// Processing is a lexer pass, not a regex over the raw string:
/// 1. Decode CSS escapes so `\75\72\6c(` and `\75 r\6c(` both become `url(`.
/// 2. Drop `/* comments */` (they concatenate identifiers: `u/**/rl` → `url`).
/// 3. Strip `@import`, request-bearing functions, and leftover script tokens.
enum CSSSanitizer {
    static func sanitize(_ css: String) -> String {
        var text = stripStyleBreakout(css)
        text = unescapeCSS(text)
        text = stripComments(text)
        text = stripAtRule(text, name: "import")
        text = stripFunctions(
            text,
            names: ["url", "expression", "image-set", "-webkit-image-set", "image", "cross-fade", "element"]
        )
        text = stripTokens(text)
        return text
    }

    /// Prevent `</style>` / `<script` from breaking out of a `<style>` element.
    private static func stripStyleBreakout(_ css: String) -> String {
        var text = css
        for needle in ["</style", "<script", "<!--", "-->"] {
            text = replaceInsensitive(text, needle, "")
        }
        return text
    }

    private static func stripTokens(_ css: String) -> String {
        var text = css
        text = replaceInsensitive(text, "javascript:", "")
        text = replaceInsensitive(text, "vbscript:", "")
        text = replaceInsensitive(text, "-moz-binding", "")
        text = replaceInsensitive(text, "behavior:", "")
        return text
    }

    /// Remove `/* … */`. Unclosed comments drop the remainder (fail closed).
    /// Empty comments concatenate adjacent identifiers (`u/**/rl` → `url`).
    private static func stripComments(_ css: String) -> String {
        var output = String()
        output.reserveCapacity(css.count)
        var index = css.startIndex
        while index < css.endIndex {
            let skipped = skipComment(css, index)
            if skipped != index {
                index = skipped
                continue
            }
            output.append(css[index])
            index = css.index(after: index)
        }
        return output
    }

    /// If `index` is at `/*`, return the index after the closing `*/` (or `endIndex`
    /// if unclosed). Consecutive comments are skipped. Otherwise returns `index`.
    private static func skipComment(_ input: String, _ index: String.Index) -> String.Index {
        var cursor = index
        while cursor < input.endIndex {
            guard input[cursor] == "/" else { return cursor }
            let next = input.index(after: cursor)
            guard next < input.endIndex, input[next] == "*" else { return cursor }
            cursor = input.index(after: next)
            var closed = false
            while cursor < input.endIndex {
                if input[cursor] == "*" {
                    let after = input.index(after: cursor)
                    if after < input.endIndex, input[after] == "/" {
                        cursor = input.index(after: after)
                        closed = true
                        break
                    }
                }
                cursor = input.index(after: cursor)
            }
            if !closed { return input.endIndex }
        }
        return cursor
    }

    private static func unescapeCSS(_ css: String) -> String {
        var output = String()
        output.reserveCapacity(css.count)
        var index = css.startIndex
        while index < css.endIndex {
            let character = css[index]
            if character != "\\" {
                output.append(character)
                index = css.index(after: index)
                continue
            }
            let afterSlash = css.index(after: index)
            if afterSlash == css.endIndex { break }

            var hex = String()
            var cursor = afterSlash
            while cursor < css.endIndex, hex.count < 6, css[cursor].isHexDigit {
                hex.append(css[cursor])
                cursor = css.index(after: cursor)
            }
            if !hex.isEmpty {
                if let value = UInt32(hex, radix: 16),
                   let scalar = Unicode.Scalar(value),
                   scalar.value >= 0x20 || scalar.value == 0x9 {
                    output.append(Character(scalar))
                }
                // CSS hex escapes consume one following whitespace as terminator,
                // so `\75 r\6c` collapses to `url`.
                if cursor < css.endIndex, css[cursor].isWhitespace {
                    cursor = css.index(after: cursor)
                }
                index = cursor
                continue
            }
            output.append(css[afterSlash])
            index = css.index(after: afterSlash)
        }
        return output
    }

    private static func stripAtRule(_ input: String, name: String) -> String {
        let needle = "@" + name
        var index = input.startIndex
        var output = String()
        output.reserveCapacity(input.count)
        while index < input.endIndex {
            let skipped = skipComment(input, index)
            if skipped != index {
                index = skipped
                continue
            }
            if isIdentifierBoundary(input, before: index),
               let afterName = matchIdent(input, index, needle) {
                var cursor = afterName
                var quote: Character?
                while cursor < input.endIndex {
                    let character = input[cursor]
                    if let current = quote {
                        if character == "\\" {
                            cursor = input.index(after: cursor)
                            if cursor < input.endIndex {
                                cursor = input.index(after: cursor)
                            }
                            continue
                        }
                        if character == current { quote = nil }
                    } else if character == "\"" || character == "'" {
                        quote = character
                    } else if character == ";" {
                        cursor = input.index(after: cursor)
                        break
                    } else if character == "}" {
                        break
                    }
                    cursor = input.index(after: cursor)
                }
                index = cursor
                continue
            }
            output.append(input[index])
            index = input.index(after: index)
        }
        return output
    }

    private static func stripFunctions(_ input: String, names: [String]) -> String {
        var index = input.startIndex
        var output = String()
        output.reserveCapacity(input.count)
        while index < input.endIndex {
            let skipped = skipComment(input, index)
            if skipped != index {
                index = skipped
                continue
            }
            var matchedEnd: String.Index?
            if isIdentifierBoundary(input, before: index) {
                for name in names {
                    if let afterName = matchIdent(input, index, name) {
                        var cursor = afterName
                        while cursor < input.endIndex {
                            cursor = skipComment(input, cursor)
                            guard cursor < input.endIndex, input[cursor].isWhitespace else { break }
                            cursor = input.index(after: cursor)
                        }
                        cursor = skipComment(input, cursor)
                        if cursor < input.endIndex, input[cursor] == "(" {
                            cursor = skipBalanced(input, opening: cursor)
                            matchedEnd = cursor
                            break
                        }
                    }
                }
            }
            if let end = matchedEnd {
                output.append("none")
                index = end
                continue
            }
            output.append(input[index])
            index = input.index(after: index)
        }
        return output
    }

    /// Match `needle` case-insensitively, ignoring CSS comments between characters
    /// so `u/**/rl` and `URL` both match `url`.
    private static func matchIdent(_ input: String, _ start: String.Index, _ needle: String) -> String.Index? {
        var index = start
        var needleIndex = needle.startIndex
        while needleIndex < needle.endIndex {
            index = skipComment(input, index)
            guard index < input.endIndex else { return nil }
            if input[index].lowercased() != needle[needleIndex].lowercased() { return nil }
            index = input.index(after: index)
            needleIndex = needle.index(after: needleIndex)
        }
        return skipComment(input, index)
    }

    /// `opening` points at `(`. Returns the index after the matching `)`.
    private static func skipBalanced(_ input: String, opening: String.Index) -> String.Index {
        var depth = 0
        var quote: Character?
        var cursor = opening
        while cursor < input.endIndex {
            let character = input[cursor]
            if let current = quote {
                if character == "\\" {
                    cursor = input.index(after: cursor)
                    if cursor < input.endIndex {
                        cursor = input.index(after: cursor)
                    }
                    continue
                }
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                cursor = input.index(after: cursor)
                if depth == 0 { return cursor }
                continue
            }
            cursor = input.index(after: cursor)
        }
        return cursor
    }

    private static func isIdentifierBoundary(_ input: String, before index: String.Index) -> Bool {
        if index == input.startIndex { return true }
        let previous = input[input.index(before: index)]
        if previous.isLetter || previous.isNumber { return false }
        if previous == "-" || previous == "_" { return false }
        return true
    }

    private static func matchInsensitive(_ input: String, _ start: String.Index, _ needle: String) -> String.Index? {
        var index = start
        var needleIndex = needle.startIndex
        while needleIndex < needle.endIndex {
            guard index < input.endIndex else { return nil }
            if input[index].lowercased() != needle[needleIndex].lowercased() { return nil }
            index = input.index(after: index)
            needleIndex = needle.index(after: needleIndex)
        }
        return index
    }

    private static func replaceInsensitive(_ input: String, _ needle: String, _ replacement: String) -> String {
        var index = input.startIndex
        var output = String()
        output.reserveCapacity(input.count)
        while index < input.endIndex {
            if let end = matchInsensitive(input, index, needle) {
                output.append(replacement)
                index = end
                continue
            }
            output.append(input[index])
            index = input.index(after: index)
        }
        return output
    }
}
