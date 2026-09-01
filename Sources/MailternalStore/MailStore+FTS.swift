import Foundation
import GRDB

extension MailStore {
    /// Full-text search over live-generation messages. Preview is an FTS snippet
    /// (spec: sync.md FTS). Empty or invalid queries yield no rows.
    ///
    /// Known 0.0.1 limitation: `unicode61` does not segment CJK, so CJK search is
    /// substring-poor until a later ICU-backed tokenizer.
    public func search(_ query: String, limit: Int) async throws -> [MessageRow] {
        let cap = max(0, limit)
        if cap == 0 { return [] }
        return try await read { db in
            guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
            let sql = """
                SELECT m.id, m.from_display, m.subject, m.internal_date, m.uid,
                       m.is_read, m.has_attachments, m.preview,
                       snippet(messages_fts, 3, '', '', '\u{2026}', 24) AS body_snippet,
                       snippet(messages_fts, 0, '', '', '\u{2026}', 16) AS subject_snippet
                FROM messages_fts
                JOIN messages m ON m.id = messages_fts.rowid
                JOIN generations g ON g.id = m.generation_id AND g.state = 'live'
                JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [pattern, cap])
            return rows.map { row in
                let bodySnippet: String? = row["body_snippet"]
                let subjectSnippet: String? = row["subject_snippet"]
                let stored: String? = row["preview"]
                let preview: String
                if let bodySnippet, !bodySnippet.isEmpty {
                    preview = bodySnippet
                } else if let subjectSnippet, !subjectSnippet.isEmpty {
                    preview = subjectSnippet
                } else {
                    preview = stored ?? ""
                }
                return MailStore.messageRow(from: row, preview: preview)
            }
        }
    }

    /// `EXPLAIN QUERY PLAN` for the FTS SELECT used by `search`.
    public func explainSearchQueryPlan(_ query: String, limit: Int) async throws -> String {
        let cap = max(0, limit)
        return try await read { db in
            guard cap > 0, let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return "" }
            let sql = """
                SELECT m.id
                FROM messages_fts
                JOIN messages m ON m.id = messages_fts.rowid
                JOIN generations g ON g.id = m.generation_id AND g.state = 'live'
                JOIN folders f ON f.id = g.folder_id AND f.retired = 0
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: [pattern, cap])
            return rows.map { row -> String in
                if let detail: String = row["detail"] { return detail }
                return row.map { "\($0.1)" }.joined(separator: " | ")
            }.joined(separator: "\n")
        }
    }

    /// `integrity-check` with rebuild-on-corruption (spec: sync.md FTS).
    public func checkFTSIntegrity() async throws -> FTSIntegrityResult {
        try await write { db in
            do {
                try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('integrity-check')")
                return .ok
            } catch {
                try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
                return .rebuilt
            }
        }
    }

    /// Rebuild hook used by migrations and corruption recovery.
    public func rebuildFTS() async throws {
        try await write { db in
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
        }
    }

    /// Segment merge/optimize, intended off the interactive path (spec: sync.md FTS).
    public func optimizeFTS() async throws {
        try await write { db in
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('optimize')")
        }
    }
}
