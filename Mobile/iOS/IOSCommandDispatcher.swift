import Foundation
import Observation
import MailternalInterfaces
import MailternalAutomation

/// Persists user intent before handing it to the runtime's durable mail queue.
/// Passwords exist only in the current execution task, never in this journal.
/// A running record found after restart is ambiguous, even for flags: replaying
/// an old read operation could undo a later unread operation.
@MainActor
@Observable
final class IOSCommandDispatcher {
    enum Status: String, Codable, Sendable {
        case pending, running, completed, failed, needsReview, discarded
    }

    struct Record: Codable, Hashable, Sendable, Identifiable {
        let id: UUID
        let createdAt: Date
        let command: MailternalAutomation.Command
        var status: Status
        var errorDescription: String?
        /// Pairing payloads are transient. This name keeps a pending action
        /// understandable after restart while the command itself is replaced
        /// with a payload-free marker in `encode(to:)`.
        let pairingActionName: String?
        let origin: CommandOrigin

        init(
            id: UUID,
            createdAt: Date,
            command: MailternalAutomation.Command,
            status: Status,
            errorDescription: String?,
            pairingActionName: String? = nil,
            origin: CommandOrigin = .iOS
        ) {
            self.id = id
            self.createdAt = createdAt
            self.command = command
            self.status = status
            self.errorDescription = errorDescription
            self.pairingActionName = pairingActionName
            self.origin = origin
        }

        /// The old iOS queue encoded a private enum with associated values.
        /// Decode that shape only as a compatibility bridge; new records use
        /// the shared `mailternal.command.v1` contract. An unknown or malformed
        /// entry throws so the dispatcher leaves the original file untouched
        /// instead of silently discarding pending work.
        private enum CodingKeys: String, CodingKey {
            case id, createdAt, command, status, errorDescription, pairingActionName, origin
        }

        private struct LegacyCodingKey: CodingKey {
            let stringValue: String
            let intValue: Int?

            init(stringValue: String) {
                self.stringValue = stringValue
                self.intValue = nil
            }

            init?(intValue: Int) {
                self.stringValue = String(intValue)
                self.intValue = intValue
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try container.decode(UUID.self, forKey: .id)
            let decodedOrigin = try container.decodeIfPresent(CommandOrigin.self, forKey: .origin) ?? .iOS
            let decodedCreatedAt = try container.decode(Date.self, forKey: .createdAt)
            let decodedStatus = try container.decode(Status.self, forKey: .status)
            let decodedError = try container.decodeIfPresent(String.self, forKey: .errorDescription)
            var decodedPairingActionName = try container.decodeIfPresent(
                String.self,
                forKey: .pairingActionName
            )
            let decodedCommand: MailternalAutomation.Command
            do {
                decodedCommand = try container.decode(
                    MailternalAutomation.Command.self,
                    forKey: .command
                )
            } catch {
                let legacy = try Self.decodeLegacyCommand(
                    from: container.superDecoder(forKey: .command)
                )
                decodedCommand = legacy.command
                // The old format has no pairing payload that can safely be
                // retained. Keep its action name for review, but never restore
                // the QR/passphrase/file data.
                if decodedPairingActionName == nil {
                    decodedPairingActionName = legacy.pairingActionName
                }
            }
            id = decodedID
            origin = decodedOrigin
            createdAt = decodedCreatedAt
            status = decodedStatus
            errorDescription = decodedError
            pairingActionName = decodedPairingActionName
            command = decodedCommand
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(origin, forKey: .origin)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(errorDescription, forKey: .errorDescription)
            if case .pairingUI(let action) = command {
                // The shared command is the in-memory execution contract, but
                // pairing actions may carry QR strings, bundles, or passphrases.
                // Persist only a marker plus its stable action name.
                try container.encode(
                    MailternalAutomation.Command.pairingUI(.showCode),
                    forKey: .command
                )
                try container.encode(
                    pairingActionName ?? action.name,
                    forKey: .pairingActionName
                )
            } else {
                try container.encode(command, forKey: .command)
                try container.encodeIfPresent(pairingActionName, forKey: .pairingActionName)
            }
        }

