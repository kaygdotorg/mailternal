import Foundation
import Testing
@testable import MailternalMIME

@Test func multipartAlternativeSelectsBoth() throws {
    let msg = try MIMETestSupport.parseEML("simple-alternative.eml")
    #expect(msg.plainText?.contains("plain body") == true)
    #expect(msg.html?.contains("<p>html body</p>") == true)
    #expect(msg.part(specifiedBy: "1")?.subtype == "plain")
    #expect(msg.part(specifiedBy: "2")?.subtype == "html")
    #expect(msg.root.isMultipart)
}

@Test func messageRFC822Nesting() throws {
    let msg = try MIMETestSupport.parseEML("message-rfc822.eml")
    #expect(msg.part(specifiedBy: "1")?.text?.contains("outer") == true)
    let inner = msg.part(specifiedBy: "2")
    #expect(inner?.isMessageRFC822 == true)
    #expect(inner?.nestedEnvelope?.subject == "Inner")
    #expect(msg.part(specifiedBy: "2.1")?.text?.contains("inner") == true)
}

@Test func formatFlowedDelsp() throws {
    let msg = try MIMETestSupport.parseEML("format-flowed.eml")
    let text = try #require(msg.plainText)
    #expect(text.contains("This is a long line that was wrapped with DelSp."))
    #expect(!text.contains("was \nwrapped"))
}
@Test func formatFlowedDelspYesJoinsMidWord() throws {
    let flowed = "This is a long line that was wra \npped with DelSp.\n"
    #expect(reflowFormatFlowed(flowed, delsp: true).contains("This is a long line that was wrapped with DelSp."))
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: delsp",
            "Content-Type: text/plain; charset=utf-8; format=flowed; delsp=yes",
        ],
        body: flowed,
        contentType: nil
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.plainText?.contains("This is a long line that was wrapped with DelSp.") == true)
}


@Test func brokenQuotedPrintableTolerated() throws {
    let msg = try MIMETestSupport.parseEML("broken-qp.eml")
    #expect(MIMETestSupport.hasDefect(msg, .brokenQuotedPrintable))
    #expect(msg.plainText?.contains("Hello") == true)
}

@Test func brokenBase64Tolerated() throws {
    let msg = try MIMETestSupport.parseEML("broken-base64.eml")
    #expect(MIMETestSupport.hasDefect(msg, .brokenBase64))
    #expect(msg.plainText?.contains("Hello") == true)
}

@Test func windows1252DeclaredAsLatin1() throws {
    let msg = try MIMETestSupport.parseEML("windows-1252-as-latin1.eml")
    #expect(MIMETestSupport.hasDefect(msg, .mislabeledCharset))
    let text = try #require(msg.plainText)
    #expect(text.contains("Hello"))
    #expect(text.contains("world"))
    #expect(text.contains("\u{201C}") || text.contains("\u{201D}") || text.contains("™") || text.contains("\u{2122}"))
}

@Test func shiftJISBody() throws {
    let msg = try MIMETestSupport.parseEML("shift-jis.eml")
    #expect(msg.plainText == "日本語")
}

@Test func cidBecomesAttachment() throws {
    let data = Data("""
    From: a@b.com\r
    Date: Wed, 01 Jan 2020 00:00:00 +0000\r
    Subject: img\r
    MIME-Version: 1.0\r
    Content-Type: multipart/related; boundary="r"\r
    \r
    --r\r
    Content-Type: text/html; charset=utf-8\r
    \r
    <img src="cid:pic@x">\r
    --r\r
    Content-Type: image/png\r
    Content-ID: <pic@x>\r
    Content-Disposition: inline\r
    Content-Transfer-Encoding: base64\r
    \r
    AAAA\r
    --r--\r
    """.utf8)
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.html?.contains("cid:pic@x") == true)
    #expect(msg.attachments.contains { $0.contentID == "pic@x" && $0.id == "2" && $0.mimeType == "image/png" })
}

@Test func decodeTextPartAPI() throws {
    let encoded = Data("SGVsbG8gV29ybGQ=".utf8)
    let decoded = try MIMEParser.decodeTextPart(
        encoded,
        mediaType: "text/plain",
        charset: "utf-8",
        encoding: .base64
    )
    #expect(decoded.text == "Hello World")
    #expect(!decoded.isTruncated)
}

@Test func missingTerminalBoundary() throws {
    let msg = try MIMETestSupport.parseEML("missing-terminal-boundary.eml")
    #expect(MIMETestSupport.hasDefect(msg, .missingTerminalBoundary))
    #expect(msg.part(specifiedBy: "1")?.text?.contains("first") == true)
    #expect(msg.part(specifiedBy: "2")?.text?.contains("second") == true)
}

@Test func extraWhitespaceBoundary() throws {
    let msg = try MIMETestSupport.parseEML("extra-whitespace-boundary.eml")
    #expect(msg.part(specifiedBy: "1") != nil)
    #expect(msg.part(specifiedBy: "2") != nil)
}

@Test func malformedBoundaryStillReturnsEnvelope() throws {
    let msg = try MIMETestSupport.parseEML("malformed-boundary.eml")
    #expect(msg.envelope.subject == "No boundary")
    #expect(MIMETestSupport.hasDefect(msg, .malformedBoundary))
}
