import Foundation
import MailternalInterfaces
import MailternalWorkspace
/// Wire-level constants shared by the app, CLI, and future headless runtime.
public enum AutomationProtocol: Sendable {
    public static let commandSchema = "mailternal.command.v1"
    public static let stateSchema = "mailternal.state.v1"
    public static let responseSchema = "mailternal.response.v1"
    public static let eventSchema = "mailternal.event.v1"
    public static let transferSchema = "mailternal.transfer.v1"
    public static let version = 1
    public static let maximumQueryLimit = 500
}

/// Transfer payloads are deliberately smaller than the NDJSON frame limit.
/// Data is base64 encoded by Codable, so keeping chunks at 256 KiB leaves
/// ample room for the response envelope and future metadata.
public enum AutomationTransferPolicy: Sendable {
    public static let chunkBytes = 256 * 1024
    public static let inlinePayloadBytes = 1 * 1024 * 1024
    public static let maximumBytes: UInt64 = 256 * 1024 * 1024
}
public enum AutomationTransferKind: String, Codable, Hashable, Sendable {
    case commandResult
    case attachment
}

public struct AutomationTransferDescriptor: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public let transferID: UUID
    public let kind: AutomationTransferKind
    public let size: UInt64
    public let chunkBytes: Int
    public let filename: String?
    public let contentType: String?

    public init(
        transferID: UUID = UUID(),
        kind: AutomationTransferKind,
        size: UInt64,
        filename: String? = nil,
        contentType: String? = nil
    ) {
        self.schema = AutomationProtocol.transferSchema
        self.version = AutomationProtocol.version
        self.transferID = transferID
        self.kind = kind
        self.size = size
        self.chunkBytes = AutomationTransferPolicy.chunkBytes
        self.filename = filename
        self.contentType = contentType
    }
}

public struct AutomationTransferChunk: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public let transferID: UUID
    public let sequence: UInt64
    public let offset: UInt64
    public let totalBytes: UInt64
    public let data: Data
    public let final: Bool

    public init(
        transferID: UUID,
        sequence: UInt64,
        offset: UInt64,
        totalBytes: UInt64,
        data: Data,
        final: Bool
    ) {
        self.schema = AutomationProtocol.transferSchema
        self.version = AutomationProtocol.version
        self.transferID = transferID
        self.sequence = sequence
        self.offset = offset
        self.totalBytes = totalBytes
        self.data = data
        self.final = final
    }
}

public enum CommandOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case app
    case localCLI = "local-cli"
    case pairedRemote = "paired-remote"
    case iOS
    case watch
}

/// Independent capabilities granted to a paired client. A client never gets
/// GUI control merely because it can reach the listener.
public struct AutomationGrant: Codable, Equatable, Hashable, Sendable {
    public var accountLinkIDs: Set<AccountLinkID>
    public var canRead: Bool
    public var canMutate: Bool
    public var canSend: Bool
    public var canControlGUI: Bool

    public init(
        accountLinkIDs: Set<AccountLinkID> = [],
        canRead: Bool = false,
        canMutate: Bool = false,
        canSend: Bool = false,
        canControlGUI: Bool = false
    ) {
        self.accountLinkIDs = accountLinkIDs
        self.canRead = canRead
        self.canMutate = canMutate
        self.canSend = canSend
        self.canControlGUI = canControlGUI
    }

    public static let local = AutomationGrant(
        canRead: true,
        canMutate: true,
        canSend: true,
        canControlGUI: true
    )
}
/// Trusted metadata attached by the authenticated IPC transport. It is not
/// decoded from an `AutomationRequest`, because wire clients must not be able
/// to self-escalate by choosing a local origin or grant.
public struct AutomationClientContext: Sendable, Equatable {
    public let origin: CommandOrigin
    public let grant: AutomationGrant
    public let clientID: UUID?

    public init(origin: CommandOrigin, grant: AutomationGrant, clientID: UUID? = nil) {
        self.origin = origin
        self.grant = grant
        self.clientID = clientID
    }
}

public enum AutomationAccess: String, Codable, CaseIterable, Hashable, Sendable {
    case read
    case mutate
    case send
    case gui
}

public enum MessageTarget: Codable, Equatable, Hashable, Sendable {
    case explicit([MessageID])
    case links([MailternalDeepLink])
    case selection(SelectionContext)

    public var explicitIDs: [MessageID]? {
        if case .explicit(let ids) = self { return ids }
        return nil
    }

    public var deepLinks: [MailternalDeepLink]? {
        if case .links(let links) = self { return links }
        return nil
    }

    public var selectionContext: SelectionContext? {
        if case .selection(let context) = self { return context }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, ids, links, context }
    private enum Kind: String, Codable { case explicit, links, selection }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .explicit(let ids):
            try container.encode(Kind.explicit, forKey: .kind)
            try container.encode(ids, forKey: .ids)
        case .links(let links):
            try container.encode(Kind.links, forKey: .kind)
            try container.encode(links, forKey: .links)
        case .selection(let context):
            try container.encode(Kind.selection, forKey: .kind)
            try container.encode(context, forKey: .context)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .explicit:
            self = .explicit(try container.decode([MessageID].self, forKey: .ids))
        case .links:
            self = .links(try container.decode([MailternalDeepLink].self, forKey: .links))
        case .selection:
            self = .selection(try container.decode(SelectionContext.self, forKey: .context))
        }
    }
}
public enum MessageReference: Codable, Equatable, Hashable, Sendable {
    case local(MessageID)
    case link(MailternalDeepLink)

    private enum CodingKeys: String, CodingKey { case kind, id, link }
    private enum Kind: String, Codable { case local, link }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let id):
            try container.encode(Kind.local, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .link(let link):
            try container.encode(Kind.link, forKey: .kind)
            try container.encode(link, forKey: .link)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local: self = .local(try container.decode(MessageID.self, forKey: .id))
        case .link: self = .link(try container.decode(MailternalDeepLink.self, forKey: .link))
        }
    }
}
public enum DraftAttachmentSource: Codable, Equatable, Hashable, Sendable {
    /// Only trusted in-process callers may provide a private local URL. Wire
    /// callers must upload bounded bytes and use `transfer`.
    case localFile(URL)
    case transfer(UUID)

    private enum CodingKeys: String, CodingKey { case kind, url, transferID }
    private enum Kind: String, Codable { case localFile, transfer }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localFile(let url):
            try container.encode(Kind.localFile, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .transfer(let id):
            try container.encode(Kind.transfer, forKey: .kind)
            try container.encode(id, forKey: .transferID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .localFile:
            self = .localFile(try container.decode(URL.self, forKey: .url))
        case .transfer:
            self = .transfer(try container.decode(UUID.self, forKey: .transferID))
        }
    }
}


public struct SelectionContext: Codable, Equatable, Hashable, Sendable {
    public var revision: UInt64
    public var folderID: FolderID?
    public var messageIDs: [MessageID]

    public init(revision: UInt64, folderID: FolderID?, messageIDs: [MessageID] = []) {
        self.revision = revision
        self.folderID = folderID
        self.messageIDs = messageIDs
    }
}

