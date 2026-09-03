import Foundation

/// The on-disk representation of reader tabs. Message bodies are deliberately
/// absent: a tab stores only its durable deep link and view state.
struct ReaderTabsSnapshot: Codable, Equatable {
    struct Entry: Codable, Hashable {
        let id: UUID
        let link: String
        let isTransient: Bool
        let scrollOffset: CGFloat

        init(id: UUID, link: String, isTransient: Bool, scrollOffset: CGFloat = 0) {
            self.id = id
            self.link = link
            self.isTransient = isTransient
            self.scrollOffset = scrollOffset
        }
    }

    var tabs: [Entry]
    var activeID: UUID?
    var mruIDs: [UUID]

    init(tabs: [Entry] = [], activeID: UUID? = nil, mruIDs: [UUID] = []) {
        self.tabs = tabs
        self.activeID = activeID
        self.mruIDs = mruIDs
    }

    /// Compatibility spelling for callers that describe the field as order.
    var order: [UUID] { tabs.map(\.id) }

    /// Stable deep links in strip order.
    var links: [String] { tabs.map(\.link) }
}
