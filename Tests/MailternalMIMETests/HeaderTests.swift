import Foundation
import Testing
@testable import MailternalMIME

@Test func emptyInputThrows() {
    #expect(throws: MIMEParseError.emptyInput) {
        try MIMEParser.parse(Data(), internalDate: MIMETestSupport.t0)
    }
}

@Test func simplePlainMessage() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: Alice <alice@example.com>",
            "To: Bob <bob@example.com>",
            "Subject: Hello",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Message-ID: <mid@example.com>",
        ],
        body: "hello world\n"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.subject == "Hello")
    #expect(msg.envelope.from.first?.address == "alice@example.com")
    #expect(msg.envelope.from.first?.displayName == "Alice")
    #expect(msg.envelope.to.first?.address == "bob@example.com")
    #expect(msg.envelope.rfcMessageID == "<mid@example.com>")
    #expect(msg.envelope.headerDate == dateUTC(year: 2020, month: 1, day: 1))
    #expect(msg.envelope.internalDate == MIMETestSupport.t0)
    #expect(msg.plainText == "hello world\n")
    #expect(msg.root.specifier == "1")
    #expect(msg.part(specifiedBy: "1")?.text == "hello world\n")
}

@Test func rfc2047AdjacentWordsJoin() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Subject: =?utf-8?Q?Hello?= =?utf-8?Q?_World?=",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.subject == "Hello World")
}

@Test func rfc2047Base64Japanese() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Subject: =?utf-8?B?5pel5pys6Kqe?=",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.subject == "日本語")
}

@Test func rfc2047QEncodedAddressName() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: =?utf-8?Q?Foo_Bar?= <foo@bar.com>",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: x",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.from.first?.displayName == "Foo Bar")
    #expect(msg.envelope.from.first?.address == "foo@bar.com")
}

@Test func rfc2231FilenameContinuations() throws {
    let data = Data("""
    From: a@b.com\r
    Date: Wed, 01 Jan 2020 00:00:00 +0000\r
    Subject: file\r
    Content-Type: application/pdf\r
    Content-Disposition: attachment;\r
     filename*0*=UTF-8''%E6%97%A5%E6%9C%AC;\r
     filename*1*=%E8%AA%9E%2E%70%64%66\r
    \r
    %PDF
    """.utf8)
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.root.filename == "日本語.pdf")
    #expect(msg.attachments.first?.filename == "日本語.pdf")
    #expect(msg.attachments.first?.id == "1")
}

@Test func messageIDReferencesNormalization() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: re",
            "Message-ID: <one@host>",
            "In-Reply-To: <prev@host> (comment)",
            "References: <root@host> <prev@host>",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.rfcMessageID == "<one@host>")
    #expect(msg.envelope.inReplyTo == "<prev@host>")
    #expect(msg.envelope.references == ["<root@host>", "<prev@host>"])
}

@Test func dateRFC5322AndBrokenForms() throws {
    let cases: [(String, Date)] = [
        ("Wed, 01 Jan 2020 00:00:00 +0000", dateUTC(year: 2020, month: 1, day: 1)),
        ("1 Jan 2020 00:00:00 +0000", dateUTC(year: 2020, month: 1, day: 1)),
        ("01 Jan 20 00:00:00 GMT", dateUTC(year: 2020, month: 1, day: 1)),
        ("01 Jan 2020 00:00:00 EST", dateUTC(year: 2020, month: 1, day: 1, offset: -5 * 3600)),
        ("01 Jan 2020 09:00:00 +0900", dateUTC(year: 2020, month: 1, day: 1, hour: 9, offset: 9 * 3600)),
        ("2020-01-01T00:00:00Z", dateUTC(year: 2020, month: 1, day: 1)),
        ("31/08/2026", dateUTC(year: 2026, month: 8, day: 31)),
        ("Aug 31 2026 16:22:00 +0000", dateUTC(year: 2026, month: 8, day: 31, hour: 16, minute: 22)),
    ]
    for (raw, expected) in cases {
        let parsed = parseRFC5322Date(raw)
        #expect(parsed == expected, "failed to parse \(raw) → \(String(describing: parsed))")
    }
}

@Test func missingDateRecordsDefect() throws {
    let data = MIMETestSupport.message(
        headers: ["From: a@b.com", "Subject: no date"],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.headerDate == nil)
    #expect(MIMETestSupport.hasDefect(msg, .missingDate))
}

@Test func malformedDateRecordsDefect() throws {
    let data = MIMETestSupport.message(
        headers: ["From: a@b.com", "Subject: x", "Date: not-a-date"],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.headerDate == nil)
    #expect(MIMETestSupport.hasDefect(msg, .malformedDate))
}

@Test func addressGroupsQuotedComments() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: \"Doe, John\" <john@example.com>",
            "To: Friends: alice@example.com, Bob (old) <bob@example.com>;",
            "Cc: carol@example.com (Carol)",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: g",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.from.first?.displayName == "Doe, John")
    #expect(msg.envelope.to.map(\.address) == ["alice@example.com", "bob@example.com"])
    #expect(msg.envelope.to[1].displayName == "Bob")
    #expect(msg.envelope.cc.first?.address == "carol@example.com")
    #expect(msg.envelope.cc.first?.displayName == "Carol")
}

@Test func undisclosedRecipientsGroup() throws {
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "To: undisclosed-recipients:;",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: x",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.to.isEmpty)
}

@Test func headerUnfolding() throws {
    let data = Data("""
    From: a@b.com\r
    Subject: one\r
     two\r
    Date: Wed, 01 Jan 2020 00:00:00 +0000\r
    \r
    body
    """.utf8)
    let msg = try MIMETestSupport.parse(data)
    #expect(msg.envelope.subject == "one two" || msg.envelope.subject.contains("one"))
    #expect(msg.envelope.subject.contains("two"))
}

@Test func eightBitSubjectDecoded() throws {
    var bytes: [UInt8] = Array("From: a@b.com\r\nSubject: caf".utf8)
    bytes.append(0xE9)
    bytes.append(contentsOf: Array("\r\nDate: Wed, 01 Jan 2020 00:00:00 +0000\r\n\r\nbody\r\n".utf8))
    let msg = try MIMETestSupport.parse(Data(bytes))
    #expect(MIMETestSupport.hasDefect(msg, .eightBitHeader))
    #expect(msg.envelope.subject.contains("caf"))
}
