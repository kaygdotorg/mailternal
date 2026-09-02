import Foundation

enum UIIdentifier {
    static let mainWindow = "main-window"
    static let settingsWindow = "settings-window"
    static let sidebar = "folder-sidebar"
    static let messageTable = "message-table"
    static let messageListTitle = "message-list-title"
    static let messageListLines = "message-list-lines"
    static let messageViewer = "message-viewer"
    static let messageSubject = "message-subject"
    static let messageDetails = "message-details"
    static let messageBody = "message-body"
    static let searchPanel = "search-panel"
    static let searchField = "search-field"
    static let searchCoverage = "search-coverage"
    static let quarantineBanner = "quarantine-banner"
    static let toastStack = "toast-stack"
    static let toast = "toast"
    static let setupDisplayName = "setup-display-name"
    static let setupEmail = "setup-email"
    static let setupUsername = "setup-username"
    static let setupPassword = "setup-password"
    static let setupHost = "setup-host"
    static let setupPort = "setup-port"
    static let accountSave = "account-save"
    static let sidebarAccountTitle = "sidebar-account-title"
    static let emailReadingMode = "appearance-email-reading"
    static let actionsSection = "settings-actions"
    static let actionsSwipeLeading0 = "actions-swipe-leading-0"
    static let actionsSwipeLeading1 = "actions-swipe-leading-1"
    static let actionsSwipeTrailing0 = "actions-swipe-trailing-0"
    static let actionsSwipeTrailing1 = "actions-swipe-trailing-1"
    static let actionsSwipeTrailing2 = "actions-swipe-trailing-2"

    static func actionsSwipeLeading(_ index: Int) -> String {
        "actions-swipe-leading-\(index)"
    }

    static func actionsSwipeTrailing(_ index: Int) -> String {
        "actions-swipe-trailing-\(index)"
    }
    static func sidebarFolder(_ path: String) -> String {
        "sidebar-folder-\(path)"
    }
}




/// Geometry shared by the detail viewer and its focused layout tests.
///
/// The reader is one scrolling surface holding three floating islands. The
/// islands share the list pane's outer inset and are separated by a single
/// deliberate gap; their contents use the card's normal interior padding.
enum MessageViewerLayoutPolicy {
    /// Leading/trailing inset of every reader island, matching the message
    /// list's content inset.
    static let horizontalPadding: CGFloat = 16
    /// Vertical distance between the three independent islands.
    static let islandSpacing: CGFloat = 12
    /// Interior horizontal padding shared by the card-like islands.
    static let islandContentPadding: CGFloat = 18
    /// Interior vertical padding shared by the card-like islands.
    static let islandVerticalPadding: CGFloat = 16
    /// Clearance between the end of the viewer's top dissolve and the first
    /// subject glyph. The island itself begins one interior inset earlier so
    /// its material can softly enter the dissolve rather than clipping the
    /// title.
    static let fadeGuard: CGFloat = 12
    static let envelopeTopPadding: CGFloat = 12
    static let envelopeBottomPadding: CGFloat = 12
    static let envelopeRowSpacing: CGFloat = 8
    static let envelopePairSpacing: CGFloat = 6
    static let attachmentSpacing: CGFloat = 10
    static let bodyContentSpacing: CGFloat = 12
    static let bottomPadding: CGFloat = 40
    /// A just-loaded web view reports no useful document height yet. Keep a
    /// small page surface until the first real measurement arrives.
    static let htmlMinimumHeight: CGFloat = 80
    /// Comfortable reading measure for plain text. HTML is authored layout and
    /// keeps the whole pane; only plain text is measured.
    static let plainTextMeasureCharacters = 72

    /// Depth, below the physical window top, at which the reader's first
    /// readable glyph may rest: past the viewer dissolve's reach — or past a
    /// deeper measured titlebar — plus a guard. With no measured geometry this
    /// is the documented 52 + 12 fallback.
    static func readerTopInset(safeAreaTop: CGFloat) -> CGFloat {
        let fadeReach = MailWindowDissolvePolicy.viewer.restDepth(safeAreaTop: 0)
        return max(fadeReach, max(safeAreaTop, 0)) + fadeGuard
    }

    /// Height of the HTML page island from its document measurement. Invalid
    /// or transient zero measurements use the floor rather than creating a
    /// nested scrolling viewport or collapsing the card.
    static func htmlHeight(contentHeight: CGFloat) -> CGFloat {
        guard contentHeight.isFinite, contentHeight > 0 else {
            return htmlMinimumHeight
        }
        return contentHeight
    }
}

/// The native window values are kept in a platform-neutral seam for tests.
enum MainWindowLayoutPolicy {
    static let defaultContentSize = CGSize(width: 1_040, height: 720)
    static let minimumContentSize = CGSize(width: 760, height: 480)
    static let isResizable = true
}