public enum CommandName: String, Codable, CaseIterable, Hashable, Sendable {
    case saveAccount = "account.save"
    case removeAccount = "account.remove"
    case setAccountEnabled = "account.set-enabled"
    case exportAccounts = "account.export"
    case importAccounts = "account.import"
    case renameAccount = "account.rename"
    case selectFolder = "folder.select"
    case renameFolder = "folder.rename"
    case setRetention = "folder.set-retention"
    case list = "mail.list"
    case read = "mail.read"
    case raw = "mail.raw"
    case fetchAttachment = "mail.fetch-attachment"
    case search = "mail.search"
    case markRead = "mail.mark-read"
    case markUnread = "mail.mark-unread"
    case setFlagged = "mail.set-flagged"
    case archive = "mail.archive"
    case trash = "mail.trash"
    case move = "mail.move"
    case selectMessages = "selection.set"
    case selectAll = "selection.all"
    case clearSelection = "selection.clear"
    case refresh = "mail.refresh"
    case undo = "mail.undo"
    case openMessage = "ui.open-message"
    case openSearchResult = "ui.search.open"
    case openWindow = "ui.open-window"
    case activateTab = "ui.tab.activate"
    case closeTab = "ui.tab.close"
    case closeOthers = "ui.tab.close-others"
    case closeToRight = "ui.tab.close-to-right"
    case keepTab = "ui.tab.keep"
    case moveTab = "ui.tab.move"
    case nextTab = "ui.tab.next"
    case previousTab = "ui.tab.previous"
    case toggleSearch = "ui.search.toggle"
    case toggleFind = "ui.find.toggle"
    case setFindQuery = "ui.find.query"
    case setFindPresented = "ui.find.presented"
    case toggleSidebar = "ui.sidebar.toggle"
    case showSettings = "ui.settings.show"
    case toggleRawSource = "ui.raw.toggle"
    case setReadingMode = "ui.reading-mode.set"
    case setRemoteImages = "ui.remote-images.set"
    case setListCustomizationTarget = "ui.list.target"
    case setListPaneLayout = "ui.list.pane-layout"
    case setListPresentation = "ui.list.presentation"
    case setListColumnOrder = "ui.list.column-order"
    case setListColumnVisible = "ui.list.column-visible"
    case setListColumnWidth = "ui.list.column-width"
    case setListSort = "ui.list.sort"
    case resetListSettings = "ui.list.reset"
    case resetGlobalListSettings = "ui.list.reset-global"
    case setWorkspaceSync = "settings.workspace-sync"
    case setWorkspaceSyncCategory = "ui.workspace-sync.category"
    case resolveWorkspaceSyncConflict = "ui.workspace-sync.resolve"
    case getSetting = "settings.get"
    case setSetting = "settings.set"
    case configureRemote = "automation.remote.configure"
    case revokeAutomationClient = "automation.client.revoke"
    case setSearchQuery = "ui.search.query"
    case selectSearchResult = "ui.search.select"
    case setSearchFieldFocused = "ui.search.focus"
    case cancelSearch = "ui.search.cancel"
    case setPairingPresented = "ui.pairing.present"
    case pairingUI = "ui.pairing.action"
    case getSettings = "settings.list"
    case configureSMTP = "account.smtp.configure"
    case createDraft = "draft.create"
    case createReplyDraft = "draft.reply"
    case createForwardDraft = "draft.forward"
    case saveDraft = "draft.save"
    case deleteDraft = "draft.delete"
    case getDraft = "draft.get"
    case listDrafts = "draft.list"
    case importDraftAttachment = "draft.attachment.import"
    case getDraftAttachment = "draft.attachment.get"
    case sendDraft = "draft.send"
    case retrySubmission = "outbox.retry"
    case cancelSubmission = "outbox.cancel"
    case getSubmission = "outbox.get"
    case listOutbox = "outbox.list"
}

public enum AutomationReadingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case original
    case dark
}
public enum MailListCustomizationTargetValue: String, Codable, CaseIterable, Hashable, Sendable {
    case currentFolder
    case global
}

public enum Command: Codable, Equatable, Hashable, Sendable {
    case saveAccount(AccountConfig, hasPassword: Bool)
    case removeAccount(AccountID)
    case setAccountEnabled(AccountID, Bool)
    case exportAccounts([AccountID], includeSettings: Bool)
    case importAccounts(Data, selectedIDs: [AccountID], replaceExisting: Bool, importSettings: Bool)
    case renameAccount(AccountID, String)
    case selectFolder(FolderID?)
    case renameFolder(FolderID, String)
    case setRetention(FolderID, Bool)
    case list(FolderID?, MessagePageCursor?, Int, MailListSort)
    case read(MessageReference)
    case raw(MessageReference)
    case fetchAttachment(MessageReference, String)
    case search(String, Int)
    case markRead(MessageTarget)
    case move(MessageTarget, FolderID)
    case markUnread(MessageTarget)
    case setFlagged(MessageTarget, Bool)
    case archive(MessageTarget)
    case trash(MessageTarget)
    case selectMessages(MessageTarget, anchor: MessageReference?)
    case selectAll
    case clearSelection
    case refresh
    case undo
    case openMessage(MessageReference, permanent: Bool)
    case openSearchResult(MessageReference)
    case openWindow(MessageReference)
    case activateTab(UUID)
    case closeTab(UUID)
    case closeOthers(UUID)
    case closeToRight(UUID)
    case keepTab(UUID)
    case moveTab(UUID, Int)
    case nextTab
    case previousTab
    case toggleSearch
    case toggleFind
    case setFindQuery(String)
    case setFindPresented(Bool)
    case toggleSidebar
    case showSettings
    case toggleRawSource
    case setReadingMode(AutomationReadingMode)
    case setRemoteImages(Bool)
    case setListCustomizationTarget(MailListCustomizationTargetValue)
    case setListPaneLayout(MailPaneLayout)
    case setListPresentation(MailListPresentation)
    case setListColumnOrder([MailListColumn])
    case setListColumnVisible(MailListColumn, Bool)
    case setListColumnWidth(MailListColumn, Double)
    case setListSort(MailListSort)
    case resetListSettings
    case resetGlobalListSettings
    case setWorkspaceSync(Bool)
    case setWorkspaceSyncCategory(WorkspaceSyncCategory, Bool)
    case resolveWorkspaceSyncConflict(WorkspaceSyncCategory, WorkspaceSyncChoice)
    case getSetting(String)
    case setSetting(String, String?)
    case configureRemote(AutomationRemoteConfiguration)
    case revokeAutomationClient(UUID)
    case setSearchQuery(String)
    case selectSearchResult(MessageReference?)
    case setSearchFieldFocused(Bool)
    case cancelSearch
    case setPairingPresented(Bool)
    case pairingUI(PairingUIAction)
    case getSettings
    case configureSMTP(AccountID, SMTPConfiguration?, hasPassword: Bool)
    case createDraft(id: UUID, accountID: AccountID, content: DraftContent)
    case createReplyDraft(id: UUID, MessageReference, replyAll: Bool)
    case createForwardDraft(id: UUID, MessageReference)
    case saveDraft(id: UUID, expectedRevision: Int64, content: DraftContent)
    case deleteDraft(id: UUID, expectedRevision: Int64)
    case getDraft(UUID)
    case listDrafts(AccountID?, Int)
    case importDraftAttachment(id: UUID, account: AccountID, source: DraftAttachmentSource, filename: String, mimeType: String)
    case getDraftAttachment(account: AccountID, id: UUID)
    case sendDraft(id: UUID, draftID: UUID, expectedRevision: Int64)
    case retrySubmission(UUID, acknowledgeDuplicateRisk: Bool)
    case cancelSubmission(UUID)
    case getSubmission(UUID)
    case listOutbox(AccountID?, Int)