        private static func decodeLegacyCommand(
            from decoder: Decoder
        ) throws -> (command: MailternalAutomation.Command, pairingActionName: String?) {
            let wrapper = try decoder.container(keyedBy: LegacyCodingKey.self)
            guard let caseKey = wrapper.allKeys.first else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The legacy iOS command has no case."
                ))
            }
            let payloadDecoder = try wrapper.superDecoder(forKey: caseKey)
            let payload = try payloadDecoder.container(keyedBy: LegacyCodingKey.self)

            func decode<T: Decodable>(
                _ names: [String],
                as type: T.Type
            ) throws -> T {
                for name in names {
                    let key = LegacyCodingKey(stringValue: name)
                    if payload.contains(key) {
                        return try payload.decode(T.self, forKey: key)
                    }
                }
                throw DecodingError.keyNotFound(
                    LegacyCodingKey(stringValue: names[0]),
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "The legacy iOS command payload is incomplete."
                    )
                )
            }

            switch caseKey.stringValue {
            case "saveAccount":
                return (
                    .saveAccount(
                        try decode(["_0", "0"], as: AccountConfig.self),
                        hasPassword: try decode(
                            ["requiresPassword", "_1", "1"],
                            as: Bool.self
                        )
                    ),
                    nil
                )
            case "setAccountEnabled":
                return (
                    .setAccountEnabled(
                        try decode(["_0", "0"], as: AccountID.self),
                        try decode(["_1", "1"], as: Bool.self)
                    ),
                    nil
                )
            case "removeAccount":
                return (
                    .removeAccount(try decode(["_0", "0"], as: AccountID.self)),
                    nil
                )
            case "renameFolder":
                return (
                    .renameFolder(
                        try decode(["_0", "0"], as: FolderID.self),
                        try decode(["_1", "1"], as: String.self)
                    ),
                    nil
                )
            case "setRetention":
                return (
                    .setRetention(
                        try decode(["_0", "0"], as: FolderID.self),
                        try decode(["_1", "1"], as: Bool.self)
                    ),
                    nil
                )
            case "markRead":
                return (
                    .markRead(.explicit(try decode(["_0", "0"], as: [MessageID].self))),
                    nil
                )
            case "markUnread":
                return (
                    .markUnread(.explicit(try decode(["_0", "0"], as: [MessageID].self))),
                    nil
                )
            case "setFlagged":
                return (
                    .setFlagged(
                        .explicit(try decode(["_0", "0"], as: [MessageID].self)),
                        try decode(["_1", "1"], as: Bool.self)
                    ),
                    nil
                )
            case "archive":
                return (
                    .archive(.explicit(try decode(["_0", "0"], as: [MessageID].self))),
                    nil
                )
            case "trash":
                return (
                    .trash(.explicit(try decode(["_0", "0"], as: [MessageID].self))),
                    nil
                )
            case "move":
                return (
                    .move(
                        .explicit(try decode(["_0", "0"], as: [MessageID].self)),
                        try decode(["_1", "1"], as: FolderID.self)
                    ),
                    nil
                )
            case "pairing":
                return (
                    .pairingUI(.showCode),
                    try decode(["_0", "0"], as: String.self)
                )
            default:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "The legacy iOS command case is unsupported."
                ))
            }
        }

        var title: String {
            if let pairingActionName {
                return "Pairing action: \(pairingActionName)"
            }
            return command.title
        }
    }

    enum DispatchError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): message }
        }
    }

    private let facade: any MailFacade
    private let fileURL: URL
    @ObservationIgnored private var acceptsCommands = false
    private let automationJournal: CommandJournal
    private(set) var records: [Record] = []
    /// A non-nil error leaves the decoded records untouched and makes every
    /// later journal write fail closed; the shell must not continue as ready.
    private(set) var loadError: String?
    @ObservationIgnored private var executionTail: Task<CommandResult, Error>?
    @ObservationIgnored private var tailID: UUID?

    init(facade: any MailFacade, fileURL: URL) {
        self.facade = facade
        self.fileURL = fileURL
        self.automationJournal = CommandJournal(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("command-journal.json")
        )
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            records = try JSONDecoder.mailternal.decode([Record].self, from: Data(contentsOf: fileURL))
        } catch {
            // Never overwrite an unreadable journal with an empty one.
            loadError = "The command journal could not be opened: \(error.localizedDescription)"
        }
    }

    var pendingCount: Int {
        records.filter { $0.status == .pending || $0.status == .running }.count
    }

    var needsReviewCount: Int {
        records.filter { $0.status == .needsReview || $0.status == .failed }.count
    }

    /// Only work known not to have started can resume automatically. Failures
    /// stay inspectable and explicitly retryable in Settings → Pending Actions.
    /// Before resuming, orphaned iOS metadata records are terminalized as
    /// interrupted so a crash cannot leave shared pending/running history
    /// forever or cause an automatic replay of ambiguous work.
    func resumeSafeCommands() async {
        guard loadError == nil else { return }
        do {
            try await recoverInterruptedJournalRecords()
        } catch {
            loadError = error.localizedDescription
            return
        }
        let queued = records.filter { $0.status == .pending || $0.status == .running }
        for record in queued {
            do {
                if record.command.requiresLivePairing {
                    try transition(record.id, to: .needsReview, error: "Return to Pair Device to start a new action.")
                    continue
                }
                if record.status == .running || record.command.requiresPassword {
                    try transition(record.id, to: .needsReview, error: record.command.requiresPassword
                        ? "Enter the account password to retry."
                        : "Interrupted while submitting. Check the result before retrying.")
                } else {
                    _ = try await schedule(record, secret: nil)
                }
            } catch {
                // Execution failures transition the record to .failed and
                // remain retryable. A failed journal transition leaves the
                // original pending/running status in place, so fail closed
                // instead of allowing a later launch to overwrite it.
                if let status = records.first(where: { $0.id == record.id })?.status,
                   status == .pending || status == .running {
                    loadError = error.localizedDescription
                    return
                }
            }
        }
        acceptsCommands = true
    }
    private func recoverInterruptedJournalRecords() async throws {
        try await automationJournal.reload()
        let pending = try await automationJournal.pending()
        for record in pending where record.origin == .iOS || record.origin == .watch {
            try await automationJournal.fail(
                record.id,
                error: "Interrupted on iOS; the durable mail operation may still complete. Review before retrying."
            )
        }
    }

    @discardableResult
    func submit(
        _ command: MailternalAutomation.Command, secret: String? = nil,
        origin: CommandOrigin = .iOS
    ) async throws -> CommandResult {
        try await enqueue(command, secret: secret, pairing: nil, origin: origin)
    }

    /// Queues the shared command while persisting only its non-secret intent.
    /// The shared metadata journal is committed before the live bridge runs.
    func submitPairing(_ action: PairingUIAction, bridge: PairingAutomationBridge) async throws {
        _ = try await enqueue(
            .pairingUI(action),
            secret: nil,
            pairing: (.pairingUI(action), bridge)
        )
    }
    private func enqueue(
        _ command: MailternalAutomation.Command,
        secret: String?,
        pairing: (MailternalAutomation.Command, PairingAutomationBridge)?,
        origin: CommandOrigin = .iOS
    ) async throws -> CommandResult {
        guard acceptsCommands else {
            throw DispatchError.unavailable("Mail is still restoring on this device.")
        }
        guard command.isSupportedOnIOS else {
            throw DispatchError.unavailable("This command is not supported on iOS.")
        }
        let pairingActionName: String?
        if case .pairingUI(let action) = command {
            pairingActionName = action.name
        } else {
            pairingActionName = nil
        }
        let record = Record(
            id: UUID(),
            createdAt: Date(),
            command: command,
            status: .pending,
            errorDescription: nil,
            pairingActionName: pairingActionName,
            origin: origin
        )
        records.append(record)
        do { try persist() }
        catch { records.removeLast(); throw error }
        return try await schedule(record, secret: secret, pairing: pairing)
    }
    @discardableResult
    func retry(_ id: UUID, secret: String? = nil) async throws -> CommandResult {
        guard acceptsCommands else {
            throw DispatchError.unavailable("Mail is still restoring on this device.")
        }
        guard let record = records.first(where: { $0.id == id }),
              record.status == .failed else {
            throw DispatchError.unavailable("This action requires review before any retry.")
        }
        guard !record.command.requiresLivePairing else {
            throw DispatchError.unavailable("Return to Pair Device to start a new action.")
        }
        guard !record.command.requiresPassword || secret?.isEmpty == false else {
            throw DispatchError.unavailable("Enter the account password to retry.")
        }
        try transition(id, to: .pending)
        return try await schedule(record, secret: secret)
    }

    func discard(_ id: UUID) throws {
        guard acceptsCommands else {
            throw DispatchError.unavailable("Mail is still restoring on this device.")
        }
        guard let record = records.first(where: { $0.id == id }),
              record.status == .failed || record.status == .needsReview else { return }
        try transition(id, to: .discarded)
    }
    private func schedule(
        _ record: Record,
        secret: String?,
        pairing: (MailternalAutomation.Command, PairingAutomationBridge)? = nil
    ) async throws -> CommandResult {
        let predecessor = executionTail
        let task = Task { @MainActor in
            _ = try? await predecessor?.value
            return try await self.execute(record, secret: secret, pairing: pairing)
        }
        executionTail = task
        tailID = record.id
        defer {
            if tailID == record.id { executionTail = nil; tailID = nil }
        }
        return try await task.value
    }
    private func execute(
        _ record: Record,
        secret: String?,
        pairing: (MailternalAutomation.Command, PairingAutomationBridge)?
    ) async throws -> CommandResult {
        var auditID: UUID?
        do {
            // Mark the queue entry running before metadata work. If the
            // process stops between these durable steps, restart treats it as
            // ambiguous rather than replaying an operation that may have run.
            try transition(record.id, to: .running)
            // Metadata is intentionally derived from the command, never from
            // credentials, message bodies, search text, or pairing payloads.
            let audit = try await automationJournal.append(
                origin: record.origin,
                action: record.command.name.rawValue,
                targetIDs: record.command.journalTargetIDs
            )
            auditID = audit.id
            try await automationJournal.begin(audit.id)
        } catch {
            if let auditID {
                try? await automationJournal.fail(auditID, error: "iOS command could not be started.")
            }
            if records.first(where: { $0.id == record.id })?.status == .running {
                try? transition(
                    record.id,
                    to: .failed,
                    error: "iOS command could not be recorded."
                )
            }
            throw error
        }
        guard let auditID else {
            throw DispatchError.unavailable("The iOS command could not be recorded.")
        }

        var effectApplied = false
        func applyEffect<Value>(
            _ operation: () async throws -> Value
        ) async throws -> Value {
            let value = try await operation()
            effectApplied = true
            return value
        }
        func postEffectError(_ error: Error) -> CommandEffectAppliedError {
            if let error = error as? CommandEffectAppliedError {
                return error
            }
            return CommandEffectAppliedError(
                commandID: record.id,
                message: "The command effect may have been applied, but completion could not be recorded: \(error.localizedDescription)"
            )
        }

        let payload: Data?
        do {
            switch record.command {
            case .saveAccount(let config, let hasPassword):
                if hasPassword {
                    guard let secret, !secret.isEmpty else {
                        throw DispatchError.unavailable("Enter the account password to retry.")
                    }
                    if facade.accounts.contains(where: { $0.id == config.id }) {
                        try await applyEffect {
                            try await facade.updateAccount(config, password: secret)
                        }
                    } else {
                        try await applyEffect {
                            try await facade.addAccount(config, password: secret)
                        }
                    }
                } else {
                    try await applyEffect {
                        try await facade.updateAccount(config, password: nil)
                    }
                }
                payload = nil
            case .configureSMTP(let accountID, let configuration, let hasPassword):
                let password = hasPassword ? secret : nil
                guard !hasPassword || password?.isEmpty == false else {
                    throw DispatchError.unavailable("Enter the SMTP password to retry.")
                }
                try await applyEffect {
                    try await facade.configureSMTP(
                        accountID, configuration: configuration, password: password
                    )
                }
                payload = nil
            case .createDraft(let id, let accountID, let content):
                let draft = try await applyEffect {
                    try await facade.createDraft(id: id, accountID: accountID, content: content)
                }
                payload = try encodeAutomation(draft)
            case .createReplyDraft(let id, let reference, let replyAll):
                guard case .local(let messageID) = reference else {
                    throw DispatchError.unavailable("This iOS action requires a local message.")
                }
                let draft = try await applyEffect {
                    try await facade.createReplyDraft(id: id, messageID: messageID, replyAll: replyAll)
                }
                payload = try encodeAutomation(draft)
            case .createForwardDraft(let id, let reference):
                guard case .local(let messageID) = reference else {
                    throw DispatchError.unavailable("This iOS action requires a local message.")
                }
                let draft = try await applyEffect {
                    try await facade.createForwardDraft(id: id, messageID: messageID)
                }
                payload = try encodeAutomation(draft)
            case .saveDraft(let id, let expectedRevision, let content):
                let result = try await applyEffect {
                    try await facade.saveDraft(
                        id: id, expectedRevision: expectedRevision, content: content
                    )
                }
                payload = try encodeAutomation(result)
            case .deleteDraft(let id, let expectedRevision):
                try await applyEffect {
                    try await facade.deleteDraft(id: id, expectedRevision: expectedRevision)
                }
                payload = nil
            case .getDraft(let id):
                payload = try encodeAutomation(try await facade.draft(id: id))
            case .listDrafts(let accountID, let limit):
                payload = try encodeAutomation(
                    try await facade.drafts(
                        accounts: accountID.map { Set([$0]) }, limit: limit
                    )
                )
            case .importDraftAttachment(let id, let accountID, let source, let filename, let mimeType):
                guard case .localFile(let sourceURL) = source else {
                    throw DispatchError.unavailable("This iOS action requires a local attachment.")
                }
                let attachment = try await applyEffect {
                    try await facade.importDraftAttachment(
                        id: id,
                        accountID: accountID,
                        sourceURL: sourceURL,
                        filename: filename,
                        mimeType: mimeType
                    )
                }
                payload = try encodeAutomation(attachment)
            case .getDraftAttachment(let accountID, let id):
                payload = try encodeAutomation(
                    try await facade.draftAttachmentURL(id: id, accountID: accountID)
                )
            case .sendDraft(let id, let draftID, let expectedRevision):
                let submission = try await applyEffect {
                    try await facade.enqueueSubmission(
                        id: id, draftID: draftID, expectedRevision: expectedRevision
                    )
                }
                payload = try encodeAutomation(submission)
            case .retrySubmission(let id, let acknowledgeDuplicateRisk):
                let submission = try await applyEffect {
                    try await facade.retrySubmission(
                        id: id, acknowledgeDuplicateRisk: acknowledgeDuplicateRisk
                    )
                }
                payload = try encodeAutomation(submission)
            case .cancelSubmission(let id):
                let submission = try await applyEffect {
                    try await facade.cancelSubmission(id: id)
                }
                payload = try encodeAutomation(submission)
            case .getSubmission(let id):
                payload = try encodeAutomation(try await facade.outbox(id: id))
            case .listOutbox(let accountID, let limit):
                payload = try encodeAutomation(
                    try await facade.outbox(
                        accounts: accountID.map { Set([$0]) }, limit: limit
                    )
                )
            case .setAccountEnabled(let id, let enabled):
                try await applyEffect {
                    try await facade.setAccountEnabled(id, enabled)
                }
                payload = nil
            case .removeAccount(let id):
                try await applyEffect {
                    try await facade.removeAccount(id)
                }
                payload = nil
            case .renameFolder(let id, let name):
                try await applyEffect {
                    try await facade.renameFolder(id, to: name)
                }
                payload = nil
            case .setRetention(let id, let keep):
                try await applyEffect {
                    try await facade.setKeepLocally(keep, for: id)
                }
                payload = nil
            case .markRead(let target):
                try await applyEffect {
                    try await facade.markRead(try target.explicitIDsForIOS())
                }
                payload = nil
            case .markUnread(let target):
                try await applyEffect {
                    try await facade.markUnread(try target.explicitIDsForIOS())
                }
                payload = nil
            case .setFlagged(let target, let flagged):
                try await applyEffect {
                    try await facade.setFlagged(try target.explicitIDsForIOS(), flagged)
                }
                payload = nil
            case .archive(let target):
                try await applyEffect {
                    try await facade.archive(try target.explicitIDsForIOS())
                }
                payload = nil
            case .trash(let target):
                try await applyEffect {
                    try await facade.trash(try target.explicitIDsForIOS())
                }
                payload = nil
            case .move(let target, let folder):
                let outcome = try await applyEffect {
                    try await facade.move(try target.explicitIDsForIOS(), to: folder)
                }
                payload = try encodeAutomation(outcome)
            case .pairingUI(let action):
                guard let (command, bridge) = pairing,
                      case .pairingUI(let liveAction) = command,
                      liveAction == action else {
                    throw DispatchError.unavailable("Return to Pair Device to start a new action.")
                }
                try await applyEffect {
                    try await bridge.perform(action: action)
                }
                payload = nil
            default:
                throw DispatchError.unavailable("This command is not supported on iOS.")
            }
        } catch {
            guard effectApplied else {
                try? await automationJournal.fail(auditID, error: "iOS command failed.")
                try transition(
                    record.id,
                    to: .failed,
                    error: record.command.requiresLivePairing
                        ? "Pairing action failed. Return to Pair Device to continue."
                        : error.localizedDescription
                )
                throw error
            }
            let effectError = postEffectError(error)
            try? transition(record.id, to: .needsReview, error: effectError.message)
            throw effectError
        }

        // Completion means durable local enqueue, never server confirmation.
        // A completion failure after an applied effect leaves both metadata
        // records ambiguous so restart/review cannot offer a safe replay.
        do {
            try await automationJournal.complete(
                auditID,
                outcome: payload == nil ? "accepted" : "result"
            )
            try transition(record.id, to: .completed)
        } catch {
            guard effectApplied else {
                try? await automationJournal.fail(auditID, error: "iOS command completion failed.")
                try transition(record.id, to: .failed, error: error.localizedDescription)
                throw error
            }
            let effectError = postEffectError(error)
            try? transition(record.id, to: .needsReview, error: effectError.message)
            throw effectError
        }
        return CommandResult(command: record.command.name, data: payload)
    }

    private func encodeAutomation<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder.mailternal.encode(value)
    }
    private func transition(_ id: UUID, to status: Status, error: String? = nil) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw DispatchError.unavailable("The queued action is no longer available.")
        }
        let previous = records
        records[index].status = status
        records[index].errorDescription = error
        let terminal = records.filter { $0.status == .completed || $0.status == .discarded }
        if terminal.count > 200 {
            let obsolete = Set(terminal.prefix(terminal.count - 200).map(\.id))
            records.removeAll { obsolete.contains($0.id) }
        }
        do { try persist() }
        catch { records = previous; throw error }
    }

    private func persist() throws {
        if let loadError { throw DispatchError.unavailable(loadError) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.mailternal.encode(records).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

extension MailternalAutomation.Command {
    var isSupportedOnIOS: Bool {
        switch self {
        case .saveAccount, .configureSMTP, .createDraft, .createReplyDraft,
             .createForwardDraft, .saveDraft, .deleteDraft, .getDraft,
             .listDrafts, .importDraftAttachment, .getDraftAttachment,
             .sendDraft, .retrySubmission, .cancelSubmission, .getSubmission,
             .listOutbox, .setAccountEnabled, .removeAccount,
             .renameFolder, .setRetention, .markRead, .markUnread,
             .setFlagged, .archive, .trash, .move, .pairingUI:
            return true
        default:
            return false
        }
    }

    var requiresLivePairing: Bool {
        if case .pairingUI = self { return true }
        return false
    }

    var requiresPassword: Bool {
        switch self {
        case .saveAccount(_, let hasPassword), .configureSMTP(_, _, let hasPassword):
            return hasPassword
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .saveAccount(let account, _): "Save \(account.emailAddress)"
        case .setAccountEnabled(_, let enabled): enabled ? "Enable account" : "Disable account"
        case .removeAccount: "Remove account"
        case .renameFolder(_, let name): "Rename folder to \(name)"
        case .setRetention(_, let keep): keep ? "Keep mail locally" : "Remove local mail cache"
        case .markRead(let target): "Mark \(target.iosMessageCount) messages read"
        case .markUnread(let target): "Mark \(target.iosMessageCount) messages unread"
        case .setFlagged(let target, let flagged):
            "\(flagged ? "Flag" : "Unflag") \(target.iosMessageCount) messages"
        case .archive(let target): "Archive \(target.iosMessageCount) messages"
        case .configureSMTP: "Configure SMTP"
        case .createDraft: "Create draft"
        case .createReplyDraft: "Create reply draft"
        case .createForwardDraft: "Create forward draft"
        case .saveDraft: "Save draft"
        case .deleteDraft: "Delete draft"
        case .getDraft: "Open draft"
        case .listDrafts: "List drafts"
        case .importDraftAttachment: "Add draft attachment"
        case .getDraftAttachment: "Download draft attachment"
        case .sendDraft: "Queue draft for sending"
        case .retrySubmission: "Retry outgoing message"
        case .cancelSubmission: "Cancel outgoing message"
        case .getSubmission: "Open outgoing message"
        case .listOutbox: "List outgoing messages"
        case .trash(let target): "Trash \(target.iosMessageCount) messages"
        case .move(let target, _): "Move \(target.iosMessageCount) messages"
        case .pairingUI(let action): "Pairing action: \(action.name)"
        default: "Unsupported iOS command"
        }
    }

    var journalTargetIDs: [String] {
        var values: [String] = []
        var seen = Set<String>()
        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            values.append(value)
        }
        func appendAccount(_ id: AccountID) { append("account:\(id.rawValue)") }
        func appendFolder(_ id: FolderID) { append("folder:\(id.rawValue)") }
        func appendMessage(_ id: MessageID) { append("message:\(id.rawValue)") }
        func appendTarget(_ target: MessageTarget) {
            switch target {
            case .explicit(let ids):
                ids.forEach(appendMessage)
            case .links(let links):
                for link in links {
                    if let value = link.formattedString {
                        append("message:\(value)")
                    }
                }
            case .selection(let context):
                context.folderID.map(appendFolder)
                context.messageIDs.forEach(appendMessage)
            }
        }
        switch self {
        case .saveAccount(let config, _):
            appendAccount(config.id)
            append("account-link:\(config.accountLinkID.uuidString.lowercased())")
        case .configureSMTP(let accountID, _, _):
            appendAccount(accountID)
        case .createDraft(let id, let accountID, _):
            append("draft:\(id.uuidString.lowercased())")
            appendAccount(accountID)
        case .createReplyDraft(let id, let reference, _),
             .createForwardDraft(let id, let reference):
            append("draft:\(id.uuidString.lowercased())")
            if case .local(let messageID) = reference {
                appendMessage(messageID)
            } else if case .link(let link) = reference, let value = link.formattedString {
                append("message:\(value)")
            }
        case .saveDraft(let id, _, _), .deleteDraft(let id, _), .getDraft(let id):
            append("draft:\(id.uuidString.lowercased())")
        case .importDraftAttachment(let id, let accountID, let source, _, _):
            append("attachment:\(id.uuidString.lowercased())")
            appendAccount(accountID)
            if case .transfer(let id) = source {
                append("transfer:\(id.uuidString.lowercased())")
            }
        case .getDraftAttachment(let accountID, let id):
            appendAccount(accountID)
            append("attachment:\(id.uuidString.lowercased())")
        case .sendDraft(let id, let draftID, _):
            append("submission:\(id.uuidString.lowercased())")
            append("draft:\(draftID.uuidString.lowercased())")
        case .retrySubmission(let id, _), .cancelSubmission(let id), .getSubmission(let id):
            append("submission:\(id.uuidString.lowercased())")
        case .listOutbox(let accountID, _):
            accountID.map(appendAccount)
        case .removeAccount(let id), .setAccountEnabled(let id, _):
            appendAccount(id)
        case .renameFolder(let id, _), .setRetention(let id, _):
            appendFolder(id)
        case .markRead(let target), .markUnread(let target), .archive(let target),
             .trash(let target):
            appendTarget(target)
        case .setFlagged(let target, _):
            appendTarget(target)
        case .move(let target, let folder):
            appendTarget(target)
            appendFolder(folder)
        case .pairingUI(let action):
            append("pairing:\(action.name)")
            switch action {
            case .sendSelectedAccounts(let ids, _),
                 .setSelectedAccounts(let ids),
                 .confirmImport(let ids, _, _),
                 .exportOfflineBundle(let ids, _):
                ids.forEach(appendAccount)
            default:
                break
            }
        default:
            break
        }
        return values
    }
}

private extension MessageTarget {
    func explicitIDsForIOS() throws -> [MessageID] {
        guard case .explicit(let ids) = self else {
            throw IOSCommandDispatcher.DispatchError.unavailable(
                "This iOS action requires explicit message IDs."
            )
        }
        guard !ids.isEmpty else {
            throw IOSCommandDispatcher.DispatchError.unavailable(
                "This iOS action requires at least one message."
            )
        }
        return ids
    }

    var iosMessageCount: Int {
        switch self {
        case .explicit(let ids): ids.count
        case .links(let links): links.count
        case .selection(let context): context.messageIDs.count
        }
    }
}

private extension JSONEncoder {
    static var mailternal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var mailternal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
