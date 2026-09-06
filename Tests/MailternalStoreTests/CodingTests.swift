import Foundation
import Testing
@testable import MailternalStore

@Test func previewNormalizesUnicodeWhitespaceAndPreservesGraphemes() {
    let body = "\u{00A0}\u{2003}Cafe\u{301}\t\t👨‍👩‍👧‍👦\n🇺🇳\u{2028}  done\u{00A0}\u{2002}"

    #expect(Preview.make(from: body) == "Cafe\u{301} 👨‍👩‍👧‍👦 🇺🇳 done")
}

@Test func previewKeepsSeparatorAtTheTwoHundredthCharacter() {
    let prefix = String(repeating: "x", count: 199)
    let body = prefix + "\u{2003}\u{2003}tail that is not part of the preview"

    #expect(Preview.make(from: body) == prefix + " ")
    #expect(Preview.make(from: body).count == Preview.maxChars)
}

@Test func previewLooksAheadAcrossCombiningCharactersAtBoundary() {
    let x199 = String(repeating: "x", count: 199)
    let x198 = String(repeating: "x", count: 198)

    #expect(Preview.make(from: x199 + "\n\u{0301}tail") == x199 + " \u{0301}")
    #expect(Preview.make(from: x198 + "\r\n\u{0301}tail") == x198 + " \u{0301}t")
    #expect(Preview.make(from: x199 + "\n\u{200D}tail") == x199 + " \u{200D}")
}

@Test func previewMatchesPreviousNormalizationAcrossUnicodeCorpus() {
    let corpus: [String?] = [
        nil,
        "",
        "  leading and trailing  ",
        "\u{00A0}\u{2003}repeated\u{2003}\u{2003}whitespace\u{00A0}",
        "e\u{301} cafe\u{301} 👩🏽‍💻 🇺🇳",
        String(repeating: "e\u{301}", count: 200),
        String(repeating: "👨‍👩‍👧‍👦", count: 200),
        String(repeating: "word ", count: 60) + String(repeating: "suffix\u{2003}", count: 1_000),
    ]

    for body in corpus {
        #expect(Preview.make(from: body) == previousPreview(from: body))
    }
}

private func previousPreview(from body: String?) -> String {
    guard let body, !body.isEmpty else { return "" }
    let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if collapsed.count <= 200 { return collapsed }
    let end = collapsed.index(collapsed.startIndex, offsetBy: 200)
    return String(collapsed[..<end])
}