    public var name: CommandName {
        switch self {
        case .saveAccount: .saveAccount
        case .removeAccount: .removeAccount
        case .setAccountEnabled: .setAccountEnabled
        case .exportAccounts: .exportAccounts
        case .importAccounts: .importAccounts
        case .renameAccount: .renameAccount
        case .selectFolder: .selectFolder
        case .renameFolder: .renameFolder
        case .setRetention: .setRetention
        case .list: .list
        case .read: .read
        case .raw: .raw
        case .fetchAttachment: .fetchAttachment
        case .search: .search
        case .markRead: .markRead
        case .markUnread: .markUnread
        case .setFlagged: .setFlagged
        case .archive: .archive
        case .trash: .trash
        case .move: .move
        case .selectMessages: .selectMessages
        case .selectAll: .selectAll
        case .clearSelection: .clearSelection
        case .refresh: .refresh
        case .undo: .undo
        case .openMessage: .openMessage
        case .openSearchResult: .openSearchResult
        case .openWindow: .openWindow
        case .activateTab: .activateTab
        case .closeTab: .closeTab
        case .closeOthers: .closeOthers
        case .closeToRight: .closeToRight
        case .keepTab: .keepTab
        case .moveTab: .moveTab
        case .nextTab: .nextTab
        case .previousTab: .previousTab
        case .toggleSearch: .toggleSearch
        case .toggleFind: .toggleFind
        case .setFindQuery: .setFindQuery
        case .configureSMTP: .configureSMTP
        case .createDraft: .createDraft
        case .createReplyDraft: .createReplyDraft
        case .createForwardDraft: .createForwardDraft
        case .saveDraft: .saveDraft
        case .deleteDraft: .deleteDraft
        case .getDraft: .getDraft
        case .listDrafts: .listDrafts
        case .importDraftAttachment: .importDraftAttachment
        case .getDraftAttachment: .getDraftAttachment
        case .sendDraft: .sendDraft
        case .retrySubmission: .retrySubmission
        case .cancelSubmission: .cancelSubmission
        case .getSubmission: .getSubmission
        case .listOutbox: .listOutbox
        case .setFindPresented: .setFindPresented
        case .toggleSidebar: .toggleSidebar
        case .showSettings: .showSettings
        case .toggleRawSource: .toggleRawSource
        case .setReadingMode: .setReadingMode
        case .setRemoteImages: .setRemoteImages
        case .setListCustomizationTarget: .setListCustomizationTarget
        case .setListPaneLayout: .setListPaneLayout
        case .setListPresentation: .setListPresentation
        case .setListColumnOrder: .setListColumnOrder
        case .setListColumnVisible: .setListColumnVisible
        case .setListColumnWidth: .setListColumnWidth
        case .setListSort: .setListSort
        case .resetListSettings: .resetListSettings
        case .resetGlobalListSettings: .resetGlobalListSettings
        case .setWorkspaceSync: .setWorkspaceSync
        case .setWorkspaceSyncCategory: .setWorkspaceSyncCategory
        case .resolveWorkspaceSyncConflict: .resolveWorkspaceSyncConflict
        case .getSetting: .getSetting
        case .setSetting: .setSetting
        case .configureRemote: .configureRemote
        case .revokeAutomationClient: .revokeAutomationClient
        case .setSearchQuery: .setSearchQuery
        case .selectSearchResult: .selectSearchResult
        case .setSearchFieldFocused: .setSearchFieldFocused
        case .cancelSearch: .cancelSearch
        case .setPairingPresented: .setPairingPresented
        case .pairingUI: .pairingUI
        case .getSettings: .getSettings
    }
    }

    public var access: AutomationAccess {
        switch self {
        case .read, .raw, .fetchAttachment, .list, .search, .getSetting, .getSettings,
             .getDraft, .listDrafts, .getDraftAttachment, .getSubmission, .listOutbox:
            .read
        case .sendDraft, .retrySubmission, .cancelSubmission:
            .send
        case .saveAccount, .removeAccount, .setAccountEnabled, .exportAccounts, .importAccounts, .renameAccount,
             .renameFolder, .setRetention, .markRead, .markUnread, .setFlagged, .archive, .trash, .move,
             .refresh, .undo, .setSetting, .configureRemote, .revokeAutomationClient,
             .configureSMTP, .createDraft, .createReplyDraft, .createForwardDraft, .saveDraft,
             .deleteDraft, .importDraftAttachment:
            .mutate
        case .selectFolder, .selectMessages, .selectAll, .clearSelection,
             .openMessage, .openSearchResult, .openWindow, .activateTab, .closeTab, .closeOthers,
             .closeToRight, .keepTab, .moveTab, .nextTab, .previousTab,
             .toggleSearch, .toggleFind, .setFindQuery, .setFindPresented, .setSearchQuery, .selectSearchResult,
             .setSearchFieldFocused, .cancelSearch, .setPairingPresented, .pairingUI,
             .toggleSidebar, .showSettings,
             .toggleRawSource, .setReadingMode, .setRemoteImages,
             .setListCustomizationTarget, .setListPaneLayout, .setListPresentation,
             .setListColumnOrder, .setListColumnVisible, .setListColumnWidth,
             .setListSort, .resetListSettings, .resetGlobalListSettings, .setWorkspaceSync,
             .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict:
            .gui
        }
    }

    public var isCredentialTransfer: Bool {
        switch self {
        case .saveAccount, .exportAccounts, .importAccounts, .configureSMTP:
            return true
        case .pairingUI(let action):
            return action.isCredentialTransfer
        default:
            return false
        }
    }

    public var requiresGUI: Bool {
        switch self {
        case .selectFolder, .selectMessages, .selectAll, .clearSelection,
             .openMessage, .openSearchResult, .openWindow, .activateTab, .closeTab, .closeOthers,
             .closeToRight, .keepTab, .moveTab, .nextTab, .previousTab,
             .toggleSearch, .toggleFind, .setFindQuery, .setFindPresented, .setSearchQuery,
             .selectSearchResult, .setSearchFieldFocused, .cancelSearch,
             .setPairingPresented, .pairingUI, .toggleSidebar, .showSettings,
             .toggleRawSource, .setReadingMode, .setRemoteImages,
             .setListCustomizationTarget, .setListPaneLayout, .setListPresentation,
             .setListColumnOrder, .setListColumnVisible, .setListColumnWidth,
             .setListSort, .resetListSettings, .resetGlobalListSettings, .setWorkspaceSync,
             .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict:
            return true
        default:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey { case name, payload }
    private struct Payload: Codable {
        var values: [AnyCodable]
        init(_ values: [AnyCodable] = []) { self.values = values }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(AnyCodable.payload(for: self), forKey: .payload)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(CommandName.self, forKey: .name)
        let payload = try container.decode([AnyCodable].self, forKey: .payload)
        self = try AnyCodable.command(name: name, payload: payload)
    }
}

/// Values carried by command payloads. It is intentionally private in spirit,
/// but public so Codable can decode a command without a second schema.
public enum AnyCodable: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case uuid(UUID)
    case accountID(AccountID)
    case folderID(FolderID)
    case messageID(MessageID)
    case data(Data)
    case commandJSON(Data)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(Data.self) { self = .data(value); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported automation payload"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .uuid(let value): try container.encode(value.uuidString.lowercased())
        case .accountID(let value): try container.encode(value.rawValue)
        case .folderID(let value): try container.encode(value.rawValue)
        case .messageID(let value): try container.encode(value.rawValue)
        case .data(let value), .commandJSON(let value): try container.encode(value.base64EncodedString())
        case .null: try container.encodeNil()
        }
    }