/// The macOS 26 scroll-pocket capability is optional across OS builds.
enum ScrollEdgeEffectPolicy {
    static let allowedPocketEdgesKey = "allowedPocketEdges"
    static let allowedPocketEdgesSetter = "setAllowedPocketEdges:"
    static let suppressedPocketEdges = 0
}

struct MailWindowTopDissolveStop: Equatable, Sendable {
    let location: CGFloat
    let alpha: CGFloat
}

/// The ramp SHAPE every masked surface shares, plus the fallback depth of the
/// window's chrome band.
///
/// The eight segments are a smoothstep sampled at eighths: the slope leaves
/// zero and returns to zero, so no join in the perceptible band changes slope
/// by more than 1.33x and the ramp reads as a dissolve rather than a crease.
/// Surfaces reuse this curve and differ only in where the ramp starts and how
/// far it reaches.
enum MailWindowTopDissolvePolicy {
    /// Depth of the titlebar/traffic-light band. Used only as the documented
    /// fallback when a surface reports no measured top safe-area inset: a
    /// probe on macOS 26 measures 52pt while the window has toolbar items and
    /// 32pt when it has none, and the larger is the state with controls to
    /// protect.
    static let titlebarDepth: CGFloat = 52
    static let stops: [MailWindowTopDissolveStop] = [
        .init(location: 0, alpha: 0),
        .init(location: 1 / 8, alpha: 0.06),
        .init(location: 2 / 8, alpha: 0.18),
        .init(location: 3 / 8, alpha: 0.34),
        .init(location: 4 / 8, alpha: 0.52),
        .init(location: 5 / 8, alpha: 0.70),
        .init(location: 6 / 8, alpha: 0.85),
        .init(location: 7 / 8, alpha: 0.96),
        .init(location: 1, alpha: 1),
    ]

    /// Ramp alpha at a fraction of the ramp's own length.
    static func alpha(atFraction fraction: CGFloat) -> CGFloat {
        guard fraction > 0 else { return stops[0].alpha }
        guard fraction < 1 else { return stops[stops.count - 1].alpha }
        guard let upperIndex = stops.firstIndex(where: { $0.location >= fraction }) else {
            return stops[stops.count - 1].alpha
        }
        guard upperIndex > 0 else { return stops[upperIndex].alpha }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let span = upper.location - lower.location
        guard span > 0 else { return upper.alpha }
        return lower.alpha + (fraction - lower.location) / span * (upper.alpha - lower.alpha)
    }
}

/// One full-height mask policy per pane. Top-only surfaces end in opaque
/// content; scrolling list surfaces add a bottom ramp in the same mask.
struct MailWindowDissolvePolicy: Equatable, Sendable {
    /// Where a pane's top ramp starts, measured down from the physical window
    /// top.
    ///
    /// The panes differ here because their chrome differs, not because they
    /// draw with different code. Fixed chrome can use either the physical
    /// window top or measured titlebar safe area; scrolling surfaces can
    /// provide a measured origin for content-specific chrome.
    enum TopOrigin: Equatable, Sendable {
        /// The physical window top; the ramp crosses the chrome band.
        case windowTop
        /// The lower edge of the measured titlebar safe area.
        case titlebarSafeArea
        /// A measured chrome boundary, expressed in points below the
        /// physical window top.
        case measured(CGFloat)

        func depth(safeAreaTop: CGFloat) -> CGFloat {
            switch self {
            case .windowTop:
                0
            case .titlebarSafeArea:
                safeAreaTop > 0 ? safeAreaTop : MailWindowTopDissolvePolicy.titlebarDepth
            case .measured(let depth):
                max(depth, 0)
            }
        }
    }

    let topOrigin: TopOrigin
    let topReach: CGFloat
    let bottomReach: CGFloat?
    /// Space that belongs to fixed chrome outside the scrolling surface.
    /// FolderSidebar's account inset is outside its masked List, so this stays
    /// zero while the message list reaches the window bottom.
    let bottomReservedHeight: CGFloat

    static let viewer = Self(
        topOrigin: .windowTop,
        topReach: MailWindowTopDissolvePolicy.titlebarDepth,
        bottomReach: nil,
        bottomReservedHeight: 0
    )
    /// The traffic lights live in this column's band, so the ramp spends its
    /// ink in the open air below the safe area instead of behind them.
    static let sidebar = Self(
        topOrigin: .titlebarSafeArea,
        topReach: 32,
        bottomReach: 48,
        bottomReservedHeight: 0
    )
    static let messageList = Self(
        topOrigin: .windowTop,
        topReach: MailWindowTopDissolvePolicy.titlebarDepth,
        bottomReach: 48,
        bottomReservedHeight: 0
    )

