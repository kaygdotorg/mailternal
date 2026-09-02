import Foundation

enum StoreJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(string.utf8))
    }
}

struct AttachmentInfoDTO: Codable, Sendable {
    var id: String
    var filename: String?
    var mimeType: String
    var sizeEstimate: Int?
    var contentID: String?
    var transferEncoding: String?

    init(_ info: AttachmentInfo) {
        id = info.id
        filename = info.filename
        mimeType = info.mimeType
        sizeEstimate = info.sizeEstimate
        contentID = info.contentID
        transferEncoding = info.transferEncoding
    }

    func makeInfo() -> AttachmentInfo {
        AttachmentInfo(
            id: id,
            filename: filename,
            mimeType: mimeType,
            sizeEstimate: sizeEstimate,
            contentID: contentID,
            transferEncoding: transferEncoding
        )
    }
}

enum AddressFormat {
    static func ftsText(_ addresses: [MailAddress]) -> String {
        addresses.map { addr in
            if let name = addr.displayName, !name.isEmpty {
                return "\(name) \(addr.address)"
            }
            return addr.address
        }.joined(separator: " ")
    }

    static func display(_ addresses: [MailAddress]) -> String {
        guard let first = addresses.first else { return "" }
        if let name = first.displayName, !name.isEmpty { return name }
        return first.address
    }
}

enum Preview {
    static let maxChars = 200

    static func make(from body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        let collapsed = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxChars)
        return String(collapsed[..<end])
    }
}

enum RoleOrder {
    static func sqlCase(_ column: String) -> String {
        """
        CASE \(column)
          WHEN 'inbox' THEN 0
          WHEN 'drafts' THEN 1
          WHEN 'sent' THEN 2
          WHEN 'archive' THEN 3
          WHEN 'junk' THEN 4
          WHEN 'trash' THEN 5
          ELSE 6
        END
        """
    }
}

extension BackfillState {
    static func from(phase: String?, progress: Double?, haltedThrough: Double?) -> BackfillState {
        switch BackfillPhase(rawValue: phase ?? "") {
        case .walking:
            return .syncing(progress: progress)
        case .complete:
            return .complete
        case .halted:
            let date = haltedThrough.map { Date(timeIntervalSince1970: $0) } ?? Date(timeIntervalSince1970: 0)
            return .halted(syncedThrough: date)
        case .idle, .none:
            return .idle
        }
    }
}