    static func payload(for command: Command) -> [AnyCodable] {
        switch command {
        case .saveAccount(let config, let hasPassword): return [.commandJSON(encode(config)), .bool(hasPassword)]
        case .removeAccount(let id): return [.accountID(id)]
        case .setAccountEnabled(let id, let enabled): return [.accountID(id), .bool(enabled)]
        case .exportAccounts(let ids, let includeSettings): return [.commandJSON(encode(ids)), .bool(includeSettings)]
        case .importAccounts(let data, let ids, let replaceExisting, let importSettings):
            return [.data(data), .commandJSON(encode(ids)), .bool(replaceExisting), .bool(importSettings)]
        case .renameAccount(let id, let value): return [.accountID(id), .string(value)]
        case .selectFolder(let id): return id.map { [.folderID($0)] } ?? [.null]
        case .renameFolder(let id, let value): return [.folderID(id), .string(value)]
        case .setRetention(let id, let value): return [.folderID(id), .bool(value)]
        case .list(let folder, let cursor, let limit, let sort): return [folder.map(AnyCodable.folderID) ?? .null, cursor.map { .commandJSON(encode($0)) } ?? .null, .integer(limit), .commandJSON(encode(sort))]
        case .read(let reference), .raw(let reference), .openWindow(let reference):
            return [.commandJSON(encode(reference))]
        case .fetchAttachment(let reference, let part): return [.commandJSON(encode(reference)), .string(part)]
        case .search(let query, let limit): return [.string(query), .integer(limit)]
        case .markRead(let target), .markUnread(let target), .archive(let target), .trash(let target): return [.commandJSON(encode(target))]
        case .setFlagged(let target, let value): return [.commandJSON(encode(target)), .bool(value)]
        case .move(let target, let folder): return [.commandJSON(encode(target)), .folderID(folder)]
        case .selectMessages(let target, let anchor):
            return [
                .commandJSON(encode(target)),
                anchor.map { .commandJSON(encode($0)) } ?? .null
            ]
        case .selectAll, .clearSelection, .refresh, .undo, .nextTab, .previousTab,
             .toggleSearch, .toggleFind, .toggleSidebar, .showSettings,
             .toggleRawSource, .resetListSettings, .resetGlobalListSettings, .cancelSearch, .getSettings:
            return []
        case .openMessage(let reference, let permanent):
            return [.commandJSON(encode(reference)), .bool(permanent)]
        case .openSearchResult(let reference):
            return [.commandJSON(encode(reference))]
        case .activateTab(let id), .closeTab(let id), .closeOthers(let id),
             .closeToRight(let id), .keepTab(let id):
            return [.uuid(id)]
        case .moveTab(let id, let index):
            return [.uuid(id), .integer(index)]
        case .setFindQuery(let query), .setSearchQuery(let query): return [.string(query)]
        case .setFindPresented(let presented): return [.bool(presented)]
        case .selectSearchResult(let reference):
            return [reference.map { .commandJSON(encode($0)) } ?? .null]
        case .setSearchFieldFocused(let focused): return [.bool(focused)]
        case .setPairingPresented(let presented): return [.bool(presented)]
        case .pairingUI(let action): return [.commandJSON(encode(action))]
        case .setReadingMode(let mode): return [.string(mode.rawValue)]
        case .setRemoteImages(let value): return [.bool(value)]
        case .setListCustomizationTarget(let value): return [.string(value.rawValue)]
        case .setListPaneLayout(let value): return [.string(value.rawValue)]
        case .setListPresentation(let value): return [.string(value.rawValue)]
        case .setListColumnOrder(let values): return [.commandJSON(encode(values))]
        case .setListColumnVisible(let column, let visible): return [.string(column.rawValue), .bool(visible)]
        case .setListColumnWidth(let column, let width): return [.string(column.rawValue), .double(width)]
        case .setListSort(let sort): return [.commandJSON(encode(sort))]
        case .setWorkspaceSync(let enabled): return [.bool(enabled)]
        case .setWorkspaceSyncCategory(let category, let enabled):
            return [.string(category.rawValue), .bool(enabled)]
        case .resolveWorkspaceSyncConflict(let category, let choice):
            return [.string(category.rawValue), .string(choice.rawValue)]
        case .getSetting(let key): return [.string(key)]
        case .setSetting(let key, let value): return [.string(key), value.map(AnyCodable.string) ?? .null]
        case .configureSMTP(let accountID, let configuration, let hasPassword):
            return [.accountID(accountID), configuration.map { .commandJSON(encode($0)) } ?? .null, .bool(hasPassword)]
        case .createDraft(let id, let accountID, let content):
            return [.uuid(id), .accountID(accountID), .commandJSON(encode(content))]
        case .createReplyDraft(let id, let reference, let replyAll):
            return [.uuid(id), .commandJSON(encode(reference)), .bool(replyAll)]
        case .createForwardDraft(let id, let reference):
            return [.uuid(id), .commandJSON(encode(reference))]
        case .saveDraft(let id, let revision, let content):
            return [.uuid(id), .integer(Int(revision)), .commandJSON(encode(content))]
        case .deleteDraft(let id, let revision):
            return [.uuid(id), .integer(Int(revision))]
        case .getDraft(let id):
            return [.uuid(id)]
        case .listDrafts(let accountID, let limit):
            return [accountID.map(AnyCodable.accountID) ?? .null, .integer(limit)]
        case .importDraftAttachment(let id, let accountID, let source, let filename, let mimeType):
            return [.uuid(id), .accountID(accountID), .commandJSON(encode(source)), .string(filename), .string(mimeType)]
        case .getDraftAttachment(let accountID, let id):
            return [.accountID(accountID), .uuid(id)]
        case .sendDraft(let id, let draftID, let revision):
            return [.uuid(id), .uuid(draftID), .integer(Int(revision))]
        case .retrySubmission(let id, let acknowledge):
            return [.uuid(id), .bool(acknowledge)]
        case .cancelSubmission(let id), .getSubmission(let id):
            return [.uuid(id)]
        case .listOutbox(let accountID, let limit):
            return [accountID.map(AnyCodable.accountID) ?? .null, .integer(limit)]
        case .configureRemote(let configuration): return [.commandJSON(encode(configuration))]
        case .revokeAutomationClient(let id): return [.uuid(id)]
        }
    }

