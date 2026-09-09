import Foundation
import Observation
import UniformTypeIdentifiers
import MailternalInterfaces
import MailternalAutomation
import MailternalMIME

/// Both native editors use the same persisted Command path. The facade is used
/// only for read observations; mutations never bypass the supplied dispatcher.
@MainActor
@Observable
final class MailComposerController {
    typealias Execute = @MainActor (MailternalAutomation.Command, String?) async throws -> CommandResult

    @ObservationIgnored let facade: any MailFacade
    @ObservationIgnored let execute: Execute
    @ObservationIgnored private var observation: Task<Void, Never>?
    var editor: MailComposerModel?
    var isPresented = false
    var returnsToLibrary = false
    var isOpening = false
    var outgoing = OutgoingState()
    var errorMessage: String?

    init(facade: any MailFacade, execute: @escaping Execute) {
        self.facade = facade
        self.execute = execute
    }

    deinit { observation?.cancel() }

    func newMessage(account: AccountConfig) async {
        await open(command: .createDraft(
            id: UUID(), accountID: account.id,
            content: DraftContent(from: MailAddress(
                displayName: account.displayName.isEmpty ? nil : account.displayName,
                address: account.emailAddress
            ))
        ))
    }

    func newMessage(preferredAccountID: AccountID? = nil) async {
        guard let account = facade.accounts.first(where: { $0.id == preferredAccountID })
            ?? facade.accounts.first(where: { $0.isEnabled })
            ?? facade.accounts.first else {
            errorMessage = "Add an account before creating a message."
            return
        }
        await newMessage(account: account)
    }

    func reply(to message: MessageID, all: Bool) async {
        await open(command: .createReplyDraft(id: UUID(), .local(message), replyAll: all))
    }

    func forward(_ message: MessageID) async {
        await open(command: .createForwardDraft(id: UUID(), .local(message)))
    }

    func openDraft(_ id: UUID) async {
        await open(command: .getDraft(id))
    }

    func showLibrary() async {
        guard !isOpening, editor?.isBusy != true else { return }
        isOpening = true
        let previousEditor = editor
        previousEditor?.isBusy = true
        defer {
            previousEditor?.isBusy = false
            isOpening = false
        }
        if let editor {
            do {
                try await editor.flush()
            } catch is CommandEffectAppliedError {
                await showAmbiguousDraft(draftID: editor.draft.id)
                return
            } catch {
                editor.errorMessage = error.localizedDescription
                return
            }
        }
        editor = nil
        returnsToLibrary = true
        isPresented = true
        observe()
    }

