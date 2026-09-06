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

    /// Produces the same whitespace-normalized prefix as the previous
    /// split/join implementation, capped in extended grapheme clusters.
    static func make(from body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }

        // Stream normalized words until the bounded preview is complete. This
        // mirrors `split(whereSeparator: \.isWhitespace).joined(separator: " ")`
        // while avoiding allocation and traversal of an unneeded body suffix.
        var preview = ""
        preview.reserveCapacity(maxChars)
        var separatorPending = false

        for character in body {
            if character.isWhitespace {
                guard !preview.isEmpty else { continue }

                // A separator is only emitted when a following word exists.
                // Once it would fall beyond the cap, the existing prefix is
                // already stable and the remaining body cannot affect it.
                if preview.count >= maxChars {
                    var candidate = preview
                    candidate.append(" ")
                    if candidate.count > maxChars {
                        return preview
                    }
                }
                separatorPending = true
                continue
            }

            if separatorPending {
                preview.append(" ")
                separatorPending = false
                if preview.count > maxChars {
                    let end = preview.index(preview.startIndex, offsetBy: maxChars)
                    return String(preview[..<end])
                }
            }

            preview.append(character)
            if preview.count > maxChars {
                let end = preview.index(preview.startIndex, offsetBy: maxChars)
                return String(preview[..<end])
            }
        }

        return preview
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