    static func command(name: CommandName, payload: [AnyCodable]) throws -> Command {
        let expectedCount: Int
        switch name {
        case .saveAccount, .setAccountEnabled, .exportAccounts, .renameAccount,
             .renameFolder, .setRetention, .fetchAttachment, .setFlagged,
             .move, .openMessage, .moveTab, .setListColumnVisible,
             .setListColumnWidth, .setSetting, .createForwardDraft,
             .deleteDraft, .getDraftAttachment, .retrySubmission:
            expectedCount = 2
        case .configureSMTP, .createDraft, .createReplyDraft, .saveDraft, .sendDraft:
            expectedCount = 3
        case .importAccounts:
            expectedCount = 4
        case .importDraftAttachment:
            expectedCount = 5
        case .list:
            expectedCount = 4
        case .listDrafts, .listOutbox:
            expectedCount = 2
        case .selectMessages:
            expectedCount = 2
        case .search:
            expectedCount = 2
        case .read, .raw, .markRead, .markUnread, .archive, .trash,
             .openSearchResult, .openWindow, .activateTab, .closeTab, .closeOthers, .closeToRight,
             .keepTab, .setFindQuery, .setFindPresented, .setSearchQuery, .selectSearchResult,
             .setSearchFieldFocused, .setPairingPresented, .pairingUI,
             .setReadingMode, .setRemoteImages, .setListCustomizationTarget,
             .setListPaneLayout, .setListPresentation, .setListColumnOrder,
             .setListSort, .setWorkspaceSync, .getSetting,
             .configureRemote, .revokeAutomationClient, .cancelSubmission, .getSubmission,
             .getDraft:
            expectedCount = 1
        case .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict:
            expectedCount = 2
        case .removeAccount, .selectFolder:
            expectedCount = 1
        case .selectAll, .clearSelection, .refresh, .undo, .nextTab, .previousTab,
             .toggleSearch, .toggleFind, .toggleSidebar, .showSettings,
             .toggleRawSource, .resetListSettings, .resetGlobalListSettings, .cancelSearch, .getSettings:
            expectedCount = 0
        }
        guard payload.count == expectedCount else {
            throw AutomationCommandError.invalidPayload(name.rawValue)
        }
        func require<T>(_ index: Int, _ cast: (AnyCodable) -> T?) throws -> T {
            guard payload.indices.contains(index), let value = cast(payload[index]) else { throw AutomationCommandError.invalidPayload(name.rawValue) }
            return value
        }
        func requireInt64(_ index: Int) throws -> Int64 {
            guard payload.indices.contains(index),
                  let raw = int(payload[index]),
                  let value = Int64(exactly: raw)
            else { throw AutomationCommandError.invalidPayload(name.rawValue) }
            return value
        }
        func decode<T: Decodable>(_ index: Int, _ type: T.Type) throws -> T {
            let data = try require(index) { value in value.commandData }
            return try JSONDecoder().decode(type, from: data)
        }
        func requireData(_ index: Int) throws -> Data {
            try require(index) { $0.commandData }
        }
        func requireStringEnum<T>(_ index: Int, _ make: (String) -> T?) throws -> T {
            guard payload.indices.contains(index),
                  let raw = string(payload[index]),
                  let value = make(raw)
            else { throw AutomationCommandError.invalidPayload(name.rawValue) }
            return value
        }
        switch name {
        case .saveAccount: return .saveAccount(try decode(0, AccountConfig.self), hasPassword: try require(1) { if case .bool(let v) = $0 { return v }; return nil })
        case .configureSMTP:
            return .configureSMTP(
                try require(0, id(AccountID.self)),
                try optionalDecoded(payload[safe: 1], SMTPConfiguration.self),
                hasPassword: try require(2, bool)
            )
        case .createDraft:
            return .createDraft(
                id: try require(0, uuid),
                accountID: try require(1, id(AccountID.self)),
                content: try decode(2, DraftContent.self)
            )
        case .createReplyDraft:
            return .createReplyDraft(
                id: try require(0, uuid),
                try decode(1, MessageReference.self),
                replyAll: try require(2, bool)
            )
        case .createForwardDraft:
            return .createForwardDraft(
                id: try require(0, uuid),
                try decode(1, MessageReference.self)
            )
        case .saveDraft:
            return .saveDraft(
                id: try require(0, uuid),
                expectedRevision: try requireInt64(1),
                content: try decode(2, DraftContent.self)
            )
        case .deleteDraft:
            return .deleteDraft(id: try require(0, uuid), expectedRevision: try requireInt64(1))
        case .getDraft:
            return .getDraft(try require(0, uuid))
        case .listDrafts:
            return .listDrafts(try optionalID(payload[safe: 0], AccountID.self), try require(1, int))
        case .importDraftAttachment:
            return .importDraftAttachment(
                id: try require(0, uuid),
                account: try require(1, id(AccountID.self)),
                source: try decode(2, DraftAttachmentSource.self),
                filename: try require(3, string),
                mimeType: try require(4, string)
            )
        case .getDraftAttachment:
            return .getDraftAttachment(
                account: try require(0, id(AccountID.self)),
                id: try require(1, uuid)
            )
        case .sendDraft:
            return .sendDraft(
                id: try require(0, uuid),
                draftID: try require(1, uuid),
                expectedRevision: try requireInt64(2)
            )
        case .retrySubmission:
            return .retrySubmission(try require(0, uuid), acknowledgeDuplicateRisk: try require(1, bool))
        case .cancelSubmission:
            return .cancelSubmission(try require(0, uuid))
        case .getSubmission:
            return .getSubmission(try require(0, uuid))
        case .listOutbox:
            return .listOutbox(try optionalID(payload[safe: 0], AccountID.self), try require(1, int))
        case .removeAccount: return .removeAccount(try require(0, id(AccountID.self)))
        case .setAccountEnabled: return .setAccountEnabled(try require(0, id(AccountID.self)), try require(1, bool))
        case .exportAccounts: return .exportAccounts(try decode(0, [AccountID].self), includeSettings: try require(1, bool))
        case .importAccounts:
            return .importAccounts(
                try requireData(0),
                selectedIDs: try decode(1, [AccountID].self),
                replaceExisting: try require(2, bool),
                importSettings: try require(3, bool)
            )
        case .renameAccount: return .renameAccount(try require(0, id(AccountID.self)), try require(1, string))
        case .selectFolder: return .selectFolder(try optionalID(payload.first, FolderID.self))
        case .renameFolder: return .renameFolder(try require(0, id(FolderID.self)), try require(1, string))
        case .setRetention: return .setRetention(try require(0, id(FolderID.self)), try require(1, bool))
        case .list: return .list(try optionalID(payload.first, FolderID.self), try optionalDecoded(payload[safe: 1], MessagePageCursor.self), try require(2, int), try decode(3, MailListSort.self))
        case .read: return .read(try decode(0, MessageReference.self))
        case .raw: return .raw(try decode(0, MessageReference.self))
        case .fetchAttachment: return .fetchAttachment(try decode(0, MessageReference.self), try require(1, string))
        case .search: return .search(try require(0, string), try require(1, int))
        case .markRead: return .markRead(try decode(0, MessageTarget.self))
        case .markUnread: return .markUnread(try decode(0, MessageTarget.self))
        case .setFlagged: return .setFlagged(try decode(0, MessageTarget.self), try require(1, bool))
        case .archive: return .archive(try decode(0, MessageTarget.self))
        case .trash: return .trash(try decode(0, MessageTarget.self))
        case .move: return .move(try decode(0, MessageTarget.self), try require(1, id(FolderID.self)))
        case .selectMessages:
            return .selectMessages(
                try decode(0, MessageTarget.self),
                anchor: try optionalDecoded(payload[safe: 1], MessageReference.self)
            )
        case .selectAll: return .selectAll
        case .clearSelection: return .clearSelection
        case .refresh: return .refresh
        case .undo: return .undo
        case .openMessage: return .openMessage(try decode(0, MessageReference.self), permanent: try require(1, bool))
        case .openSearchResult: return .openSearchResult(try decode(0, MessageReference.self))
        case .openWindow: return .openWindow(try decode(0, MessageReference.self))
        case .activateTab: return .activateTab(try require(0, uuid))
        case .closeTab: return .closeTab(try require(0, uuid))
        case .closeOthers: return .closeOthers(try require(0, uuid))
        case .closeToRight: return .closeToRight(try require(0, uuid))
        case .keepTab: return .keepTab(try require(0, uuid))
        case .moveTab: return .moveTab(try require(0, uuid), try require(1, int))
        case .nextTab: return .nextTab
        case .previousTab: return .previousTab
        case .toggleSearch: return .toggleSearch
        case .toggleFind: return .toggleFind
        case .setFindQuery: return .setFindQuery(try require(0, string))
        case .setFindPresented: return .setFindPresented(try require(0, bool))
        case .setSearchQuery: return .setSearchQuery(try require(0, string))
        case .selectSearchResult: return .selectSearchResult(try optionalDecoded(payload.first, MessageReference.self))
        case .setSearchFieldFocused: return .setSearchFieldFocused(try require(0, bool))
        case .cancelSearch: return .cancelSearch
        case .toggleSidebar: return .toggleSidebar
        case .showSettings: return .showSettings
        case .toggleRawSource: return .toggleRawSource
        case .setPairingPresented: return .setPairingPresented(try require(0, bool))
        case .pairingUI: return .pairingUI(try decode(0, PairingUIAction.self))
        case .setReadingMode: return .setReadingMode(try requireStringEnum(0, AutomationReadingMode.init(rawValue:)))
        case .setRemoteImages: return .setRemoteImages(try require(0, bool))
        case .setListCustomizationTarget: return .setListCustomizationTarget(try requireStringEnum(0, MailListCustomizationTargetValue.init(rawValue:)))
        case .setListPaneLayout: return .setListPaneLayout(try requireStringEnum(0, MailPaneLayout.init(rawValue:)))
        case .setListPresentation: return .setListPresentation(try requireStringEnum(0, MailListPresentation.init(rawValue:)))
        case .setListColumnOrder: return .setListColumnOrder(try decode(0, [MailListColumn].self))
        case .setListColumnVisible: return .setListColumnVisible(try requireStringEnum(0, MailListColumn.init(rawValue:)), try require(1, bool))
        case .setListColumnWidth: return .setListColumnWidth(try requireStringEnum(0, MailListColumn.init(rawValue:)), try require(1, double))
        case .setListSort: return .setListSort(try decode(0, MailListSort.self))
        case .resetListSettings: return .resetListSettings
        case .resetGlobalListSettings: return .resetGlobalListSettings
        case .setWorkspaceSync: return .setWorkspaceSync(try require(0, bool))
        case .setWorkspaceSyncCategory:
            return .setWorkspaceSyncCategory(
                try requireStringEnum(0, WorkspaceSyncCategory.init(rawValue:)),
                try require(1, bool)
            )
        case .resolveWorkspaceSyncConflict:
            return .resolveWorkspaceSyncConflict(
                try requireStringEnum(0, WorkspaceSyncCategory.init(rawValue:)),
                try requireStringEnum(1, WorkspaceSyncChoice.init(rawValue:))
            )
        case .getSetting: return .getSetting(try require(0, string))
        case .setSetting:
            return .setSetting(
                try require(0, string),
                try optionalString(payload[safe: 1])
            )
        case .configureRemote: return .configureRemote(try decode(0, AutomationRemoteConfiguration.self))
        case .revokeAutomationClient: return .revokeAutomationClient(try require(0, uuid))
        case .getSettings: return .getSettings
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func id<T>(_ type: T.Type) -> (AnyCodable) -> T? {
        { value in
            if type == AccountID.self {
                switch value {
                case .accountID(let id): return id as? T
                case .string(let raw): return AccountID(rawValue: raw) as? T
                default: return nil
                }
            }
            if type == FolderID.self {
                switch value {
                case .folderID(let id): return id as? T
                case .integer(let raw): return FolderID(rawValue: Int64(raw)) as? T
                case .double(let raw): return FolderID(rawValue: Int64(raw)) as? T
                default: return nil
                }
            }
            if type == MessageID.self {
                switch value {
                case .messageID(let id): return id as? T
                case .integer(let raw): return MessageID(rawValue: Int64(raw)) as? T
                case .double(let raw): return MessageID(rawValue: Int64(raw)) as? T
                default: return nil
                }
            }
            return nil
        }
    }

    private static func string(_ value: AnyCodable) -> String? {
        if case .string(let value) = value { return value }
        return nil
    }
    private static func bool(_ value: AnyCodable) -> Bool? {
        if case .bool(let value) = value { return value }
        return nil
    }
    private static func int(_ value: AnyCodable) -> Int? {
        switch value {
        case .integer(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }
    private static func double(_ value: AnyCodable) -> Double? {
        switch value {
        case .double(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
    private static func uuid(_ value: AnyCodable) -> UUID? {
        if case .uuid(let value) = value { return value }
        if case .string(let value) = value { return UUID(uuidString: value) }
        return nil
    }
    private static func optionalString(_ value: AnyCodable?) throws -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let result = string(value) else {
            throw AutomationCommandError.invalidPayload("string")
        }
        return result
    }
    private static func optionalID<T>(_ value: AnyCodable?, _ type: T.Type) throws -> T? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return try requireID(value, type)
    }
    private static func requireID<T>(_ value: AnyCodable, _ type: T.Type) throws -> T {
        guard let value = id(type)(value) else {
            throw AutomationCommandError.invalidPayload("identity")
        }
        return value
    }
    private static func optionalDecoded<T: Decodable>(_ value: AnyCodable?, _ type: T.Type) throws -> T? {
        guard let value else { return nil }
        if case .null = value { return nil }
        guard let data = value.commandData else {
            throw AutomationCommandError.invalidPayload("encoded payload")
        }
        return try JSONDecoder().decode(type, from: data)
    }

}
private extension AnyCodable {
    var commandData: Data? {
        if case .commandJSON(let data) = self { return data }
        if case .string(let value) = self { return Data(base64Encoded: value) }
        return nil
    }
}

public enum AutomationFailure: String, Codable, Hashable, Sendable {
    case domain
    case usage
    case unavailable
    case authorization

    public var exitCode: Int32 {
        switch self {
        case .domain: 1
        case .usage: 2
        case .unavailable: 3
        case .authorization: 4
        }
    }
}

public enum AutomationRequestError: LocalizedError, Equatable, Sendable {
    case invalidOperation
    case invalidStateModifiers
    case invalidTransferRequest

    public var errorDescription: String? {
        switch self {
        case .invalidOperation:
            "Automation request must contain exactly one operation: command, control, or state."
        case .invalidStateModifiers:
            "State request modifiers require a state operation."
        case .invalidTransferRequest:
            "Malformed automation transfer request."
        }
    }
}

public enum AutomationCommandError: LocalizedError, Equatable, Sendable {
    case invalidPayload(String)
    case staleSelection(expected: UInt64, actual: UInt64)
    case permissionDenied(AutomationAccess)
    case appUnavailable
    case runtimeOwned
    case unsupported(String)

    public var failure: AutomationFailure {
        switch self {
        case .invalidPayload: .usage
        case .staleSelection, .unsupported: .domain
        case .permissionDenied: .authorization
        case .appUnavailable, .runtimeOwned: .unavailable
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidPayload(let command): "Invalid payload for \(command)."
        case .staleSelection(let expected, let actual): "Selection is stale (observed revision \(expected), current revision \(actual)); fetch ui state and retry."
        case .permissionDenied(let access): "This client is not granted \(access.rawValue) access."
        case .appUnavailable: "The Mailternal app or headless engine is not reachable."
        case .runtimeOwned: "Another Mailternal runtime already owns this container."
        case .unsupported(let value): "Unsupported automation operation: \(value)."
        }
    }
}

public struct AutomationResponse: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public let requestID: UUID
    public let ok: Bool
    public let result: Data?
    public let error: String?
    public let failure: AutomationFailure?

    public init(
        requestID: UUID,
        ok: Bool,
        result: Data? = nil,
        error: String? = nil,
        failure: AutomationFailure? = nil
    ) {
        self.schema = AutomationProtocol.responseSchema
        self.version = AutomationProtocol.version
        self.requestID = requestID
        self.ok = ok
        self.result = result
        self.error = error
        self.failure = ok ? nil : (failure ?? .domain)
    }
    private enum CodingKeys: String, CodingKey {
        case schema, version, requestID, ok, result, error, failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        self.schema = try container.decode(String.self, forKey: .schema)
        self.version = try container.decode(Int.self, forKey: .version)
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.ok = ok
        self.result = try container.decodeIfPresent(Data.self, forKey: .result)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        let failure = try container.decodeIfPresent(AutomationFailure.self, forKey: .failure)
        self.failure = ok ? nil : (failure ?? .domain)
    }
}


public enum AutomationControl: String, Codable, Hashable, Sendable {
    case engineStatus
    case engineShutdown
    case remoteStatus
    case pairingCreate
    case pairingClaim
    case transferRead
    case transferWrite
    case transferCreate
    case transferCancel
}

public enum AutomationRuntimeKind: String, Codable, Hashable, Sendable {
    case app
    case daemon
    case notRunning
}

public struct AutomationRuntimeStatus: Codable, Equatable, Hashable, Sendable {
    public let kind: AutomationRuntimeKind
    public let processID: Int32?
    public let ready: Bool

    public init(kind: AutomationRuntimeKind, processID: Int32? = nil, ready: Bool = false) {
        self.kind = kind
        self.processID = processID
        self.ready = ready
    }
}

public struct AutomationRemoteStatus: Codable, Equatable, Hashable, Sendable {
    public let enabled: Bool
    public let running: Bool
    public let host: String
    public let port: UInt16

    public init(enabled: Bool, running: Bool, host: String, port: UInt16) {
        self.enabled = enabled
        self.running = running
        self.host = host
        self.port = port
    }
}

public struct CommandResult: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public let command: CommandName
    public let data: Data?
    public let stateRevision: UInt64?

    public init(command: CommandName, data: Data? = nil, stateRevision: UInt64? = nil) {
        self.schema = AutomationProtocol.responseSchema
        self.version = AutomationProtocol.version
        self.command = command
        self.data = data
        self.stateRevision = stateRevision
    }
}


public struct AutomationPairingOfferResult: Codable, Equatable, Hashable, Sendable {
    public let code: String
    public let offerID: UUID
    public let expiresAt: Date
    public let host: String
    public let port: UInt16
    public let fingerprint: String

    public init(code: String, offerID: UUID, expiresAt: Date, host: String, port: UInt16, fingerprint: String) {
        self.code = code
        self.offerID = offerID
        self.expiresAt = expiresAt
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
    }
}

public struct AutomationPairingClaimResult: Codable, Equatable, Hashable, Sendable {
    public let endpoint: AutomationPairedEndpoint

    public init(endpoint: AutomationPairedEndpoint) {
        self.endpoint = endpoint
    }
}

public struct AutomationFolderState: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: FolderID
    public let accountID: AccountID
    public let name: String
    public let path: String
    public let role: FolderRole
    public let unreadCount: Int
    public let totalCount: Int
    public let keepLocally: Bool
    public let activity: String

    public init(id: FolderID, accountID: AccountID, name: String, path: String, role: FolderRole,
                unreadCount: Int, totalCount: Int, keepLocally: Bool, activity: String) {
        self.id = id; self.accountID = accountID; self.name = name; self.path = path; self.role = role
        self.unreadCount = unreadCount; self.totalCount = totalCount; self.keepLocally = keepLocally; self.activity = activity
    }
}

public struct AutomationReaderTabState: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let messageID: MessageID
    public let link: String?
    public let isTransient: Bool
    public let order: Int
    public let scrollOffset: Double

    public init(id: UUID, messageID: MessageID, link: String?, isTransient: Bool, order: Int, scrollOffset: Double) {
        self.id = id; self.messageID = messageID; self.link = link; self.isTransient = isTransient; self.order = order; self.scrollOffset = scrollOffset
    }
}

public struct AutomationWindowState: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let title: String?
    public let isVisible: Bool
    public let isKey: Bool
    public let focusedSurface: String?