    private func open(command: MailternalAutomation.Command) async {
        guard !isOpening, editor?.isBusy != true else { return }
        isOpening = true
        // Freeze the old editor until replacement completes. Otherwise text
        // entered while the next draft is loading can outlive its last save.
        let previousEditor = editor
        previousEditor?.isBusy = true
        defer {
            previousEditor?.isBusy = false
            isOpening = false
        }
        do {
            if let editor {
                do {
                    try await editor.flush()
                } catch is CommandEffectAppliedError {
                    await showAmbiguousDraft(draftID: editor.draft.id)
                    return
                }
            }
            let result = try await execute(command, nil)
            let draft: MailDraft
            do {
                draft = try decodeComposerResult(result)
            } catch {
                guard let draftID = Self.draftMutationID(for: command) else { throw error }
                throw CommandEffectAppliedError(
                    commandID: draftID,
                    message: "The draft was created, but its result could not be decoded. Reopen Drafts before editing or sending."
                )
            }
            editor = MailComposerModel(draft: draft, facade: facade, execute: execute)
            isPresented = true
            errorMessage = nil
            observe()
        } catch is CommandEffectAppliedError {
            if let draftID = Self.draftMutationID(for: command) {
                await showAmbiguousDraft(draftID: draftID)
            } else {
                errorMessage = "The draft result could not be confirmed. Review Drafts before trying again."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func draftMutationID(for command: MailternalAutomation.Command) -> UUID? {
        switch command {
        case .createDraft(let id, _, _),
             .createReplyDraft(let id, _, _),
             .createForwardDraft(let id, _),
             .saveDraft(let id, _, _),
             .deleteDraft(let id, _):
            return id
        default:
            return nil
        }
    }

    /// Observation begins only after a user opens a ready account's composer or
    /// outgoing library, never during facade construction or runtime election.
    private func observe() {
        guard observation == nil else { return }
        let stream = facade.observeOutgoing(accounts: nil, limit: 200)
        observation = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                outgoing = state
                if let editor,
                   let head = state.drafts.first(where: { $0.id == editor.draft.id }),
                   head.revision > editor.draft.revision {
                    editor.hasExternalChanges = true
                }
            }
        }
    }

    func closeEditor() async {
        guard !isOpening else { return }
        guard let editor else { isPresented = false; return }
        guard !editor.isBusy else { return }
        editor.isBusy = true
        defer { editor.isBusy = false }
        do {
            try await editor.flush()
            self.editor = nil
            if !returnsToLibrary { isPresented = false }
        } catch is CommandEffectAppliedError {
            await showAmbiguousDraft(draftID: editor.draft.id)
        } catch {
            editor.errorMessage = error.localizedDescription
        }
    }

    func send() async {
        guard let editor, !editor.isBusy, !editor.requiresReview else { return }
        editor.isBusy = true
        defer { editor.isBusy = false }
        let submissionID = UUID()
        do {
            do {
                try await editor.flush()
            } catch is CommandEffectAppliedError {
                await showAmbiguousDraft(draftID: editor.draft.id)
                return
            }
            do {
                _ = try await execute(.sendDraft(
                    id: submissionID, draftID: editor.draft.id, expectedRevision: editor.draft.revision
                ), nil)
                self.editor = nil
                // Queue admission is not delivery. Keep the outbox visible until
                // the runtime reports acceptance, failure, or Sent-copy progress.
                returnsToLibrary = true
                observe()
            } catch is CommandEffectAppliedError {
                await showAmbiguousSend(submissionID: submissionID)
            }
        } catch {
            editor.errorMessage = error.localizedDescription
        }
    }

    /// A post-effect failure cannot safely return to an editable draft: the
    /// original submission ID is the only safe handle for reviewing whether
    /// the durable outbox admission happened.
    private func showAmbiguousSend(submissionID: UUID) async {
        self.editor = nil
        returnsToLibrary = true
        isPresented = true
        observe()

        let id = submissionID.uuidString
        do {
            let submission = try await facade.outbox(id: submissionID)
            if submission != nil {
                errorMessage =
                    "Send request \(id) is in Outbox. Delivery is not confirmed; review it before retrying."
            } else {
                errorMessage =
                    "Send request \(id) may have been queued, but it is not currently visible in Outbox. Delivery status is uncertain; review before retrying."
            }
        } catch {
            errorMessage =
                "Could not verify send request \(id) after a post-effect failure. Delivery status is uncertain; review Outbox before retrying."
        }
    }
    /// A draft mutation may have committed even when its command completion
    /// failed. Freeze this editor and query the saved draft before exposing
    /// any further send/edit action.
    private func showAmbiguousDraft(draftID: UUID) async {
        self.editor = nil
        returnsToLibrary = true
        isPresented = true
        observe()

        let id = draftID.uuidString
        do {
            let draft = try await facade.draft(id: draftID)
            errorMessage = draft == nil
                ? "Draft \(id) may have changed, but it is not currently visible. Reopen Drafts before editing or sending."
                : "Draft \(id) was saved but its result could not be confirmed. Reopen it from Drafts before editing or sending."
        } catch {
            errorMessage =
                "Could not verify draft \(id) after a post-effect failure. Reopen Drafts before editing or sending."
        }
    }

    func discardEditor() async {
        guard let editor, !editor.isBusy else { return }
        editor.isBusy = true
        defer { editor.isBusy = false }
        do {
            do {
                try await editor.flush()
            } catch is CommandEffectAppliedError {
                await showAmbiguousDraft(draftID: editor.draft.id)
                return
            }
            _ = try await execute(.deleteDraft(
                id: editor.draft.id, expectedRevision: editor.draft.revision
            ), nil)
            self.editor = nil
        } catch is CommandEffectAppliedError {
            await showAmbiguousDraft(draftID: editor.draft.id)
        } catch {
            editor.errorMessage = error.localizedDescription
        }
    }

    func delete(_ draft: DraftSummary) async {
        do {
            _ = try await execute(.deleteDraft(id: draft.id, expectedRevision: draft.revision), nil)
        } catch is CommandEffectAppliedError {
            await showAmbiguousDraft(draftID: draft.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func showAmbiguousOutboxMutation(
        submissionID: UUID,
        action: String
    ) async {
        let id = submissionID.uuidString
        do {
            let submission = try await facade.outbox(id: submissionID)
            errorMessage = submission == nil
                ? "\(action) request \(id) may have been applied, but it is not currently visible in Outbox. Review before retrying."
                : "\(action) request \(id) may have been applied. Review its current Outbox state before retrying."
        } catch {
            errorMessage =
                "Could not verify \(action.lowercased()) request \(id). Review Outbox before retrying."
        }
    }

    func retry(_ submission: OutboxSummary, acknowledgeDuplicateRisk: Bool = false) async {
        do {
            _ = try await execute(.retrySubmission(
                submission.id, acknowledgeDuplicateRisk: acknowledgeDuplicateRisk
            ), nil)
        } catch is CommandEffectAppliedError {
            await showAmbiguousOutboxMutation(submissionID: submission.id, action: "Retry")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel(_ submission: OutboxSummary) async {
        do {
            _ = try await execute(.cancelSubmission(submission.id), nil)
        } catch is CommandEffectAppliedError {
            await showAmbiguousOutboxMutation(submissionID: submission.id, action: "Cancel")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Edits stay on screen while a save is in flight. Saves serialize through one
/// tail, and a stale server revision retains a fork instead of replacing either
/// editor value. Closing and sending await the latest complete saved value.
@MainActor
@Observable
final class MailComposerModel {
    private(set) var draft: MailDraft
    var toText: String { didSet { if oldValue != toText { changed() } } }
    var ccText: String { didSet { if oldValue != ccText { changed() } } }
    var bccText: String { didSet { if oldValue != bccText { changed() } } }
    var subject: String { didSet { if oldValue != subject { changed() } } }
    var body: String {
        didSet {
            if oldValue != body {
                html = nil
                changed()
            }
        }
    }
    private(set) var attachments: [DraftAttachment]
    var focusedField: String?
    var isBusy = false
    private(set) var isSaving = false
    /// A post-effect mutation failure freezes ordinary editing/retry until the
    /// authoritative draft is reopened from the library.
    private(set) var requiresReview = false
    var errorMessage: String?
    var conflictMessage: String?
    var hasExternalChanges = false
    @ObservationIgnored private var html: String?
    @ObservationIgnored private let facade: any MailFacade
    @ObservationIgnored private let execute: MailComposerController.Execute
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saveTail: Task<Void, Error>?
    private var editRevision: UInt64 = 0
    private var savedEditRevision: UInt64 = 0

    init(draft: MailDraft, facade: any MailFacade, execute: @escaping MailComposerController.Execute) {
        self.draft = draft
        self.facade = facade
        self.execute = execute
        toText = Self.addressText(draft.content.to)
        ccText = Self.addressText(draft.content.cc)
        bccText = Self.addressText(draft.content.bcc)
        subject = draft.content.subject
        body = draft.content.plainText
        html = draft.content.html
        attachments = draft.content.attachments
    }

    deinit { debounce?.cancel() }

    var isDirty: Bool { !requiresReview && editRevision != savedEditRevision }
    var account: AccountConfig? { facade.accounts.first { $0.id == draft.accountID } }
    var canSend: Bool {
        !requiresReview && !isBusy && account?.isEnabled == true && account?.smtp != nil
            && (toText.contains { !$0.isWhitespace }
                || ccText.contains { !$0.isWhitespace }
                || bccText.contains { !$0.isWhitespace })
    }
    var sendingUnavailableReason: String? {
        guard let account else { return "This account is no longer available. Your saved draft is retained." }
        if !account.isEnabled { return "Enable this account in Settings before sending." }
        if account.smtp == nil { return "Set up outgoing mail for this account in Settings before sending." }
        return nil
    }
    var saveStatus: String {
        if requiresReview { return "Review draft state" }
        if errorMessage != nil && isDirty { return "Not saved" }
        if isSaving || isDirty { return "Saving draft…" }
        return "Draft saved"
    }

    private func changed() {
        guard !requiresReview else { return }
        editRevision &+= 1
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard let self else { return }
            do { try await flush() }
            catch is CommandEffectAppliedError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func flush() async throws {
        guard !requiresReview else { return }
        debounce?.cancel()
        let previous = saveTail
        let operation = Task { @MainActor [weak self] in
            // A failed earlier edit must not poison a subsequent explicit save.
            // This operation reports its own durable write failure to its caller.
            _ = try? await previous?.value
            guard let self else { return }
            isSaving = true
            defer { isSaving = false }
            while isDirty {
                let editing = editRevision
                var content = draft.content
                content.to = MIMEParser.parseEditableAddresses(toText)
                content.cc = MIMEParser.parseEditableAddresses(ccText)
                content.bcc = MIMEParser.parseEditableAddresses(bccText)
                content.subject = subject
                content.plainText = body
                content.html = html
                content.attachments = attachments
                let response = try await execute(.saveDraft(
                    id: draft.id, expectedRevision: draft.revision, content: content
                ), nil)
                let result: DraftSaveResult
                do {
                    result = try decodeComposerResult(response)
                } catch {
                    throw CommandEffectAppliedError(
                        commandID: draft.id,
                        message: "The draft may have been saved, but its result could not be decoded. Reopen it before editing or sending."
                    )
                }
                draft = result.saved
                savedEditRevision = editing
                hasExternalChanges = false
                errorMessage = nil
                if result.conflictWith != nil {
                    conflictMessage = "This draft changed elsewhere. Both versions were saved; you are editing your copy."
                }
            }
        }
        saveTail = operation
        do {
            try await operation.value
        } catch let error as CommandEffectAppliedError {
            requiresReview = true
            errorMessage = "Draft save may have been applied, but its result could not be confirmed. Reopen the draft before editing or sending."
            throw error
        }
    }

    func addAttachments(_ urls: [URL]) async {
        guard !isBusy, !requiresReview else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
                let response = try await execute(.importDraftAttachment(
                    id: UUID(),
                    account: draft.accountID,
                    source: .localFile(url),
                    filename: url.lastPathComponent,
                    mimeType: type?.preferredMIMEType ?? "application/octet-stream"
                ), nil)
                let attachment: DraftAttachment
                do {
                    attachment = try decodeComposerResult(response)
                } catch {
                    throw CommandEffectAppliedError(
                        commandID: draft.id,
                        message: "The attachment may have been imported, but its result could not be decoded. Reopen the draft before editing or sending."
                    )
                }
                attachments.append(attachment)
                changed()
                try await flush()
            }
        } catch is CommandEffectAppliedError {
            requiresReview = true
            errorMessage = "Attachment import may have been applied, but its result could not be confirmed. Reopen the draft before editing or sending."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAttachment(_ attachment: DraftAttachment) {
        guard !isBusy, !requiresReview else { return }
        attachments.removeAll { $0.id == attachment.id }
        changed()
    }

    func attachmentURL(_ attachment: DraftAttachment) async throws -> URL {
        try await facade.draftAttachmentURL(id: attachment.id, accountID: draft.accountID)
    }

    private static func addressText(_ addresses: [MailAddress]) -> String {
        addresses.map { address in
            guard let name = address.displayName, !name.isEmpty else { return address.address }
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address.address)>"
        }.joined(separator: ", ")
    }
}

func decodeComposerResult<T: Decodable>(_ result: CommandResult) throws -> T {
    guard let data = result.data else { throw ComposerResultError.missingValue }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: data)
}

private enum ComposerResultError: Error, LocalizedError {
    case missingValue
    var errorDescription: String? { "Mailternal did not return the saved message. Keep this editor open and try again." }
}