    /// Returns a copy whose top ramp starts at a measured chrome boundary.
    /// The shared dissolve curve and reach remain unchanged.
    func withTopOrigin(_ depth: CGFloat) -> Self {
        Self(
            topOrigin: .measured(depth),
            topReach: topReach,
            bottomReach: bottomReach,
            bottomReservedHeight: bottomReservedHeight
        )
    }

    var hasBottomRamp: Bool { bottomReach != nil }

    /// The depth at which content is readable again. The mask's ramp and the
    /// surface's own top content inset both read this one number, so a row can
    /// never come to rest inside the ramp that erases it.
    func restDepth(safeAreaTop: CGFloat) -> CGFloat {
        topOrigin.depth(safeAreaTop: safeAreaTop) + max(topReach, 0)
    }

    /// Mask alpha at a depth below the physical window top.
    func alpha(atDepth depth: CGFloat, safeAreaTop: CGFloat) -> CGFloat {
        let origin = topOrigin.depth(safeAreaTop: safeAreaTop)
        let reach = max(topReach, 0)
        guard depth > origin else { return 0 }
        guard reach > 0 else { return 1 }
        return MailWindowTopDissolvePolicy.alpha(atFraction: min((depth - origin) / reach, 1))
    }

    func stops(for rawHeight: CGFloat, safeAreaTop: CGFloat) -> [MailWindowTopDissolveStop] {
        let height = max(rawHeight, 1)
        let topStart = min(max(topOrigin.depth(safeAreaTop: safeAreaTop), 0), height)
        let topEnd = min(topStart + max(topReach, 0), height)
        // A ramp that starts below the chrome holds the mask clear through the
        // whole band above it, so no ink lands behind the window buttons.
        var stops: [MailWindowTopDissolveStop] = topStart > 0
            ? [.init(location: 0, alpha: 0)]
            : []
        stops += MailWindowTopDissolvePolicy.stops.map { stop in
            MailWindowTopDissolveStop(
                location: min((topStart + stop.location * (topEnd - topStart)) / height, 1),
                alpha: stop.alpha
            )
        }
        guard let bottomReach, bottomReach > 0 else {
            if topEnd < height {
                stops.append(MailWindowTopDissolveStop(location: 1, alpha: 1))
            }
            return stops
        }

        let reserved = min(max(bottomReservedHeight, 0), height)
        let bottomEnd = max(topEnd, min(height - reserved, height))
        let reach = min(bottomReach, max(bottomEnd - topEnd, 0))
        guard reach > 0 else {
            if stops.last?.location != 1 {
                stops.append(MailWindowTopDissolveStop(location: 1, alpha: 1))
            }
            return stops
        }

        func location(_ distanceFromEnd: CGFloat) -> CGFloat {
            (bottomEnd - distanceFromEnd) / height
        }
        stops.append(MailWindowTopDissolveStop(location: location(reach), alpha: 1))
        stops.append(MailWindowTopDissolveStop(location: location(min(reach, 36)), alpha: 0.55))
        stops.append(MailWindowTopDissolveStop(location: location(min(reach, 24)), alpha: 0.12))
        stops.append(MailWindowTopDissolveStop(location: location(min(reach, 15)), alpha: 0))
        stops.append(MailWindowTopDissolveStop(location: bottomEnd / height, alpha: 0))
        if bottomEnd < height {
            stops.append(MailWindowTopDissolveStop(location: 1, alpha: 1))
        }
        return stops
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

struct MessageListFieldVisibility: Equatable, Sendable {
    let sender: Bool
    let date: Bool
    let preview: Bool
}

enum MessageListLayout {
    static let lineRange = 1...6
    static let defaultLineCount = 3
    static let rowBaseHeight: CGFloat = 36
    static let rowHeightPerLine: CGFloat = 18

    static func normalizedLineCount(_ value: Int) -> Int {
        min(max(value, lineRange.lowerBound), lineRange.upperBound)
    }

    static func fieldVisibility(for lineCount: Int) -> MessageListFieldVisibility {
        let lines = normalizedLineCount(lineCount)
        return MessageListFieldVisibility(
            sender: lines >= 2,
            date: lines >= 2,
            preview: lines >= 3
        )
    }

    static func previewLineCount(for lineCount: Int) -> Int {
        max(0, normalizedLineCount(lineCount) - 2)
    }

    static func rowHeight(for lineCount: Int) -> CGFloat {
        rowBaseHeight + CGFloat(normalizedLineCount(lineCount) - 1) * rowHeightPerLine
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

    /// Matches the viewer surface: raw pane, HTML body, then plain text.
    static func haystack(
        bodyText: String?,
        html: String?,
        raw: String?,
        showingRaw: Bool
    ) -> String {
        if showingRaw, let raw {
            return raw
        }
        if let html, !html.isEmpty {
            return visibleText(fromHTML: html)
        }
        return bodyText ?? ""
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
