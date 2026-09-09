import Foundation
import MailternalInterfaces

/// Incrementally validates CRLF MIME serialization and applies SMTP DATA
/// dot-stuffing. The state is carried across file-read chunks.
struct SMTPDataEncoder {
    private(set) var atLineStart = true
    private var pendingCR = false
    private(set) var inputByteCount: Int64 = 0

    mutating func encode(_ data: Data) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(data.count + 1)
        for byte in data {
            inputByteCount += 1
            if pendingCR {
                guard byte == 0x0A else { throw SMTPSubmissionError(kind: .message, message: "The MIME file contains a bare carriage return.") }
                output.append(byte)
                pendingCR = false
                atLineStart = true
                continue
            }
            if byte == 0x0D {
                output.append(byte)
                pendingCR = true
                atLineStart = false
                continue
            }
            guard byte != 0x0A else {
                throw SMTPSubmissionError(kind: .message, message: "The MIME file contains a bare line feed.")
            }
            if atLineStart, byte == 0x2E {
                output.append(0x2E)
            }
            output.append(byte)
            atLineStart = false
        }
        return output
    }

    mutating func finish() throws {
        guard !pendingCR else {
            throw SMTPSubmissionError(kind: .message, message: "The MIME file ends with a bare carriage return.")
        }
        guard atLineStart || inputByteCount == 0 else {
            throw SMTPSubmissionError(kind: .message, message: "The MIME file must end with CRLF.")
        }
    }
}
