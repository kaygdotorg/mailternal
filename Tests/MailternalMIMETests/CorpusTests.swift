import Foundation
import Testing
@testable import MailternalMIME

@Test func corpusSimpleAlternative() throws {
    let msg = try MIMETestSupport.parseEML("simple-alternative.eml")
    #expect(msg.envelope.subject == "Alternative")
    #expect(msg.plainText?.contains("plain body") == true)
    #expect(msg.html?.contains("html body") == true)
}

@Test func corpusMalformedBoundary() throws {
    let msg = try MIMETestSupport.parseEML("malformed-boundary.eml")
    #expect(msg.envelope.from.first?.address == "a@b.com")
    #expect(MIMETestSupport.hasDefect(msg, .malformedBoundary))
}

@Test func corpusMissingTerminal() throws {
    let msg = try MIMETestSupport.parseEML("missing-terminal-boundary.eml")
    #expect(MIMETestSupport.hasDefect(msg, .missingTerminalBoundary))
    #expect(msg.parts.contains { $0.text?.contains("first") == true })
    #expect(msg.parts.contains { $0.text?.contains("second") == true })
}

@Test func corpusExtraWhitespaceBoundary() throws {
    let msg = try MIMETestSupport.parseEML("extra-whitespace-boundary.eml")
    #expect(msg.part(specifiedBy: "1")?.text?.contains("alpha") == true)
    #expect(msg.part(specifiedBy: "2")?.text?.contains("beta") == true)
}

@Test func corpusMessageRFC822() throws {
    let msg = try MIMETestSupport.parseEML("message-rfc822.eml")
    #expect(msg.part(specifiedBy: "2")?.nestedEnvelope?.rfcMessageID == "<inner@host>")
}

@Test func corpusRFC2047And2231() throws {
    let h = try MIMETestSupport.parseEML("rfc2047-headers.eml")
    #expect(h.envelope.subject == "Hello World")
    let f = try MIMETestSupport.parseEML("rfc2231-params.eml")
    #expect(f.attachments.first?.filename == "日本語.pdf")
}

@Test func corpusBrokenTransferEncodings() throws {
    let qp = try MIMETestSupport.parseEML("broken-qp.eml")
    #expect(MIMETestSupport.hasDefect(qp, .brokenQuotedPrintable))
    let b64 = try MIMETestSupport.parseEML("broken-base64.eml")
    #expect(MIMETestSupport.hasDefect(b64, .brokenBase64))
}

@Test func corpusFormatFlowed() throws {
    let msg = try MIMETestSupport.parseEML("format-flowed.eml")
    #expect(msg.plainText?.contains("wrapped with DelSp") == true)
}

@Test func corpusMislabeledCharsets() throws {
    let w = try MIMETestSupport.parseEML("windows-1252-as-latin1.eml")
    #expect(MIMETestSupport.hasDefect(w, .mislabeledCharset))
    let j = try MIMETestSupport.parseEML("shift-jis.eml")
    #expect(j.plainText == "日本語")
}

@Test func corpusMissingDate() throws {
    let msg = try MIMETestSupport.parseEML("missing-date.eml")
    #expect(msg.envelope.headerDate == nil)
    #expect(MIMETestSupport.hasDefect(msg, .missingDate))
}

@Test func corpusEightBitHeaders() throws {
    let msg = try MIMETestSupport.parseEML("eight-bit-headers.eml")
    #expect(MIMETestSupport.hasDefect(msg, .eightBitHeader))
}

@Test func corpusDeepNesting() throws {
    let msg = try MIMETestSupport.parseEML("deep-nesting.eml")
    #expect(MIMETestSupport.hasDefect(msg, .nestingTooDeep))
    let deepest = msg.parts.map { specifierComponentCount($0.specifier) }.max() ?? 0
    #expect(deepest <= MIMELimits.maxNestingDepth)
}

@Test func corpusAddressGroups() throws {
    let msg = try MIMETestSupport.parseEML("address-groups.eml")
    #expect(msg.envelope.to.count == 2)
}

@Test func corpusMessageIDs() throws {
    let msg = try MIMETestSupport.parseEML("message-ids.eml")
    #expect(msg.envelope.rfcMessageID == "<one@host>")
    #expect(msg.envelope.references.count == 2)
}

@Test func everyCorpusFileParses() throws {
    let files = try MIMETestSupport.loadAllCorpus()
    #expect(!files.isEmpty)
    for file in files {
        let msg = try MIMETestSupport.parse(file.data)
        #expect(msg.envelope.internalDate == MIMETestSupport.t0)
        for part in msg.parts {
            if let text = part.text {
                #expect(text.utf8.count <= MIMELimits.decodedTextPart, "\(file.name) \(part.specifier)")
            }
            #expect(specifierComponentCount(part.specifier) <= MIMELimits.maxNestingDepth)
        }
    }
}
