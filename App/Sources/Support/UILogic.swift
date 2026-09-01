import Foundation

enum UIIdentifier {
    static let mainWindow = "main-window"
    static let settingsWindow = "settings-window"
    static let sidebar = "folder-sidebar"
    static let messageTable = "message-table"
    static let messageViewer = "message-viewer"
    static let searchPanel = "search-panel"
    static let searchField = "search-field"
    static let windowedBanner = "windowed-mode-banner"
    static let quarantineBanner = "quarantine-banner"
    static let toastStack = "toast-stack"
    static let toast = "toast"
    static let unreadDot = "message-unread-dot"
    static let setupDisplayName = "setup-display-name"
    static let setupEmail = "setup-email"
    static let setupUsername = "setup-username"
    static let setupPassword = "setup-password"
    static let setupHost = "setup-host"
    static let setupPort = "setup-port"

    static func sidebarFolder(_ path: String) -> String {
        "sidebar-folder-\(path)"
    }
}

enum MailDateFormat {
    private static let time: Date.FormatStyle = .dateTime.hour().minute()
    private static let absolute: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()
    private static let weekday: Date.FormatStyle = .dateTime.weekday(.wide)

    static func listRow(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.relative(presentation: .named, unitsStyle: .narrow))
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           date >= weekAgo {
            return date.formatted(weekday)
        }
        return date.formatted(absolute)
    }

    static func envelope(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
    }

    static func syncedThrough(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

enum MessageListPrefetch: Sendable {
    static let pageSize = 80
    static let margin = 24

    static func shouldLoadMore(
        near row: Int,
        loadedCount: Int,
        hasMore: Bool,
        isPaging: Bool
    ) -> Bool {
        guard !isPaging, hasMore else { return false }
        return row >= loadedCount - margin
    }
}

enum SearchQueryPolicy: Sendable {
    static let debounce: Duration = .milliseconds(120)

    static func normalizedQuery(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// In-message find: match ranges, wrap-around index, and the text the bar searches.
enum MessageFind: Sendable {
    enum Step: Sendable {
        case next
        case previous
    }

    struct Snapshot: Equatable, Sendable {
        var query: String
        var ranges: [Range<String.Index>]
        /// 0-based. `nil` when there are no matches.
        var index: Int?

        var count: Int { ranges.count }

        var selectedMatchNumber: Int? {
            guard let index, count > 0 else { return nil }
            return index + 1
        }

        var selectedRange: Range<String.Index>? {
            guard let index, ranges.indices.contains(index) else { return nil }
            return ranges[index]
        }
    }

    /// Case-insensitive, non-overlapping ranges in `text`. Empty query → no matches.
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var search = text.startIndex
        while let found = text.range(of: query, options: [.caseInsensitive], range: search..<text.endIndex) {
            result.append(found)
            search = found.upperBound
        }
        return result
    }

    static func make(text: String, query: String, index: Int?) -> Snapshot {
        let ranges = ranges(in: text, query: query)
        return Snapshot(query: query, ranges: ranges, index: clamp(index, count: ranges.count))
    }

    /// First match after the query (or haystack) changes.
    static func restartIndex(count: Int) -> Int? {
        count > 0 ? 0 : nil
    }

    /// Wrap-around next/previous. `nil` index starts at first (next) or last (previous).
    static func advance(index: Int?, count: Int, step: Step) -> Int? {
        guard count > 0 else { return nil }
        switch step {
        case .next:
            guard let index else { return 0 }
            return (clamp(index, count: count)! + 1) % count
        case .previous:
            guard let index else { return count - 1 }
            return (clamp(index, count: count)! - 1 + count) % count
        }
    }

    /// Body text wins; raw source when that pane is showing; otherwise tag-stripped HTML.
    static func haystack(
        bodyText: String?,
        html: String?,
        raw: String?,
        showingRaw: Bool
    ) -> String {
        if showingRaw, let raw {
            return raw
        }
        if let bodyText, !bodyText.isEmpty {
            return bodyText
        }
        if let html, !html.isEmpty {
            return visibleText(fromHTML: html)
        }
        return ""
    }

    static func visibleText(fromHTML html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var inTag = false
        for character in html {
            if character == "<" {
                inTag = true
                continue
            }
            if character == ">" {
                inTag = false
                continue
            }
            if !inTag {
                result.append(character)
            }
        }
        return result
    }

    /// Out-of-range indexes clamp (query changed / fewer hits). Wrap is only `advance`.
    static func clamp(_ index: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        if index < 0 { return 0 }
        if index >= count { return count - 1 }
        return index
    }
}
