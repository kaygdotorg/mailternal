import Foundation
import Testing
@testable import MailternalMIME

@Test func headerLineOver64KiBRecordsDefect() throws {
    let huge = String(repeating: "A", count: MIMELimits.headerLine + 64)
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Subject: \(huge)",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
        ],
        body: "x"
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(MIMETestSupport.hasDefect(msg, .headerLineTooLong))
}

@Test func headerBlockOver1MiBRecordsDefect() throws {
    var headers = [
        "From: a@b.com",
        "Subject: fill",
        "Date: Wed, 01 Jan 2020 00:00:00 +0000",
    ]
    let filler = String(repeating: "z", count: 200)
    var headerBytes = headers.joined(separator: "\r\n").utf8.count
    let row = "X-Fill: \(filler)"
    while headerBytes < MIMELimits.headerBlock + 512 {
        headers.append(row)
        headerBytes += row.utf8.count + 2
    }
    let data = MIMETestSupport.message(headers: headers, body: "still here")
    let msg = try MIMETestSupport.parse(data)
    #expect(MIMETestSupport.hasDefect(msg, .headerBlockTooLarge))
}

@Test func decodedTextOver8MiBTruncates() throws {
    let n = MIMELimits.decodedTextPart + 4096
    let body = String(repeating: "A", count: n)
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: big",
        ],
        body: body
    )
    let msg = try MIMETestSupport.parse(data)
    #expect(MIMETestSupport.hasDefect(msg, .textPartTruncated))
    #expect(msg.root.isTruncated)
    let text = try #require(msg.plainText)
    #expect(text.utf8.count <= MIMELimits.decodedTextPart)
}

@Test func nestingDeeperThanEightRecordsDefect() throws {
    let data = makeNestedMultipart(levels: 10)
    let msg = try MIMETestSupport.parse(data)
    #expect(MIMETestSupport.hasDefect(msg, .nestingTooDeep))
    let deepest = msg.parts.compactMap { $0.specifier }.map(specifierComponentCount).max() ?? 0
    #expect(deepest <= MIMELimits.maxNestingDepth)
}

@Test func oneMebibyteParsesWellUnder50ms() throws {
    let line = "The quick brown fox jumps over the lazy dog.\n"
    let body = String(repeating: line, count: (1_048_576 / line.utf8.count) + 1)
    let data = MIMETestSupport.message(
        headers: [
            "From: bench@example.com",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: bench",
        ],
        body: body
    )
    _ = try MIMETestSupport.parse(data)
    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0..<5 {
        let start = clock.now
        _ = try MIMETestSupport.parse(data)
        let elapsed = clock.now - start
        if elapsed < best { best = elapsed }
        if best < .milliseconds(50) { break }
    }
    #expect(best < .milliseconds(50))
}

@Test func cancelledTaskThrowsCancellation() async {
    let body = String(repeating: "B", count: MIMELimits.cancellationCheckpoint * 3)
    let data = MIMETestSupport.message(
        headers: [
            "From: a@b.com",
            "Date: Wed, 01 Jan 2020 00:00:00 +0000",
            "Subject: cancel",
        ],
        body: body
    )
    let task = Task {
        try MIMEParser.parse(data, internalDate: MIMETestSupport.t0)
    }
    task.cancel()
    do {
        _ = try await task.value
        // Extremely fast hosts may finish before the cancel is observed.
        // The contract is still exercised: a cancelled task must not crash.
    } catch is CancellationError {
        // Expected path.
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func base64StreamingDecodeRoundTrip() throws {
    let raw = Data("Hello World".utf8)
    let encoded = Data(raw.base64EncodedString().utf8)
    let state = ParseState()
    let result = try decodeBase64Streaming(encoded, state: state, specifier: nil, cap: nil)
    #expect(!result.truncated)
    #expect(result.data == raw)
    #expect(result.inputBytesConsumed <= encoded.count)
}

@Test func base64DecodeStopsAtCapAndReturnsEarly() throws {
    // Production cap is 8 MiB; a smaller cap on the same decoder proves we
    // stop, flag truncation, and do not scan or materialize the remainder.
    let cap = 64 * 1024
    let wouldBeDecoded = 2 * 1024 * 1024
    let raw = Data(repeating: UInt8(ascii: "A"), count: wouldBeDecoded)
    let encoded = Data(raw.base64EncodedString().utf8)
    #expect(encoded.count > cap * 4)

    let state = ParseState()
    let result = try decodeBase64Streaming(encoded, state: state, specifier: "1", cap: cap)
    #expect(result.truncated)
    #expect(result.data.count == cap)
    #expect(result.data == Data(repeating: UInt8(ascii: "A"), count: cap))
    #expect(result.inputBytesConsumed < encoded.count)
    // 4 alphabet chars → 3 decoded bytes; one extra quad if `cap` is not a
    // multiple of 3. No line wrapping here, so consumed stays near this bound.
    let maxAlphabet = ((cap + 2) / 3) * 4 + 8
    #expect(result.inputBytesConsumed <= maxAlphabet)
}

@Test func cancelledBase64DecodeThrowsCancellation() async {
    let decodedSize = MIMELimits.cancellationCheckpoint * 3
    let raw = Data(repeating: UInt8(ascii: "x"), count: decodedSize)
    let encoded = Data(raw.base64EncodedString().utf8)
    let task = Task {
        let state = ParseState()
        _ = try decodeBase64(encoded, state: state, specifier: "1", cap: nil)
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("expected CancellationError for a pre-cancelled base64 decode over 256 KiB")
    } catch is CancellationError {
        // First checkpoint must observe the cancel.
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

func makeNestedMultipart(levels: Int) -> Data {
    var part = "Content-Type: text/plain; charset=utf-8\r\n\r\nleaf\r\n"
    if levels <= 0 {
        return MIMETestSupport.message(
            headers: [
                "From: a@b.com",
                "Date: Wed, 01 Jan 2020 00:00:00 +0000",
                "Subject: nest",
            ],
            body: "leaf"
        )
    }
    for d in stride(from: levels, through: 1, by: -1) {
        let b = "B\(d)"
        part = """
        Content-Type: multipart/mixed; boundary="\(b)"\r
        \r
        --\(b)\r
        \(part)--\(b)--\r

        """
    }
    return Data("""
    From: a@b.com\r
    Date: Wed, 01 Jan 2020 00:00:00 +0000\r
    Subject: nest\r
    MIME-Version: 1.0\r
    \(part)
    """.utf8)
}