    public init(
        id: UUID,
        kind: String,
        title: String? = nil,
        isVisible: Bool,
        isKey: Bool,

        focusedSurface: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isVisible = isVisible
        self.isKey = isKey
        self.focusedSurface = focusedSurface
    }
}

public struct AutomationDialogState: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let isPresented: Bool
    public let message: String?

    public init(id: String, kind: String, isPresented: Bool, message: String? = nil) {
        self.id = id
        self.kind = kind
        self.isPresented = isPresented
        self.message = message
    }
}

public struct AutomationActionState: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let isEnabled: Bool
    public let requiresSelection: Bool
    public let requiresGUI: Bool

    public init(id: String, isEnabled: Bool, requiresSelection: Bool = false, requiresGUI: Bool = false) {
        self.id = id
        self.isEnabled = isEnabled
        self.requiresSelection = requiresSelection
        self.requiresGUI = requiresGUI
    }
}

/// A wire-safe message row. Unlike the store's local `MessageRow`, every
/// automation row carries a canonical cross-device deep link. The local ID is
/// retained only as a convenience for a trusted same-device client.
public struct AutomationMessageRow: Identifiable, Hashable, Sendable, Codable {
    public let id: MessageID
    public let link: String
    public let from: String
    public let senderAddress: String?
    public let subject: String
    public let preview: String
    public let date: Date
    public let isRead: Bool
    public let hasAttachments: Bool
    public let isFlagged: Bool
    public let folderName: String
    public let accountName: String?
    public let folderID: FolderID?

