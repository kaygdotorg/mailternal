import Foundation
import MailternalInterfaces
import NIO
import Testing
@testable import MailternalIMAP

struct IMAPSentCopyTests {
    @Test func searchDoesNotConfuseMissingResponseWithMissingCopy() async throws {
        try await ScriptedIMAP.run(security: .implicitTLS) { imap in
            try await imap.connectImplicit()
            let selecting = Task { try await imap.session.select("Sent") }
            let selection = try await imap.expectCommand(containing: "SELECT")
            try await imap.writeServer("* FLAGS (\\Seen)")
            try await imap.writeServer("* 2 EXISTS")
            try await imap.writeServer("* OK [UIDVALIDITY 1] stable")
            try await imap.writeServer("* OK [UIDNEXT 43] next")
            try await imap.ok(selection.tag)
            _ = try await selecting.value

            let existing = Task { try await imap.session.containsMessageID("<existing@example.test>") }
            let foundQuery = try await imap.expectCommand(containing: "UID SEARCH")
            try await imap.writeServer("* SEARCH 42")
            try await imap.ok(foundQuery.tag)
            #expect(try await existing.value)

            let missing = Task { try await imap.session.containsMessageID("<missing@example.test>") }
            let emptyQuery = try await imap.expectCommand(containing: "UID SEARCH")
            try await imap.writeServer("* SEARCH")
            try await imap.ok(emptyQuery.tag)
            #expect(try await !missing.value)

            let malformed = Task { try await imap.session.containsMessageID("<uncertain@example.test>") }
            let incompleteQuery = try await imap.expectCommand(containing: "UID SEARCH")
            try await imap.ok(incompleteQuery.tag)
            do {
                _ = try await malformed.value
                Issue.record("An incomplete search must not permit another Sent copy")
            } catch IMAPError.parse {
                // A protocol error is different from an explicitly empty result.
            }
        }
    }

    @Test func streamedSentCopyDoesNotSucceedOnTaggedRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("message.eml")
        let bodyLine = String(repeating: "x", count: 75) + "\r\n"
        let data = Data(("Subject: Streamed copy\r\n\r\n" + String(repeating: bodyLine, count: 1_800)).utf8)
        try data.write(to: file)

        try await ScriptedIMAP.run(security: .implicitTLS) { imap in
            try await imap.connectImplicit()
            let appending = Task {
                try await imap.session.append(
                    fileURL: file, byteCount: Int64(data.count), to: "Sent",
                    date: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
            let command = try await imap.expectCommand(containing: "APPEND")
            #expect(command.line.hasSuffix("{\(data.count)}"))
            try await imap.writeServer("+ Continue")
            var received = Data()
            while received.count < data.count + 2 {
                let buffer = try await imap.channel.waitForOutboundWrite(as: ByteBuffer.self)
                received.append(contentsOf: buffer.readableBytesView)
            }
            var expected = data
            expected.append(contentsOf: [13, 10])
            #expect(received == expected)
            try await imap.no(command.tag, "Cannot store the message")
            do {
                try await appending.value
                Issue.record("Writing all bytes is not a successful Sent-copy acknowledgement")
            } catch IMAPError.taggedNO {
                // The durable outbox keeps this as copy-only pending work.
            }
        }
    }
}
