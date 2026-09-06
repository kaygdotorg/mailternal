import Foundation
import Observation
import MailternalInterfaces

/// Persists user intent before handing it to the runtime's durable mail queue.
/// Passwords exist only in the current execution task, never in this journal.
/// A running record found after restart is ambiguous, even for flags: replaying
/// an old read operation could undo a later unread operation.
@MainActor
@Observable
final class IOSCommandDispatcher {
    enum Command: Codable, Hashable, Sendable {
        case saveAccount(AccountConfig, requiresPassword: Bool)
        case setAccountEnabled(AccountID, Bool)
        case removeAccount(AccountID)
        case renameFolder(FolderID, String)
        case setRetention(FolderID, Bool)
        case markRead([MessageID])
        case markUnread([MessageID])
        case setFlagged([MessageID], Bool)
        case archive([MessageID])
        case trash([MessageID])
        case move([MessageID], FolderID)

        var requiresPassword: Bool {
            if case .saveAccount(_, let required) = self { return required }
            return false
        }

        var title: String {
            switch self {
            case .saveAccount(let account, _): "Save \(account.emailAddress)"
            case .setAccountEnabled(_, let enabled): enabled ? "Enable account" : "Disable account"
            case .removeAccount: "Remove account"
            case .renameFolder(_, let name): "Rename folder to \(name)"
            case .setRetention(_, let keep): keep ? "Keep mail locally" : "Remove local mail cache"
            case .markRead(let ids): "Mark \(ids.count) messages read"
            case .markUnread(let ids): "Mark \(ids.count) messages unread"
            case .setFlagged(let ids, let flagged): "\(flagged ? "Flag" : "Unflag") \(ids.count) messages"
            case .archive(let ids): "Archive \(ids.count) messages"
            case .trash(let ids): "Trash \(ids.count) messages"
            case .move(let ids, _): "Move \(ids.count) messages"
            }
        }
    }

    enum Status: String, Codable, Sendable {
        case pending, running, completed, failed, needsReview, discarded
    }

    struct Record: Codable, Hashable, Sendable, Identifiable {
        let id: UUID
        let createdAt: Date
        let command: Command
        var status: Status
        var errorDescription: String?
    }

    enum DispatchError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let message): message }
        }
    }

    private let facade: any MailFacade
    private let fileURL: URL
    private(set) var records: [Record] = []
    /// A non-nil error leaves the decoded records untouched and makes every
    /// later journal write fail closed; the shell must not continue as ready.
    private(set) var loadError: String?
    @ObservationIgnored private var executionTail: Task<MoveOutcome?, Error>?
    @ObservationIgnored private var tailID: UUID?

    init(facade: any MailFacade, fileURL: URL) {
        self.facade = facade
        self.fileURL = fileURL
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
    func resumeSafeCommands() async {
        guard loadError == nil else { return }
        let queued = records.filter { $0.status == .pending || $0.status == .running }
        for record in queued {
            do {
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

    }
    @discardableResult
    func submit(_ command: Command, secret: String? = nil) async throws -> MoveOutcome? {
        let record = Record(id: UUID(), createdAt: Date(), command: command, status: .pending, errorDescription: nil)
        records.append(record)
        do { try persist() }
        catch { records.removeLast(); throw error }
        return try await schedule(record, secret: secret)
    }

    @discardableResult
    func retry(_ id: UUID, secret: String? = nil) async throws -> MoveOutcome? {
        guard let record = records.first(where: { $0.id == id }),
              record.status == .failed || record.status == .needsReview else {
            throw DispatchError.unavailable("This action is not waiting for a retry.")
        }
        guard !record.command.requiresPassword || secret?.isEmpty == false else {
            throw DispatchError.unavailable("Enter the account password to retry.")
        }
        try transition(id, to: .pending)
        return try await schedule(record, secret: secret)
    }

    func discard(_ id: UUID) throws {
        guard let record = records.first(where: { $0.id == id }),
              record.status == .failed || record.status == .needsReview else { return }
        try transition(id, to: .discarded)
    }

    private func schedule(_ record: Record, secret: String?) async throws -> MoveOutcome? {
        let predecessor = executionTail
        let task = Task { @MainActor in
            _ = try? await predecessor?.value
            return try await self.execute(record, secret: secret)
        }
        executionTail = task
        tailID = record.id
        defer {
            if tailID == record.id { executionTail = nil; tailID = nil }
        }
        return try await task.value
    }

    private func execute(_ record: Record, secret: String?) async throws -> MoveOutcome? {
        try transition(record.id, to: .running)
        let outcome: MoveOutcome?
        do {
            switch record.command {
            case .saveAccount(let config, let requiresPassword):
                if requiresPassword {
                    guard let secret, !secret.isEmpty else {
                        throw DispatchError.unavailable("Enter the account password to retry.")
                    }
                    if facade.accounts.contains(where: { $0.id == config.id }) {
                        try await facade.updateAccount(config, password: secret)
                    } else {
                        try await facade.addAccount(config, password: secret)
                    }
                } else {
                    try await facade.updateAccount(config, password: nil)
                }
                outcome = nil
            case .setAccountEnabled(let id, let enabled):
                try await facade.setAccountEnabled(id, enabled)
                outcome = nil
            case .removeAccount(let id):
                try await facade.removeAccount(id)
                outcome = nil
            case .renameFolder(let id, let name):
                try await facade.renameFolder(id, to: name)
                outcome = nil
            case .setRetention(let id, let keep):
                try await facade.setKeepLocally(keep, for: id)
                outcome = nil
            case .markRead(let ids):
                try await facade.markRead(ids)
                outcome = nil
            case .markUnread(let ids):
                try await facade.markUnread(ids)
                outcome = nil
            case .setFlagged(let ids, let flagged):
                try await facade.setFlagged(ids, flagged)
                outcome = nil
            case .archive(let ids):
                try await facade.archive(ids)
                outcome = nil
            case .trash(let ids):
                try await facade.trash(ids)
                outcome = nil
            case .move(let ids, let folder):
                outcome = try await facade.move(ids, to: folder)
            }
        } catch {
            try transition(record.id, to: .failed, error: error.localizedDescription)
            throw error
        }
        // Completion means durable local enqueue, never server confirmation.
        try transition(record.id, to: .completed)
        return outcome
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