    public init(row: MessageRow, link: String) {
        self.id = row.id
        self.link = link
        self.from = row.from
        self.senderAddress = row.senderAddress
        self.subject = row.subject
        self.preview = row.preview
        self.date = row.date
        self.isRead = row.isRead
        self.hasAttachments = row.hasAttachments
        self.isFlagged = row.isFlagged
        self.folderName = row.folderName
        self.accountName = row.accountName
        self.folderID = row.folderID
    }
}

public struct AutomationMessagePage: Codable, Equatable, Hashable, Sendable {
    public let rows: [AutomationMessageRow]
    public let next: MessagePageCursor?

    public init(rows: [AutomationMessageRow], next: MessagePageCursor?) {
        self.rows = rows
        self.next = next
    }
}
public struct AppState: Codable, Equatable, Hashable, Sendable {
    public let outgoing: OutgoingState
    public let schema: String
    public let version: Int
    public let accounts: [AccountConfig]
    public let accountStates: [AccountID: String]
    public let folders: [AutomationFolderState]
    public let selectedFolderID: FolderID?
    public let selectedMessageIDs: [MessageID]
    public let selectedMessageID: MessageID?
    public let selectionRevision: UInt64
    public let listRows: [AutomationMessageRow]
    public let listCursor: MessagePageCursor?
    public let activeListSort: MailListSort
    public let readerTabs: [AutomationReaderTabState]
    public let activeTabID: UUID?
    public let focusedSurface: String
    public let visibleSearchQuery: String?
    public let isSearchPresented: Bool
    public let isFindPresented: Bool
    public let findQuery: String?
    public let isRawSourcePresented: Bool
    public let emailReadingMode: String?
    public let allowRemoteImages: Bool
    public let syncOnline: Bool
    public let syncMode: String
    public let listConfiguration: MailListConfiguration
    public let windows: [AutomationWindowState]
    public let dialogs: [AutomationDialogState]
    public let availableActions: [AutomationActionState]
    public let settings: [String: String]
    public let searchResults: [AutomationMessageRow]
    public let isSearchLoading: Bool
    public let searchError: String?
    public let selectedSearchResultID: MessageID?
    public let searchFieldFocused: Bool

    public init(
        accounts: [AccountConfig],
        accountStates: [AccountID: String],
        folders: [AutomationFolderState],
        selectedFolderID: FolderID?,
        selectedMessageIDs: [MessageID],
        selectedMessageID: MessageID?,
        selectionRevision: UInt64,
        listRows: [AutomationMessageRow],
        listCursor: MessagePageCursor?,
        activeListSort: MailListSort,
        readerTabs: [AutomationReaderTabState],
        activeTabID: UUID?,
        focusedSurface: String,
        visibleSearchQuery: String?,
        isSearchPresented: Bool,
        isFindPresented: Bool,
        findQuery: String?,
        isRawSourcePresented: Bool,
        emailReadingMode: String?,
        allowRemoteImages: Bool,
        syncOnline: Bool,
        syncMode: String,
        listConfiguration: MailListConfiguration,
        windows: [AutomationWindowState] = [],
        dialogs: [AutomationDialogState] = [],
        availableActions: [AutomationActionState] = [],
        settings: [String: String] = [:],
        searchResults: [AutomationMessageRow] = [],
        isSearchLoading: Bool = false,
        searchError: String? = nil,
        selectedSearchResultID: MessageID? = nil,
        searchFieldFocused: Bool = false,
        outgoing: OutgoingState = OutgoingState()
    ) {
        self.schema = AutomationProtocol.stateSchema
        self.outgoing = outgoing
        self.version = AutomationProtocol.version
        self.accounts = accounts
        self.accountStates = accountStates
        self.folders = folders
        self.selectedFolderID = selectedFolderID
        self.selectedMessageIDs = selectedMessageIDs
        self.selectedMessageID = selectedMessageID
        self.selectionRevision = selectionRevision
        self.listRows = listRows
        self.listCursor = listCursor
        self.activeListSort = activeListSort
        self.readerTabs = readerTabs
        self.activeTabID = activeTabID
        self.focusedSurface = focusedSurface
        self.visibleSearchQuery = visibleSearchQuery
        self.isSearchPresented = isSearchPresented
        self.isFindPresented = isFindPresented
        self.findQuery = findQuery
        self.isRawSourcePresented = isRawSourcePresented
        self.emailReadingMode = emailReadingMode
        self.allowRemoteImages = allowRemoteImages
        self.syncOnline = syncOnline
        self.syncMode = syncMode
        self.listConfiguration = listConfiguration
        self.windows = windows
        self.dialogs = dialogs
        self.availableActions = availableActions
        self.settings = settings
        self.searchResults = searchResults
        self.isSearchLoading = isSearchLoading
        self.searchError = searchError
        self.selectedSearchResultID = selectedSearchResultID
        self.searchFieldFocused = searchFieldFocused
    }

}

