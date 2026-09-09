import Foundation
import MailternalInterfaces
import Testing
@testable import MailternalSMTP

@Test func dotStuffingCarriesLineStateAcrossChunks() throws {
    var encoder = SMTPDataEncoder()
    let first = try encoder.encode(Data("prefix\r".utf8))
    let second = try encoder.encode(Data("\n.leading\r\n..already-stuffed\r\n".utf8))
    try encoder.finish()

    let result = Data(first + second)
    #expect(String(decoding: result, as: UTF8.self) == "prefix\r\n..leading\r\n...already-stuffed\r\n")
}

@Test func bareLineFeedAndMissingFinalCRLFAreRejected() throws {
    var bareLF = SMTPDataEncoder()
    #expect(throws: SMTPSubmissionError.self) {
        _ = try bareLF.encode(Data("bad\n".utf8))
    }

    var missingTerminator = SMTPDataEncoder()
    _ = try missingTerminator.encode(Data("missing".utf8))
    #expect(throws: SMTPSubmissionError.self) {
        try missingTerminator.finish()
    }
}
