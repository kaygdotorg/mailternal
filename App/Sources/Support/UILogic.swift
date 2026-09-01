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
