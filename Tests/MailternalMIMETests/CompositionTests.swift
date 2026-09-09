import Foundation
import Testing
import MailternalInterfaces
@testable import MailternalMIME

private func parsedAddress(_ value: String) throws -> MailAddress {
    let data = MIMETestSupport.message(
        headers: [
            "From: \(value)",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
        ],
        body: "seed"
    )
    return try MIMEParser.parse(data, internalDate: MIMETestSupport.t0).envelope.from[0]
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailternalMIME-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}

@Test func compositionNormalizesTextAndEncodesUnicodeHeaders() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let from = try parsedAddress("Jöhn Sender <sender@例え.テスト>")
    let to = try parsedAddress("Recipient <to@example.test>")
    let output = directory.appendingPathComponent("message.eml")
    let subject = "日本語 " + String(repeating: "𐐀", count: 24)
    let message = MIMEComposition(
        from: from,
        to: [to],
        cc: [],
        bcc: [],
        replyTo: [],
        subject: subject,
        plainText: "one\ntwo\rthree\r\nfour",
        html: nil,
        messageID: "<stable@example.test>",
        date: MIMETestSupport.t0,
        inReplyTo: nil,
        references: [],
        attachments: []
    )
    let result = try MIMEComposer.write(message, to: output)
    let data = try Data(contentsOf: output)
    let raw = String(decoding: data, as: UTF8.self)
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    #expect(permissions >= 0 && (permissions & 0o077) == 0)
    #expect(result.byteCount == Int64(data.count))
    #expect(raw.contains("Subject: =?UTF-8?B?"))
    let bytes = Array(data)
    #expect(!bytes.enumerated().contains {
        $0.element == 10 && ($0.offset == 0 || bytes[$0.offset - 1] != 13)
    })
    #expect(data.suffix(2) == Data([13, 10]))

    let parsed = try MIMEParser.parse(data, internalDate: MIMETestSupport.t0)
    #expect(parsed.envelope.subject == subject)
    #expect(parsed.envelope.from.first?.displayName == "Jöhn Sender")
    #expect(parsed.envelope.from.first?.address == "sender@例え.テスト")
    #expect(parsed.plainText == "one\r\ntwo\r\nthree\r\nfour\r\n")
    #expect(result.envelope.sender == "sender@例え.テスト")
    #expect(result.envelope.requiresSMTPUTF8)
}

@Test func compositionRejectsHeaderInjectionAndLeavesNoOutput() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("injected.eml")
    let message = MIMEComposition(
        from: try parsedAddress("sender@example.test"),
        to: [try parsedAddress("recipient@example.test")],
        cc: [],
        bcc: [],
        replyTo: [],
        subject: "safe\r\nBcc: leaked@example.test",
        plainText: "body",
        html: nil,
        messageID: "<stable@example.test>",
        date: MIMETestSupport.t0,
        inReplyTo: nil,
        references: [],
        attachments: []
    )

    #expect(throws: MIMECompositionError.invalidHeaderValue("Subject")) {
        try MIMEComposer.write(message, to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func compositionRoundTripsAlternativeAttachmentAndBccPrivacy() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let attachmentURL = directory.appendingPathComponent("payload.bin")
    let attachmentBytes = Data((0..<131_089).map { UInt8($0 & 0xff) })
    try attachmentBytes.write(to: attachmentURL, options: .atomic)
    let output = directory.appendingPathComponent("message.eml")
    let message = MIMEComposition(
        from: try parsedAddress("Sender <sender@example.test>"),
        to: [try parsedAddress("To <Dup@EXAMPLE.test>")],
        cc: [try parsedAddress("Cc <Dup@example.test>")],
        bcc: [try parsedAddress("Blind <dup@example.test>")],
        replyTo: [try parsedAddress("Replies <reply@example.test>")],
        subject: "Reply 日本語",
        plainText: "plain body",
        html: "<p>html body</p>",
        messageID: "<new@example.test>",
        date: MIMETestSupport.t0,
        inReplyTo: "<old@example.test>",
        references: ["<root@example.test>", "<old@example.test>"],
        attachments: [
            MIMEComposition.Attachment(
                fileURL: attachmentURL,
                filename: "résumé.bin",
                mimeType: "application/octet-stream"
            ),
        ]
    )

    let result = try MIMEComposer.write(message, to: output)
    let data = try Data(contentsOf: output)
    let raw = String(decoding: data, as: UTF8.self)
    #expect(result.byteCount == Int64(data.count))
    #expect(!raw.localizedCaseInsensitiveContains("bcc:"))
    #expect(!raw.localizedCaseInsensitiveContains("filename="))
    #expect(result.envelope.recipients == ["Dup@EXAMPLE.test", "dup@example.test"])
    #expect(!result.envelope.requiresSMTPUTF8)

    let parsed = try MIMEParser.parse(data, internalDate: MIMETestSupport.t0)
    #expect(parsed.envelope.inReplyTo == "<old@example.test>")
    #expect(parsed.envelope.references == ["<root@example.test>", "<old@example.test>"])
    #expect(parsed.envelope.replyTo.first?.address == "reply@example.test")
    #expect(parsed.plainText == "plain body")
    #expect(parsed.html == "<p>html body</p>")
    #expect(parsed.attachments.count == 1)
    #expect(parsed.attachments.first?.filename == "résumé.bin")

    let boundary = parsed.root.parameters["boundary"]!
    let attachmentHeader = "Content-Disposition: attachment"
    let attachmentPart = raw.components(separatedBy: attachmentHeader).last!
    let encodedBody = attachmentPart
        .components(separatedBy: "\r\n\r\n")[1]
        .components(separatedBy: "\r\n--\(boundary)")[0]
        .replacingOccurrences(of: "\r\n", with: "")
    #expect(Data(base64Encoded: encodedBody) == attachmentBytes)
}

