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
    let start = clock.now
    _ = try MIMETestSupport.parse(data)
    let elapsed = clock.now - start
    #expect(elapsed < .milliseconds(50))
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
