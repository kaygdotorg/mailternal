import Foundation
import MailternalInterfaces
private enum SchemaGenerationError: LocalizedError {
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let path):
            return "Schema generation could not observe \(path)"
        }
    }
}

private struct MoveOutput: Codable {
    let movedCount: Int
    let skippedCrossAccountCount: Int
}

/// Builds the published automation contract from values encoded by the actual
/// wire types.  The generator intentionally has no field-name tables: coding
/// keys and nested shapes come from each type's `Encodable` implementation.
public enum AutomationSchemaGenerator {
    public static func makeJSON() throws -> Data {
        let commands = try CommandName.allCases.map { name -> SchemaJSON in
            let command = try sampleCommand(named: name)
            return .object([
                "name": .string(name.rawValue),
                "access": .string(command.access.rawValue),
                "requiresGUI": .bool(command.requiresGUI),
                "cli": .string(cliGrammar(for: name)),
                "schema": try commandSchema(for: name)
            ])
        }

        let commandSchemas = try Dictionary(uniqueKeysWithValues: CommandName.allCases.map { name in
            return (name.rawValue, try commandSchema(for: name))
        })
        let resultSchemas = try Dictionary(uniqueKeysWithValues: CommandName.allCases.map { name in
            (name.rawValue, try resultSchema(for: name))
        })

        let request = try inferredSchema(from: [
            sampleRequest(),
            sampleRequest(includeOptionalValues: false),
            sampleTransferRequest()
        ])
        let response = try inferredSchema(from: [sampleResponse(), sampleFailureResponse()])
        let state = try inferredSchema(from: [sampleState(), sampleState(includeOptionalValues: false)])
        let event = try inferredSchema(from: [
            AppStateEvent(revision: 7, kind: .change, state: sampleState()),
            AppStateEvent(revision: 8, kind: .gap, state: nil)
        ])
        let commandResultOutput = cliResultEnvelopeSchema(resultSchemas: Array(resultSchemas.values))
        let errorOutput = try inferredSchema(from: [
            .object([
                "schema": .string(AutomationProtocol.responseSchema),
                "version": .integer(AutomationProtocol.version),
                "ok": .bool(false),
                "error": .string("permission denied"),
                "failure": .string(AutomationFailure.authorization.rawValue)
            ])
        ])
        let setupOutput = try inferredSchema(from: [
            .object([
                "schema": .string("mailternal.setup.v1"),
                "version": .integer(1),
                "command": .string("ln -sf -- '/Mailternal.app' '/usr/local/bin/mailternal'"),
                "target": .string("/usr/local/bin/mailternal"),
                "executable": .string("/Mailternal.app/Contents/MacOS/mailternal"),
                "endpoint": .string("/Mailternal/mailternal.sock")
            ])
        ])
        let helpOutput = try inferredSchema(from: [
            .object([
                "schema": .string("mailternal.help.v1"),
                "version": .integer(1),
                "usage": .string("mailternal [global options] <command>")
            ])
        ])
        let engineOutput = try inferredSchema(from: [
            cliResultExample(command: nil, result: .object([
                "state": .string("not-running"),
                "endpoint": .string("/Mailternal/mailternal.sock")
            ])),
            cliResultExample(command: nil, result: .object([
                "state": .string("running"),
                "owner": .string("headless"),
                "tokenAvailable": .bool(true)
            ])),
            cliResultExample(command: nil, result: .object([
                "state": .string("running"),
                "owner": .string("app"),
                "stopped": .bool(false)
            ]))
        ])
        let pairingOutput = try inferredSchema(from: [
            cliResultExample(command: nil, result: .object([
                "code": .string("alpha-bravo"),
                "offerID": .string(tabID.uuidString),
                "expiresAt": .string("2023-11-14T22:13:20Z"),
                "host": .string("mac.example.test"),
                "port": .integer(9443),
                "fingerprint": .string(String(repeating: "a", count: 64))
            ])),
            cliResultExample(command: nil, result: .object([
                "paired": .bool(true),
                "clientID": .string(tabID.uuidString),
                "host": .string("mac.example.test"),
                "port": .integer(9443),
                "fingerprint": .string(String(repeating: "a", count: 64))
            ]))
        ])
        let adminOutput = try inferredSchema(from: [
            cliResultExample(command: nil, result: .object([
                "enabled": .bool(true),
                "bindHost": .string("127.0.0.1"),
                "port": .integer(9443),
                "allowWildcard": .bool(false)
            ])),
            cliResultExample(command: .configureRemote, result: .null)
        ])
        let outputs: [String: SchemaJSON] = [
            "commandResult": commandResultOutput,
            "cliResult": commandResultOutput,
            "cliResultScalar": try inferredSchema(from: [cliResultExample(command: .getSetting, result: .string("schema output"))]),
            "cliResultObject": try inferredSchema(from: [cliResultExample(command: .move, result: .object([
                "movedCount": .integer(2),
                "skippedCrossAccountCount": .integer(1)
            ]))]),
            "cliResultNull": try inferredSchema(from: [cliResultExample(command: .refresh, result: .null)]),
            "runtimeStatus": try inferredSchema(from: [cliResultExample(command: nil, result: try encodedValue(AutomationRuntimeStatus(kind: .daemon, processID: 123, ready: true)))]),
            "transferDescriptor": try encodedSchema(AutomationTransferDescriptor(
                transferID: tabID,
                kind: .attachment,
                size: 4,
                filename: "file.txt",
                contentType: "text/plain"
            )),
            "transferChunk": try encodedSchema(AutomationTransferChunk(
                transferID: tabID,
                sequence: 0,
                offset: 0,
                totalBytes: 4,
                data: Data([1, 2, 3, 4]),
                final: true
            )),
            "state": state,
            "event": event,
            "setup": setupOutput,
            "help": helpOutput,
            "pairingOffer": try inferredSchema(from: [cliResultExample(command: nil, result: .object([
                "code": .string("alpha-bravo"),
                "offerID": .string(tabID.uuidString),
                "expiresAt": .string("2023-11-14T22:13:20Z"),
                "host": .string("mac.example.test"),
                "port": .integer(9443),
                "fingerprint": .string(String(repeating: "a", count: 64))
            ]))]),
            "pairingClaim": try inferredSchema(from: [cliResultExample(command: nil, result: .object([
                "paired": .bool(true),
                "clientID": .string(tabID.uuidString),
                "host": .string("mac.example.test"),
                "port": .integer(9443),
                "fingerprint": .string(String(repeating: "a", count: 64))
            ]))]),
            "engine": engineOutput,
            "pairing": pairingOutput,
            "admin": adminOutput,
            "error": errorOutput
        ]

        let root: SchemaJSON = .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "schema": .string("mailternal.schema.v1"),
            "version": .integer(AutomationProtocol.version),
            "protocol": .object([
                "commandSchema": .string(AutomationProtocol.commandSchema),
                "stateSchema": .string(AutomationProtocol.stateSchema),
                "responseSchema": .string(AutomationProtocol.responseSchema),
                "eventSchema": .string(AutomationProtocol.eventSchema),
                "transferSchema": .string(AutomationProtocol.transferSchema),
                "version": .integer(AutomationProtocol.version)
            ]),
            "query": .object([
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .integer(1),
                    "maximum": .integer(AutomationProtocol.maximumQueryLimit)
                ])
            ]),
            "schemas": .object([
                "request": request,
                "response": response,
                "state": state,
                "event": event,
                "commands": .object(commandSchemas),
                "results": .object(resultSchemas),
                "outputs": .object(outputs)
            ]),
            "commands": .array(commands),
            "exitCodes": .object([
                "0": .string("ok"),
                "1": .string("domain failure"),
                "2": .string("usage"),
                "3": .string("app or engine unavailable"),
                "4": .string("authentication or authorization")
            ])
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root) + Data([0x0A])
    }

    // MARK: Codable samples

    private static let accountID = AccountID(rawValue: "schema-account")
    private static let accountLink = AccountLinkID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let folderID = FolderID(rawValue: 42)
    private static let messageID = MessageID(rawValue: 84)
    private static let tabID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let messageLink = MailternalDeepLink.message(
        accountLinkID: accountLink,
        folderLocator: FolderLocator(kind: .path, value: "INBOX"),
        uidValidity: 9,
        uid: IMAPUID(rawValue: 84)
    )
    private static let draftID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let submissionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    private static func sampleAccount() -> AccountConfig {
        AccountConfig(
            id: accountID,
            accountLinkID: accountLink,
            displayName: "Schema account",
            emailAddress: "schema@example.test",
            username: "schema@example.test",
            imap: IMAPEndpoint(host: "imap.example.test", port: 993, security: .implicitTLS),
            isEnabled: true
        )
    }
    private static func sampleDraftContent() -> DraftContent {
        DraftContent(
            from: MailAddress(displayName: "Schema account", address: "schema@example.test"),
            to: [MailAddress(displayName: "Recipient", address: "recipient@example.test")],
            subject: "Schema draft",
            plainText: "Schema body"
        )
    }

    private static func sampleDraft() -> MailDraft {
        MailDraft(
            id: draftID,
            accountID: accountID,
            revision: 2,
            content: sampleDraftContent(),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func sampleOutbox() -> OutboxRecord {
        OutboxRecord(
            id: submissionID,
            accountID: accountID,
            draftID: draftID,
            draftRevision: 2,
            content: sampleDraftContent(),
            messageID: "<schema-outbox@example.test>",
            messageDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func sampleRow(includeOptionalValues: Bool = true) -> AutomationMessageRow {
        AutomationMessageRow(
            row: MessageRow(
                id: messageID,
                from: "Sender",
                senderAddress: includeOptionalValues ? "sender@example.test" : nil,
                subject: "Schema subject",
                preview: "Schema preview",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: false,
                hasAttachments: true,
                isFlagged: true,
                folderName: "INBOX",
                accountName: includeOptionalValues ? "Schema account" : nil,
                folderID: includeOptionalValues ? folderID : nil
            ),
            link: messageLink.formattedString!
        )
    }

    private static func sampleCursor() -> MessagePageCursor {
        MessagePageCursor(
            sort: .newest,
            value: .date(Date(timeIntervalSince1970: 1_700_000_000)),
            uid: IMAPUID(rawValue: 84)
        )
    }

    private static func sampleCommand(named name: CommandName) throws -> Command {
        let reference = MessageReference.link(messageLink)
        let target = MessageTarget.links([messageLink])
        switch name {
        case .saveAccount: return .saveAccount(sampleAccount(), hasPassword: true)
        case .configureSMTP:
            return .configureSMTP(
                accountID,
                SMTPConfiguration(
                    host: "smtp.example.test",
                    port: 465,
                    security: .implicitTLS,
                    username: "schema@example.test"
                ),
                hasPassword: true
            )
        case .createDraft:
            return .createDraft(id: draftID, accountID: accountID, content: sampleDraftContent())
        case .createReplyDraft:
            return .createReplyDraft(id: draftID, reference, replyAll: true)
        case .createForwardDraft:
            return .createForwardDraft(id: draftID, reference)
        case .saveDraft:
            return .saveDraft(id: draftID, expectedRevision: 1, content: sampleDraftContent())
        case .deleteDraft:
            return .deleteDraft(id: draftID, expectedRevision: 2)
        case .getDraft:
            return .getDraft(draftID)
        case .listDrafts:
            return .listDrafts(accountID, 50)
        case .importDraftAttachment:
            return .importDraftAttachment(
                id: tabID, account: accountID, source: .transfer(tabID),
                filename: "file.txt", mimeType: "text/plain"
            )
        case .getDraftAttachment:
            return .getDraftAttachment(account: accountID, id: tabID)
        case .sendDraft:
            return .sendDraft(id: submissionID, draftID: draftID, expectedRevision: 2)
        case .retrySubmission:
            return .retrySubmission(submissionID, acknowledgeDuplicateRisk: true)
        case .cancelSubmission:
            return .cancelSubmission(submissionID)
        case .getSubmission:
            return .getSubmission(submissionID)
        case .listOutbox:
            return .listOutbox(accountID, 50)
        case .configureRemote:
            return .configureRemote(try AutomationRemoteConfiguration(enabled: true, bindHost: "127.0.0.1", port: 9443))
        case .revokeAutomationClient: return .revokeAutomationClient(tabID)
        case .removeAccount: return .removeAccount(accountID)
        case .setAccountEnabled: return .setAccountEnabled(accountID, true)
        case .exportAccounts: return .exportAccounts([accountID], includeSettings: true)
        case .importAccounts: return .importAccounts(Data([1, 2, 3]), selectedIDs: [accountID], replaceExisting: true, importSettings: true)
        case .renameAccount: return .renameAccount(accountID, "Renamed account")
        case .selectFolder: return .selectFolder(folderID)
        case .renameFolder: return .renameFolder(folderID, "Renamed folder")
        case .setRetention: return .setRetention(folderID, true)
        case .list: return .list(folderID, sampleCursor(), 50, .newest)
        case .read: return .read(reference)
        case .raw: return .raw(reference)
        case .fetchAttachment: return .fetchAttachment(reference, "1.2")
        case .search: return .search("schema query", 50)
        case .markRead: return .markRead(target)
        case .markUnread: return .markUnread(target)
        case .setFlagged: return .setFlagged(target, true)
        case .archive: return .archive(target)
        case .trash: return .trash(target)
        case .move: return .move(target, folderID)
        case .selectMessages: return .selectMessages(target, anchor: reference)
        case .selectAll: return .selectAll
        case .clearSelection: return .clearSelection
        case .refresh: return .refresh
        case .undo: return .undo
        case .openMessage: return .openMessage(reference, permanent: true)
        case .openWindow: return .openWindow(reference)
        case .activateTab: return .activateTab(tabID)
        case .closeTab: return .closeTab(tabID)
        case .closeOthers: return .closeOthers(tabID)
        case .closeToRight: return .closeToRight(tabID)
        case .keepTab: return .keepTab(tabID)
        case .moveTab: return .moveTab(tabID, 2)
        case .nextTab: return .nextTab
        case .previousTab: return .previousTab
        case .toggleSearch: return .toggleSearch
        case .toggleFind: return .toggleFind
        case .setFindPresented: return .setFindPresented(true)
        case .setFindQuery: return .setFindQuery("find query")
        case .toggleSidebar: return .toggleSidebar
        case .showSettings: return .showSettings
        case .toggleRawSource: return .toggleRawSource
        case .setReadingMode: return .setReadingMode(.dark)
        case .setRemoteImages: return .setRemoteImages(true)
        case .setListCustomizationTarget: return .setListCustomizationTarget(.global)
        case .setListPaneLayout: return .setListPaneLayout(.sideBySide)
        case .setListPresentation: return .setListPresentation(.columns)
        case .setListColumnOrder: return .setListColumnOrder(MailListColumn.allCases)
        case .setListColumnVisible: return .setListColumnVisible(.subject, true)
        case .setListColumnWidth: return .setListColumnWidth(.subject, 240)
        case .setListSort: return .setListSort(.newest)
        case .resetListSettings: return .resetListSettings
        case .resetGlobalListSettings: return .resetGlobalListSettings
        case .setWorkspaceSyncCategory: return .setWorkspaceSyncCategory(.workspace, true)
        case .resolveWorkspaceSyncConflict: return .resolveWorkspaceSyncConflict(.workspace, .local)
        case .setWorkspaceSync: return .setWorkspaceSync(true)
        case .getSetting: return .getSetting("appearance.email-reading")
        case .setSetting: return .setSetting("appearance.email-reading", "dark")
        case .setSearchQuery: return .setSearchQuery("visible query")
        case .selectSearchResult: return .selectSearchResult(reference)
        case .openSearchResult: return .openSearchResult(reference)
        case .setSearchFieldFocused: return .setSearchFieldFocused(true)
        case .cancelSearch: return .cancelSearch
        case .setPairingPresented: return .setPairingPresented(true)
        case .pairingUI: return .pairingUI(.showCode)
        case .getSettings: return .getSettings
        }
    }
    private static func sampleCommands(named name: CommandName) throws -> [Command] {
        let primary = try sampleCommand(named: name)
        let localReference = MessageReference.local(messageID)
        let localTarget = MessageTarget.explicit([messageID])
        let selectionTarget = MessageTarget.selection(
            SelectionContext(revision: 7, folderID: folderID, messageIDs: [messageID])
        )
        switch name {
        case .selectFolder:
            return [primary, .selectFolder(nil)]
        case .list:
            return [primary, .list(nil, nil, 50, .newest)]
        case .setSetting:
            return [primary, .setSetting("appearance.email-reading", nil)]
        case .read:
            return [primary, .read(localReference)]
        case .raw:
            return [primary, .raw(localReference)]
        case .fetchAttachment:
            return [primary, .fetchAttachment(localReference, "1.2")]
        case .markRead:
            return [primary, .markRead(localTarget), .markRead(selectionTarget)]
        case .markUnread:
            return [primary, .markUnread(localTarget), .markUnread(selectionTarget)]
        case .setFlagged:
            return [primary, .setFlagged(localTarget, false), .setFlagged(selectionTarget, true)]
        case .archive:
            return [primary, .archive(localTarget), .archive(selectionTarget)]
        case .trash:
            return [primary, .trash(localTarget), .trash(selectionTarget)]
        case .move:
            return [primary, .move(localTarget, folderID), .move(selectionTarget, folderID)]
        case .selectMessages:
            return [
                primary,
                .selectMessages(localTarget, anchor: localReference),
                .selectMessages(selectionTarget, anchor: nil)
            ]
        case .openMessage:
            return [primary, .openMessage(localReference, permanent: false)]
        case .openWindow:
            return [primary, .openWindow(localReference)]
        case .selectSearchResult:
            return [primary, .selectSearchResult(localReference), .selectSearchResult(nil)]
        default:
            return [primary]
        }
    }
    private static func cliResultExample(
        command: CommandName?,
        result: SchemaJSON,
        stateRevision: Int? = nil
    ) -> SchemaJSON {
        var object: [String: SchemaJSON] = [
            "schema": .string("mailternal.cli.result.v1"),
            "version": .integer(1),
            "ok": .bool(true),
            "result": result
        ]
        if let command {
            object["command"] = .string(command.rawValue)
        }
        if let stateRevision {
            object["stateRevision"] = .integer(stateRevision)
        }
        return .object(object)
    }
    private static func cliResultEnvelopeSchema(resultSchemas: [SchemaJSON]) -> SchemaJSON {
        var uniqueResults: [SchemaJSON] = []
        for schema in resultSchemas where !uniqueResults.contains(schema) {
            uniqueResults.append(schema)
        }
        return .object([
            "type": .string("object"),
            "properties": .object([
                "schema": .object(["const": .string("mailternal.cli.result.v1")]),
                "version": .object(["const": .integer(1)]),
                "ok": .object(["const": .bool(true)]),
                "command": .object(["type": .string("string")]),
                "stateRevision": .object(["type": .string("integer")]),
                "result": .object(["anyOf": .array(uniqueResults)])
            ]),
            "required": .array([
                .string("schema"),
                .string("version"),
                .string("ok"),
                .string("result")
            ]),
            "additionalProperties": .bool(false)
        ])
    }

    private static func sampleRequest(includeOptionalValues: Bool = true) -> AutomationRequest {
        AutomationRequest(
            token: "token",
            origin: .localCLI,
            clientID: includeOptionalValues ? tabID.uuidString : nil,
            command: includeOptionalValues ? try? sampleCommand(named: .list) : nil,
            control: includeOptionalValues ? .engineStatus : nil,
            wantsState: true,
            wantsGUIState: true,
            observesState: true,
            afterRevision: includeOptionalValues ? 6 : nil,
            secret: includeOptionalValues ? "transient" : nil,
            pairingCode: includeOptionalValues ? "pairing-code" : nil,
            pairingClientName: includeOptionalValues ? "schema-client" : nil,
            pairingGrant: includeOptionalValues
                ? AutomationGrant(accountLinkIDs: [accountLink], canRead: true, canMutate: true, canSend: true, canControlGUI: true)
                : nil
        )
    }

    private static func sampleTransferRequest() -> AutomationRequest {
        AutomationRequest(
            token: "token",
            origin: .localCLI,
            control: .transferRead,
            transferID: tabID,
            transferOffset: 0,
            transferLength: AutomationTransferPolicy.chunkBytes
        )
    }

    private static func sampleResponse() -> AutomationResponse {
        AutomationResponse(requestID: tabID, ok: true, result: try? AutomationLineCodec.encode(sampleState()))
    }

    private static func sampleFailureResponse() -> AutomationResponse {
        AutomationResponse(requestID: tabID, ok: false, error: "permission denied", failure: .authorization)
    }

    private static func sampleState(includeOptionalValues: Bool = true) -> AppState {
        let folder = AutomationFolderState(
            id: folderID,
            accountID: accountID,
            name: "INBOX",
            path: "INBOX",
            role: .inbox,
            unreadCount: 1,
            totalCount: 2,
            keepLocally: true,
            activity: "idle"
        )
        let row = sampleRow(includeOptionalValues: includeOptionalValues)
        return AppState(
            accounts: [sampleAccount()],
            accountStates: [accountID: "active"],
            folders: [folder],
            selectedFolderID: includeOptionalValues ? folderID : nil,
            selectedMessageIDs: [messageID],
            selectedMessageID: includeOptionalValues ? messageID : nil,
            selectionRevision: 7,
            listRows: [row],
            listCursor: includeOptionalValues ? sampleCursor() : nil,
            activeListSort: .newest,
            readerTabs: [
                AutomationReaderTabState(
                    id: tabID,
                    messageID: messageID,
                    link: includeOptionalValues ? messageLink.formattedString : nil,
                    isTransient: false,
                    order: 0,
                    scrollOffset: 12
                )
            ],
            activeTabID: includeOptionalValues ? tabID : nil,
            focusedSurface: "message-list",
            visibleSearchQuery: includeOptionalValues ? "visible query" : nil,
            isSearchPresented: true,
            isFindPresented: true,
            findQuery: includeOptionalValues ? "find query" : nil,
            isRawSourcePresented: false,
            emailReadingMode: includeOptionalValues ? "original" : nil,
            allowRemoteImages: true,
            syncOnline: true,
            syncMode: "full-history",
            listConfiguration: MailListConfiguration(
                presentation: .columns,
                paneLayout: .sideBySide,
                columnOrder: MailListColumn.allCases,
                hiddenColumns: [.attachments],
                columnWidths: [.subject: 240],
                sort: .newest
            ),
            windows: [
                AutomationWindowState(
                    id: tabID,
                    kind: "main",
                    title: includeOptionalValues ? "Mailternal" : nil,
                    isVisible: true,
                    isKey: true,
                    focusedSurface: includeOptionalValues ? "message-list" : nil
                )
            ],
            dialogs: [
                AutomationDialogState(
                    id: "pairing",
                    kind: "pairing",
                    isPresented: false,
                    message: includeOptionalValues ? "Pairing is not shown" : nil
                )
            ],
            availableActions: [
                AutomationActionState(id: "mail.archive", isEnabled: true, requiresSelection: true, requiresGUI: false)
            ],
            settings: ["appearance.email-reading": "original"],
            searchResults: [row],
            isSearchLoading: false,
            searchError: includeOptionalValues ? "none" : nil,
            selectedSearchResultID: includeOptionalValues ? messageID : nil,
            searchFieldFocused: false
        )
    }

    // MARK: Shape inference

    private enum SchemaJSON: Codable, Equatable {
        case object([String: SchemaJSON])
        case array([SchemaJSON])
        case string(String)
        case integer(Int)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let object = try? value.decode([String: SchemaJSON].self) { self = .object(object) }
            else if let array = try? value.decode([SchemaJSON].self) { self = .array(array) }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let integer = try? value.decode(Int.self) { self = .integer(integer) }
            else if let number = try? value.decode(Double.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported JSON value") }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .object(let object): try value.encode(object)
            case .array(let array): try value.encode(array)
            case .string(let string): try value.encode(string)
            case .integer(let integer): try value.encode(integer)
            case .number(let number): try value.encode(number)
            case .bool(let bool): try value.encode(bool)
            case .null: try value.encodeNil()
            }
        }
    }
    private static func schemaKind(_ value: SchemaJSON) -> String {
        switch value {
        case .object: return "object"
        case .array: return "array"
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .bool: return "boolean"
        case .null: return "null"
        }
    }

    private static func encodedSchema<T: Encodable>(_ value: T) throws -> SchemaJSON {
        try inferredSchema(from: [value])
    }
    private static func encodedValue<T: Encodable>(_ value: T) throws -> SchemaJSON {
        try JSONDecoder().decode(SchemaJSON.self, from: AutomationLineCodec.encode(value))
    }

    private static func inferredSchema<T: Encodable>(from values: [T]) throws -> SchemaJSON {
        try inferredSchema(from: values.map { try AutomationLineCodec.encode($0) })
    }

    private static func inferredSchema(from data: [Data]) throws -> SchemaJSON {
        try inferredSchema(from: data.map { try JSONDecoder().decode(SchemaJSON.self, from: $0) })
    }

    private static func inferredSchema(from values: [SchemaJSON]) throws -> SchemaJSON {
        guard let first = values.first else {
            throw SchemaGenerationError.missingValue("root")
        }
        let kinds = Set(values.map(schemaKind))
        if kinds.count > 1 {
            var variants: [SchemaJSON] = []
            for value in values {
                let variant = try inferredSchema(from: [value])
                if !variants.contains(variant) { variants.append(variant) }
            }
            return .object(["oneOf": .array(variants)])
        }
        switch first {
        case .object:
            let objects = values.compactMap { if case .object(let value) = $0 { return value }; return nil }
            let keys = Set(objects.flatMap(\.keys)).sorted()
            var properties: [String: SchemaJSON] = [:]
            for key in keys {
                let values = objects.compactMap { $0[key] }
                guard !values.isEmpty else { throw SchemaGenerationError.missingValue(key) }
                properties[key] = try inferredSchema(from: values)
            }
            let required = keys.filter { key in objects.allSatisfy { $0[key] != nil } }
            var schema: [String: SchemaJSON] = [
                "type": .string("object"),
                "properties": .object(properties),
                "additionalProperties": .bool(false)
            ]
            if !required.isEmpty { schema["required"] = .array(required.map(SchemaJSON.string)) }
            return .object(schema)
        case .array:
            let arrays = values.compactMap { if case .array(let value) = $0 { return value }; return nil }
            let items = arrays.flatMap { $0 }
            var schema: [String: SchemaJSON] = ["type": .string("array")]
            if !items.isEmpty { schema["items"] = try inferredSchema(from: items) }
            return .object(schema)
        case .string: return primitiveSchema(values, type: "string")
        case .integer: return primitiveSchema(values, type: "integer")
        case .number: return primitiveSchema(values, type: "number")
        case .bool: return primitiveSchema(values, type: "boolean")
        case .null: return primitiveSchema(values, type: "null")
        }
    }

    private static func primitiveSchema(_ values: [SchemaJSON], type: String) -> SchemaJSON {
        let types = Set(values.map {
            switch $0 {
            case .string: return "string"
            case .integer: return "integer"
            case .number: return "number"
            case .bool: return "boolean"
            case .null: return "null"
            case .object: return "object"
            case .array: return "array"
            }
        }).sorted()
        if types.count == 1 { return .object(["type": .string(type)]) }
        return .object(["type": .array(types.map(SchemaJSON.string))])
    }

    private static func schemaValue(for value: AnyCodable) -> SchemaJSON {
        switch value {
        case .string(let value): return .string(value)
        case .bool(let value): return .bool(value)
        case .integer(let value): return .integer(value)
        case .double(let value): return .number(value)
        case .uuid(let value): return .string(value.uuidString.lowercased())
        case .accountID(let value): return .string(value.rawValue)
        case .folderID(let value): return .integer(Int(value.rawValue))
        case .messageID(let value): return .integer(Int(value.rawValue))
        case .data(let value): return .string(value.base64EncodedString())
        case .commandJSON(let value):
            var schema: [String: SchemaJSON] = [
                "type": .string("string"),
                "contentEncoding": .string("base64"),
                "contentMediaType": .string("application/json")
            ]
            if let nested = try? JSONDecoder().decode(SchemaJSON.self, from: value),
               let nestedSchema = try? inferredSchema(from: [nested]) {
                schema["contentSchema"] = nestedSchema
            }
            return .object(schema)
        case .null: return .null
        }
    }

    private static func payloadSchema(_ payloads: [[SchemaJSON]]) throws -> SchemaJSON {
        guard let first = payloads.first else {
            throw SchemaGenerationError.missingValue("command payload")
        }
        let count = first.count
        guard payloads.allSatisfy({ $0.count == count }) else {
            throw SchemaGenerationError.missingValue("inconsistent command payload")
        }
        var prefixItems: [SchemaJSON] = []
        for index in 0..<count {
            let values = payloads.map { $0[index] }
            let variants = try values.map { value -> SchemaJSON in
                if case .object(let object) = value,
                   object["contentEncoding"] != nil {
                    return value
                }
                return try inferredSchema(from: [value])
            }
            var unique: [SchemaJSON] = []
            for variant in variants where !unique.contains(variant) {
                unique.append(variant)
            }
            if unique.count == 1 {
                prefixItems.append(unique[0])
            } else {
                prefixItems.append(.object(["oneOf": .array(unique)]))
            }
        }
        return .object([
            "type": .string("array"),
            "prefixItems": .array(prefixItems),
            "minItems": .integer(count),
            "maxItems": .integer(count),
            "items": .bool(false)
        ])
    }

    private static func commandSchema(for name: CommandName) throws -> SchemaJSON {
        let commands = try sampleCommands(named: name)
        let payloads = commands.map { AnyCodable.payload(for: $0).map(schemaValue(for:)) }
        return .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["const": .string(name.rawValue)]),
                "payload": try payloadSchema(payloads)
            ]),
            "required": .array([.string("name"), .string("payload")]),
            "additionalProperties": .bool(false)
        ])
    }

    private static func resultSchema(for name: CommandName) throws -> SchemaJSON {
        let transfer = try encodedSchema(
            AutomationTransferDescriptor(
                kind: .commandResult,
                size: 1024,
                filename: nil,
                contentType: "application/json"
            )
        )
        let value: SchemaJSON
        switch name {
        case .list:
            let inline = try inferredSchema(from: [
                try AutomationLineCodec.encode(AutomationMessagePage(rows: [sampleRow()], next: sampleCursor())),
                try AutomationLineCodec.encode(AutomationMessagePage(rows: [sampleRow(includeOptionalValues: false)], next: nil))
            ])
            value = .object(["oneOf": .array([inline, transfer])])
        case .read:
            let envelope = Envelope(
                subject: "Schema subject",
                from: [MailAddress(displayName: "Sender", address: "sender@example.test")],
                to: [MailAddress(displayName: nil, address: "recipient@example.test")],
                cc: [MailAddress(displayName: nil, address: "copy@example.test")],
                replyTo: [MailAddress(displayName: nil, address: "reply@example.test")],
                internalDate: Date(timeIntervalSince1970: 1_700_000_000),
                headerDate: Date(timeIntervalSince1970: 1_700_000_100),
                rfcMessageID: "<schema@example.test>",
                inReplyTo: "<parent@example.test>",
                references: ["<parent@example.test>"]
            )
            let inline = try encodedSchema(
                MessageDetail(
                    id: messageID,
                    envelope: envelope,
                    bodyText: "Body",
                    sanitizedHTML: "<p>Body</p>",
                    hasRemoteImageReferences: true,
                    attachments: [
                        AttachmentInfo(
                            id: "1.2",
                            filename: "file.txt",
                            mimeType: "text/plain",
                            sizeEstimate: 4,
                            contentID: "cid:file",
                            transferEncoding: "base64"
                        )
                    ],
                    isQuarantined: false
                )
            )
            value = .object(["oneOf": .array([inline, transfer])])
        case .search:
            let inline = try inferredSchema(from: [
                try AutomationLineCodec.encode([sampleRow()]),
                try AutomationLineCodec.encode([sampleRow(includeOptionalValues: false)])
            ])
            value = .object(["oneOf": .array([inline, transfer])])
        case .exportAccounts:
            value = .object(["oneOf": .array([try encodedSchema(Data([1, 2, 3])), transfer])])
        case .raw:
            value = .object(["oneOf": .array([try encodedSchema("schema output"), transfer])])
        case .fetchAttachment:
            value = try encodedSchema(
                AutomationTransferDescriptor(
                    kind: .attachment,
                    size: 4,
                    filename: "file.txt",
                    contentType: "text/plain"
                )
            )
        case .getSetting:
            value = try inferredSchema(from: ["schema output", nil] as [String?])
        case .getSettings:
            value = try dictionarySchema(sample: "schema output")
        case .move:
            value = try encodedSchema(MoveOutput(movedCount: 2, skippedCrossAccountCount: 1))
        case .createDraft, .createReplyDraft, .createForwardDraft, .getDraft:
            value = try encodedSchema(sampleDraft())
        case .saveDraft:
            value = try encodedSchema(DraftSaveResult(saved: sampleDraft()))
        case .listDrafts:
            value = try encodedSchema([DraftSummary(
                id: draftID, accountID: accountID, revision: 2, subject: "Schema draft",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000), conflictOf: nil,
                attachmentCount: 0
            )])
        case .importDraftAttachment:
            value = try encodedSchema(DraftAttachment(
                id: tabID, filename: "file.txt", mimeType: "text/plain", byteCount: 4
            ))
        case .getDraftAttachment:
            value = try encodedSchema(AutomationTransferDescriptor(
                kind: .attachment, size: 4, filename: "file.txt", contentType: "text/plain"
            ))
        case .sendDraft, .retrySubmission, .cancelSubmission, .getSubmission:
            value = try encodedSchema(sampleOutbox())
        case .listOutbox:
            value = try encodedSchema([OutboxSummary(
                id: submissionID, accountID: accountID, draftID: draftID, draftRevision: 2,
                subject: "Schema draft", state: .queued, attemptCount: 0,
                nextAttemptAt: nil, acceptedAt: nil, failure: nil
            )])
        default:
            value = .object(["type": .string("null")])
        }
        return value
    }

    private static func dictionarySchema<Value: Encodable>(sample: Value) throws -> SchemaJSON {
        guard case .object(var schema) = try encodedSchema(["sample": sample]) else {
            throw SchemaGenerationError.missingValue("dictionary")
        }
        schema.removeValue(forKey: "properties")
        schema.removeValue(forKey: "required")
        schema["additionalProperties"] = try encodedSchema(sample)
        return .object(schema)
    }
    private static func cliGrammar(for name: CommandName) -> String {
        switch name {
        case .configureRemote: return "remote enable|disable <host> <port>"
        case .revokeAutomationClient: return "pair --revoke <client-uuid>"
        case .saveAccount: return "account add <AccountConfig.json>"
        case .configureSMTP: return "account smtp configure <account-id> --file <SMTPConfiguration.json> [--use-imap-password|--keep-password] | account smtp disable <account-id>"
        case .createDraft: return "draft create --account <account-id> --file <DraftContent.json>"
        case .createReplyDraft: return "draft reply <message-id|mailternal-link> [--all]"
        case .createForwardDraft: return "draft forward <message-id|mailternal-link>"
        case .saveDraft: return "draft save <draft-uuid> --revision <revision> --file <DraftContent.json>"
        case .deleteDraft: return "draft delete <draft-uuid> --revision <revision>"
        case .getDraft: return "draft get <draft-uuid>"
        case .listDrafts: return "draft list [--account <account-id>] [--limit <1...500>]"
        case .importDraftAttachment: return "draft attach <draft-uuid> --file <path|-> [--filename <name>] [--mime <type>]"
        case .getDraftAttachment: return "draft attachment <attachment-uuid> --account <account-id> (--output <path>|--stream)"
        case .sendDraft: return "draft send <draft-uuid> --revision <revision>"
        case .retrySubmission: return "outbox retry <submission-uuid> [--acknowledge-duplicate-risk]"
        case .cancelSubmission: return "outbox cancel <submission-uuid>"
        case .getSubmission: return "outbox get <submission-uuid>"
        case .listOutbox: return "outbox list [--account <account-id>] [--limit <1...500>]"
        case .removeAccount: return "account remove <account-id>"
        case .setAccountEnabled: return "account enable|disable <account-id>"
        case .exportAccounts: return "account export [<account-id> ...] [--settings]"
        case .importAccounts: return "account import <pairing-file> [<account-id> ...] [--replace] [--settings]"
        case .renameAccount: return "account rename <account-id> <name>"
        case .selectFolder: return "ui folder [<folder-id>]"
        case .renameFolder: return "folder rename <folder-id> <name>"
        case .setRetention: return "folder retention <folder-id> true|false"
        case .list: return "list [--folder <folder-id>] [--limit <1...500>] [--after <cursor>] [--sort <field:direction>]"
        case .read: return "read <message-id|mailternal-link>"
        case .raw: return "raw <message-id|mailternal-link>"
        case .fetchAttachment: return "fetch-attachment <message-id|mailternal-link> <part> --output <path> | fetch-attachment <message-id|mailternal-link> <part> --stream"
        case .search: return "search <query> [--limit <1...500>] [--follow [--after <revision>]]"
        case .markRead: return "mark <message-id[,message-id...]|mailternal-link[,mailternal-link...]> read | --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>] read"
        case .markUnread: return "mark <message-id[,message-id...]|mailternal-link[,mailternal-link...]> unread | --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>] unread"
        case .setFlagged: return "flag <message-id[,message-id...]|mailternal-link[,mailternal-link...]> [--off] | flag --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>] [--off]"
        case .archive: return "archive <message-id[,message-id...]|mailternal-link[,mailternal-link...]> | archive --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>]"
        case .trash: return "trash <message-id[,message-id...]|mailternal-link[,mailternal-link...]> | trash --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>]"
        case .move: return "move <message-id[,message-id...]|mailternal-link[,mailternal-link...]> --folder <folder-id> | move --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>] --folder <folder-id>"
        case .selectMessages: return "ui select <message-id[,message-id...]|mailternal-link[,mailternal-link...]> [--anchor <message-id|mailternal-link>] | ui select --selection-revision <revision> [--selection-folder <folder-id|none>] [--selection-ids <message-id[,message-id...]>] [--anchor <message-id|mailternal-link>]"
        case .selectAll: return "ui select-all"
        case .clearSelection: return "ui clear-selection"
        case .refresh: return "refresh"
        case .undo: return "undo"
        case .openMessage: return "ui open <message-id|mailternal-link>"
        case .openWindow: return "ui open-window <message-id|mailternal-link>"
        case .activateTab: return "ui activate-tab <tab-uuid>"
        case .closeTab: return "ui close-tab <tab-uuid>"
        case .closeOthers: return "ui close-others <tab-uuid>"
        case .closeToRight: return "ui close-to-right <tab-uuid>"
        case .keepTab: return "ui keep-tab <tab-uuid>"
        case .moveTab: return "ui move-tab <tab-uuid> <index>"
        case .nextTab: return "ui next-tab"
        case .previousTab: return "ui previous-tab"
        case .toggleSearch: return "ui search"
        case .toggleFind: return "ui find"
        case .setFindPresented: return "ui find-present true|false"
        case .setFindQuery: return "ui find-query <query>"
        case .toggleSidebar: return "ui sidebar"
        case .showSettings: return "ui settings"
        case .toggleRawSource: return "ui raw"
        case .setReadingMode: return "ui reading-mode original|dark"
        case .setRemoteImages: return "ui remote-images true|false"
        case .setListCustomizationTarget: return "ui list-target currentFolder|global"
        case .setListPaneLayout: return "ui pane-layout sideBySide|listAboveReader"
        case .setListPresentation: return "ui presentation cards|columns"
        case .setListColumnOrder: return "ui list-column-order <column,...>"
        case .setListColumnVisible: return "ui list-column-visible <column> true|false"
        case .setListColumnWidth: return "ui list-column-width <column> <width>"
        case .setListSort: return "ui list-sort <field:direction>"
        case .resetListSettings: return "ui reset-list [currentFolder]"
        case .resetGlobalListSettings: return "ui reset-list global"
        case .setWorkspaceSync: return "ui workspace-sync true|false"
        case .setWorkspaceSyncCategory: return "ui workspace-category <workspace|appearance|actions> true|false"
        case .resolveWorkspaceSyncConflict: return "ui workspace-resolve <workspace|appearance|actions> local|cloud"
        case .getSetting: return "settings get <key>"
        case .setSetting: return "settings set <key> [value]"
        case .setSearchQuery: return "ui search-query <query>"
        case .selectSearchResult: return "ui search-select [<message-id|mailternal-link>]"
        case .openSearchResult: return "ui search-open <message-id|mailternal-link>"
        case .setSearchFieldFocused: return "ui search-focus true|false"
        case .cancelSearch: return "ui cancel-search"
        case .setPairingPresented: return "ui pairing-present true|false"
        case .pairingUI: return "ui pairing-action <PairingUIAction.json>"
        case .getSettings: return "settings list"
        }
    }
}
