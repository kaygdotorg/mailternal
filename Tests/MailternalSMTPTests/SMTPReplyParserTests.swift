import Testing
@testable import MailternalSMTP

@Test func fragmentedAndCoalescedMultilineReplies() throws {
    var parser = SMTPReplyParser()
    let first = Array("250-example.test\r\n250-SIZE 4096\r\n".utf8)
    let second = Array("250 SMTPUTF8\r\n220 ready\r\n".utf8)
    var replies: [SMTPReply] = []
    for byte in first {
        if let reply = try parser.feed(byte) { replies.append(reply) }
    }
    for byte in second {
        if let reply = try parser.feed(byte) { replies.append(reply) }
    }

    #expect(replies.count == 2)
    #expect(replies[0].code == 250)
    #expect(replies[0].lines == ["example.test", "SIZE 4096", "SMTPUTF8"])
    #expect(replies[1].code == 220)
}

@Test func multilineReplyMustKeepItsStatusCode() {
    var parser = SMTPReplyParser()
    let bytes = Array("250-first\r\n251 last\r\n".utf8)
    #expect(throws: SMTPWireError.self) {
        for byte in bytes { _ = try parser.feed(byte) }
    }
}

@Test func replyWithoutOptionalTextIsAccepted() throws {
    var parser = SMTPReplyParser()
    var reply: SMTPReply?
    for byte in Array("250\r\n".utf8) {
        reply = try parser.feed(byte) ?? reply
    }
    #expect(reply?.code == 250)
    #expect(reply?.lines == [""])
}

@Test func bareLineEndingsAreRejected() {
    var parser = SMTPReplyParser()
    #expect(throws: SMTPWireError.self) {
        for byte in Array("220 ready\n".utf8) { _ = try parser.feed(byte) }
    }
}