public enum AppStateEventKind: String, Codable, Hashable, Sendable {
    case snapshot
    case change
    case gap
}

public struct AppStateEvent: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public let revision: UInt64
    public let kind: AppStateEventKind
    public let state: AppState?

    public init(revision: UInt64, kind: AppStateEventKind, state: AppState?) {
        self.schema = AutomationProtocol.eventSchema
        self.version = AutomationProtocol.version
        self.revision = revision
        self.kind = kind
        self.state = state
    }
}

public struct AutomationRequest: Codable, Equatable, Hashable, Sendable {
    public let schema: String
    public let version: Int
    public let requestID: UUID
    public let token: String
    /// Retained for wire compatibility only. Authorization is derived from the
    /// authenticated transport context, never from this field.
    public let origin: CommandOrigin
    public let clientID: String?
    public let command: Command?
    public let control: AutomationControl?
    public let wantsState: Bool
    public let wantsGUIState: Bool
    public let observesState: Bool
    public let afterRevision: UInt64?
    /// A one-request secret for account setup. It is never journaled or
    /// included in AppState; callers should prefer an OS-protected prompt.
    public let secret: String?
    public let pairingCode: String?
    public let pairingClientName: String?
    public let pairingGrant: AutomationGrant?
    /// Transfer controls carry only an opaque identifier and a bounded range.
    /// The server never accepts a filesystem path from this request.
    public let transferID: UUID?
    public let transferOffset: UInt64?
    public let transferLength: Int?
    public let transferSequence: UInt64?
    public let transferTotalBytes: UInt64?
    public let transferData: Data?
    public let transferFinal: Bool?
    public let transferFilename: String?
    public let transferContentType: String?

    public init(
        requestID: UUID = UUID(),
        token: String,
        origin: CommandOrigin,
        clientID: String? = nil,
        command: Command? = nil,
        control: AutomationControl? = nil,
        wantsState: Bool = false,
        wantsGUIState: Bool = false,
        observesState: Bool = false,
        afterRevision: UInt64? = nil,
        secret: String? = nil,
        pairingCode: String? = nil,
        pairingClientName: String? = nil,
        pairingGrant: AutomationGrant? = nil,
        transferID: UUID? = nil,
        transferOffset: UInt64? = nil,
        transferLength: Int? = nil,
        transferSequence: UInt64? = nil,
        transferTotalBytes: UInt64? = nil,
        transferData: Data? = nil,
        transferFinal: Bool? = nil,
        transferFilename: String? = nil,
        transferContentType: String? = nil
    ) {
        self.schema = AutomationProtocol.commandSchema
        self.version = AutomationProtocol.version
        self.requestID = requestID
        self.token = token
        self.origin = origin
        self.clientID = clientID
        self.command = command
        self.control = control
        self.wantsState = wantsState
        self.wantsGUIState = wantsGUIState
        self.observesState = observesState
        self.afterRevision = afterRevision
        self.secret = secret
        self.pairingCode = pairingCode
        self.pairingClientName = pairingClientName
        self.pairingGrant = pairingGrant
        self.transferID = transferID
        self.transferOffset = transferOffset
        self.transferLength = transferLength
        self.transferSequence = transferSequence
        self.transferTotalBytes = transferTotalBytes
        self.transferData = transferData
        self.transferFinal = transferFinal
        self.transferFilename = transferFilename
        self.transferContentType = transferContentType
    }


    /// Validates the operation category before transport dispatch. GUI and
    /// observation flags refine a state request; they never create a second
    /// operation category.
    public func validateOperation() throws {
        let categoryCount = (command == nil ? 0 : 1) + (control == nil ? 0 : 1) + (wantsState ? 1 : 0)
        guard categoryCount == 1 else {
            throw AutomationRequestError.invalidOperation
        }
        guard wantsState || (!wantsGUIState && !observesState && afterRevision == nil) else {
            throw AutomationRequestError.invalidStateModifiers
        }
        guard observesState || afterRevision == nil else {
            throw AutomationRequestError.invalidStateModifiers
        }
        let noTransferMetadata = transferID == nil && transferOffset == nil && transferLength == nil
            && transferSequence == nil && transferTotalBytes == nil && transferData == nil
            && transferFinal == nil && transferFilename == nil && transferContentType == nil
        switch control {
        case .transferRead:
            guard command == nil, !wantsState, !wantsGUIState, !observesState,
                  afterRevision == nil, transferID != nil, transferOffset != nil,
                  let length = transferLength,
                  (length == 0 || (1...AutomationTransferPolicy.chunkBytes).contains(length)),
                  transferSequence == nil, transferTotalBytes == nil, transferData == nil,
                  transferFinal == nil, transferFilename == nil, transferContentType == nil,
                  pairingCode == nil, pairingGrant == nil
            else { throw AutomationRequestError.invalidTransferRequest }
        case .transferCancel:
            guard command == nil, !wantsState, !wantsGUIState, !observesState,
                  afterRevision == nil, transferID != nil,
                  transferOffset == nil, transferLength == nil, transferSequence == nil,
                  transferTotalBytes == nil, transferData == nil, transferFinal == nil,
                  transferFilename == nil, transferContentType == nil,
                  pairingCode == nil, pairingGrant == nil
            else { throw AutomationRequestError.invalidTransferRequest }
        case .transferCreate:
            guard command == nil, !wantsState, !wantsGUIState, !observesState,
                  afterRevision == nil, transferID == nil, transferOffset == nil,
                  transferLength == nil, transferSequence == nil,
                  let total = transferTotalBytes, total <= AutomationTransferPolicy.maximumBytes,
                  transferData == nil, transferFinal == nil,
                  let filename = transferFilename, !filename.isEmpty,
                  let contentType = transferContentType, !contentType.isEmpty,
                  pairingCode == nil, pairingGrant == nil
            else { throw AutomationRequestError.invalidTransferRequest }
        case .transferWrite:
            guard command == nil, !wantsState, !wantsGUIState, !observesState,
                  afterRevision == nil, transferID != nil, transferOffset != nil,
                  let length = transferLength,
                  let sequence = transferSequence,
                  let total = transferTotalBytes,
                  total <= AutomationTransferPolicy.maximumBytes,
                  let data = transferData,
                  data.count == length,
                  length <= AutomationTransferPolicy.chunkBytes,
                  transferFinal != nil, transferFilename == nil, transferContentType == nil,
                  pairingCode == nil, pairingGrant == nil
            else { throw AutomationRequestError.invalidTransferRequest }
            _ = sequence
        default:
            guard noTransferMetadata else {
                throw AutomationRequestError.invalidTransferRequest
            }
        }
    }
}
private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