@Test func compositionCollisionAndAttachmentFailurePreserveFilesystemSafety() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let existing = directory.appendingPathComponent("existing.eml")
    try Data("keep me".utf8).write(to: existing)
    let message = MIMEComposition(
        from: try parsedAddress("sender@example.test"),
        to: [],
        cc: [],
        bcc: [try parsedAddress("recipient@example.test")],
        replyTo: [],
        subject: "collision",
        plainText: "body",
        html: nil,
        messageID: "<stable@example.test>",
        date: MIMETestSupport.t0,
        inReplyTo: nil,
        references: [],
        attachments: []
    )
    #expect(throws: MIMECompositionError.destinationExists) {
        try MIMEComposer.write(message, to: existing)
    }
    let preserved = try Data(contentsOf: existing)
    #expect(preserved == Data("keep me".utf8))

    let link = directory.appendingPathComponent("existing-link.eml")
    let linkTarget = directory.appendingPathComponent("must-not-be-created.eml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkTarget)
    #expect(throws: MIMECompositionError.destinationExists) {
        try MIMEComposer.write(message, to: link)
    }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == linkTarget.path)
    #expect(!FileManager.default.fileExists(atPath: linkTarget.path))

    let failed = directory.appendingPathComponent("failed.eml")
    let missingAttachment = MIMEComposition.Attachment(
        fileURL: directory.appendingPathComponent("does-not-exist.bin"),
        filename: "missing.bin",
        mimeType: "application/octet-stream"
    )
    let failingMessage = MIMEComposition(
        from: message.from,
        to: message.to,
        cc: message.cc,
        bcc: message.bcc,
        replyTo: message.replyTo,
        subject: message.subject,
        plainText: message.plainText,
        html: message.html,
        messageID: message.messageID,
        date: message.date,
        inReplyTo: message.inReplyTo,
        references: message.references,
        attachments: [missingAttachment]
    )
    #expect(throws: MIMECompositionError.attachmentReadFailed(failingMessage.attachments[0].fileURL.path)) {
        try MIMEComposer.write(failingMessage, to: failed)
    }
    #expect(!FileManager.default.fileExists(atPath: failed.path))
}

@Test func compositionPreservesFoldedHeadersAndDetectsUTF8OutsideTheEnvelope() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("folded.eml")
    let subject = String(repeating: "A long subject with meaningful spaces ", count: 8) + "end"
    let body = String(repeating: "é=\t\r\n", count: 12_000) + "end"
    let message = MIMEComposition(
        from: try parsedAddress("sender@example.test"),
        to: [try parsedAddress("recipient@example.test")],
        cc: [],
        bcc: [],
        replyTo: [try parsedAddress("réponse@example.test")],
        subject: subject,
        plainText: body,
        html: nil,
        messageID: "<folded@example.test>",
        date: MIMETestSupport.t0,
        inReplyTo: nil,
        references: [],
        attachments: []
    )
    let result = try MIMEComposer.write(message, to: output)
    let data = try Data(contentsOf: output)
    let parsed = try MIMEParser.parse(data, internalDate: MIMETestSupport.t0)
    #expect(parsed.envelope.subject == subject)
    #expect(parsed.envelope.replyTo.first?.address == "réponse@example.test")
    #expect(parsed.plainText == body + "\r\n")
    #expect(result.envelope.requiresSMTPUTF8)
}

@Test func compositionRejectsBracketedIdentifiersWithoutRoutingSyntax() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("invalid-id.eml")
    let message = MIMEComposition(
        from: MailAddress(displayName: nil, address: "sender@example.test"),
        to: [],
        cc: [],
        bcc: [],
        replyTo: [],
        subject: "Invalid message identifier",
        plainText: "body",
        html: nil,
        messageID: "<missing-at-sign>",
        date: MIMETestSupport.t0,
        inReplyTo: nil,
        references: [],
        attachments: []
    )
    #expect(throws: MIMECompositionError.invalidMessageID("Message-ID")) {
        try MIMEComposer.write(message, to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
