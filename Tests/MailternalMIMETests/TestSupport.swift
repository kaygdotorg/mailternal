import Foundation
@testable import MailternalMIME

enum MIMETestSupport {
    static let t0 = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01T00:00:00Z

    static var corpusDirectory: URL {
        if let bundled = Bundle.module.url(forResource: "Corpus", withExtension: nil) {
            return bundled
        }
        // Isolated / no-resource-bundle builds still find the fixtures next to this file.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Corpus", isDirectory: true)
    }

    static func loadCorpus(_ name: String) throws -> Data {
        try Data(contentsOf: corpusDirectory.appendingPathComponent(name))
    }

    static func loadAllCorpus() throws -> [(name: String, data: Data)] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: corpusDirectory,
            includingPropertiesForKeys: nil
        )
        return try urls
            .filter { $0.pathExtension == "eml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { (name: $0.lastPathComponent, data: try Data(contentsOf: $0)) }
    }

    static func parse(_ data: Data) throws -> MIMEMessage {
        try MIMEParser.parse(data, internalDate: t0)
    }

    static func parseEML(_ name: String) throws -> MIMEMessage {
        try parse(loadCorpus(name))
    }

    static func message(
        headers: [String],
        body: String,
        contentType: String? = "text/plain; charset=utf-8"
    ) -> Data {
        var lines = headers
        if let contentType, !headers.contains(where: { $0.lowercased().hasPrefix("content-type:") }) {
            lines.append("Content-Type: \(contentType)")
        }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        return Data(text.utf8)
    }

    static func hasDefect(_ msg: MIMEMessage, _ kind: MIMEDefect.Kind) -> Bool {
        msg.defects.contains { $0.kind == kind }
    }
}

func dateUTC(
    year: Int, month: Int, day: Int,
    hour: Int = 0, minute: Int = 0, second: Int = 0,
    offset: Int = 0
) -> Date {
    var dc = DateComponents()
    dc.calendar = Calendar(identifier: .gregorian)
    dc.timeZone = TimeZone(secondsFromGMT: offset)
    dc.year = year
    dc.month = month
    dc.day = day
    dc.hour = hour
    dc.minute = minute
    dc.second = second
    return dc.date!
}
