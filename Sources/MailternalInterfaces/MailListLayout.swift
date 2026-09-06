import Foundation

/// The columns available in the dense message-list presentation.
public enum MailListColumn: String, Codable, CaseIterable, Hashable, Sendable {
    case read
    case flagged
    case attachments
    case sender
    case subject
    case date
}
/// The two supported message-list presentations.
public enum MailListPresentation: String, Codable, CaseIterable, Hashable, Sendable {
    case cards
    case columns
}

/// The placement of the reader relative to the message list.
public enum MailPaneLayout: String, Codable, CaseIterable, Hashable, Sendable {
    case sideBySide
    case listAboveReader
}

/// The scope at which a list customization applies.
///
/// Folder paths are the complete server path and intentionally accompany the
/// stable cross-device `AccountLinkID`; local `FolderID` values never enter a
/// workspace key.
public enum MailListScope: Hashable, Sendable {
    case global
    case folder(account: AccountLinkID, path: String)
}

/// Effective message-list customization after global defaults and an optional
/// folder override have been resolved.
public struct MailListConfiguration: Codable, Hashable, Sendable {
    public var presentation: MailListPresentation
    public var paneLayout: MailPaneLayout
    public var columnOrder: [MailListColumn]
    public var hiddenColumns: Set<MailListColumn>
    public var columnWidths: [MailListColumn: Double]
    public var sort: MailListSort

    /// The initial configuration preserves Mailternal's existing layout.
    public static let `default` = MailListConfiguration(
        presentation: .cards,
        paneLayout: .sideBySide,
        columnOrder: MailListColumn.allCases,
        hiddenColumns: [],
        columnWidths: [:],
        sort: .newest
    )

    /// Alias used by settings surfaces when referring to the built-in values.
    public static let defaults = MailListConfiguration.default

    public init(
        presentation: MailListPresentation = .cards,
        paneLayout: MailPaneLayout = .sideBySide,
        columnOrder: [MailListColumn] = MailListColumn.allCases,
        hiddenColumns: Set<MailListColumn> = [],
        columnWidths: [MailListColumn: Double] = [:],
        sort: MailListSort = .newest
    ) {
        self.presentation = presentation
        self.paneLayout = paneLayout
        self.columnOrder = columnOrder
        self.hiddenColumns = hiddenColumns
        self.columnWidths = columnWidths
        self.sort = sort
    }
}
