import Foundation
import MailternalInterfaces
import MailternalIMAP
import MailternalMIME
import MailternalStore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One account's outgoing queue drainer, owned by the same exclusive runtime as
/// its IMAP engine. The owner runs `run()` in a task and cancels that task before
/// replacing the worker. Enqueue/retry calls notify(); no periodic polling runs.
/// SMTP acceptance and Sent persistence are separate durable transitions.
public actor OutgoingDelivery {
    public typealias Credentials = @Sendable () async throws -> (configuration: SMTPConfiguration, password: String)
    public typealias SaveSentCopy = @Sendable (OutboxRecord, SMTPSubmission) async throws -> Void

    private let accountID: AccountID
    private let store: MailStore
    private let smtp: any SMTPSubmitting
    private let credentials: Credentials
    private let saveSentCopy: SaveSentCopy
    private let reportError: @Sendable (String) async -> Void
    private let events: AsyncStream<Void>
    private nonisolated let continuation: AsyncStream<Void>.Continuation
    private var running = false
    private var alarm: Task<Void, Never>?
    private var active: (id: UUID, task: Task<Void, Error>)?

    public init(
        accountID: AccountID,
        store: MailStore,
        smtp: any SMTPSubmitting,
        credentials: @escaping Credentials,
        saveSentCopy: @escaping SaveSentCopy,
        reportError: @escaping @Sendable (String) async -> Void
    ) {
        self.accountID = accountID
        self.store = store
        self.smtp = smtp
        self.credentials = credentials
        self.saveSentCopy = saveSentCopy
        self.reportError = reportError
        let stream = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    deinit {
        alarm?.cancel()
        active?.task.cancel()
        continuation.finish()
    }

    public nonisolated func notify() { continuation.yield(()) }

    /// Run only after the owner has acquired its runtime lease and called
    /// MailStore.recoverOutgoing once, before starting any outgoing workers.
    public func run() async throws {
        guard !running else { throw OutgoingMailError.invalidTransition }
        running = true
        defer {
            running = false
            alarm?.cancel()
            alarm = nil
        }
        notify()
        try await withTaskCancellationHandler(operation: {
            for await _ in events {
                try Task.checkCancellation()
                alarm?.cancel()
                alarm = nil
                do {
                    try await drain()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    await reportError(error.localizedDescription)
                    scheduleWake(at: Date().addingTimeInterval(30))
                }
            }
            try Task.checkCancellation()
        }, onCancel: {
            self.continuation.finish()
        })
    }

    /// Called through the owner's Command dispatcher. The persisted cancellation
    /// wins before stopping network work; cancellation cannot cross DATA commit.
    public func cancel(id: UUID) async throws -> OutboxRecord {
        guard let record = try await store.outbox(id: id), record.accountID == accountID else {
            throw OutgoingMailError.submissionNotFound
        }
        let result = try await store.cancelSubmission(id: id)
        if active?.id == id { active?.task.cancel() }
        notify()
        return result
    }

    /// Stops the worker's transport and wakeups. The owning runtime cancels
    /// and awaits the task running `run()` after calling this method, so no
    /// SMTP operation can outlive account reconfiguration or shutdown.
    public func stop() {
        alarm?.cancel()
        active?.task.cancel()
        continuation.finish()
    }

    private func drain() async throws {
        while !Task.isCancelled {
            let now = Date()
            if let copy = try await store.nextSentCopy(account: accountID, at: now) {
                try await perform(copy, copyOnly: true)
                continue
            }
            if let submission = try await store.claimNextSubmission(account: accountID, at: now) {
                try await perform(submission, copyOnly: false)
                continue
            }
            if let next = try await store.nextOutgoingAttempt(account: accountID) {
                scheduleWake(at: next)
            }
            return
        }
        throw CancellationError()
    }

    private func perform(_ record: OutboxRecord, copyOnly: Bool) async throws {
        let task = Task {
            if copyOnly { try await self.persistSentCopy(record) }
            else { try await self.submit(record) }
        }
        active = (record.id, task)
        defer { active = nil }
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func submit(_ record: OutboxRecord) async throws {
        guard let attemptID = record.attemptID else { throw OutgoingMailError.invalidTransition }
        do {
            try Task.checkCancellation()
            let credential = try await credentials()
            let submission = try await prepare(record)
            try await store.markSubmissionPrepared(
                id: record.id, attemptID: attemptID,
                envelope: submission.envelope, byteCount: submission.byteCount
            )
            let store = self.store
            let receipt = try await smtp.submit(
                submission, configuration: credential.configuration, password: credential.password,
                beforeCommit: {
                    try Task.checkCancellation()
                    try await store.markSubmissionCommitStarted(id: record.id, attemptID: attemptID)
                }
            )
            // A failure here must never return the message to automatic SMTP.
            // The already-durable commit marker protects even a disk failure.
            try await Task {
                try await store.markSubmissionAccepted(id: record.id, attemptID: attemptID, receipt: receipt)
            }.value
        } catch {
            // Cancellation stops transport, not the durable recording of its
            // outcome. A fresh task prevents GRDB from abandoning this write.
            let wasCancelled = Task.isCancelled
            try await Task {
                guard let current = try await store.outbox(id: record.id) else { throw error }
                if current.state == .cancelled { return }
                guard current.attemptID == attemptID else { throw error }
                var failure = deliveryFailure(error)
                if current.state == .awaitingAcceptance,
                   failure.replyCode.map({ (400...599).contains($0) }) != true {
                    failure = SMTPSubmissionError(kind: .deliveryUnknown, message: "Delivery status is unknown.")
                } else if current.state != .awaitingAcceptance, wasCancelled {
                    failure = SMTPSubmissionError(kind: .connection, message: "Delivery paused before submission.")
                } else if current.state != .awaitingAcceptance,
                          error as? OutgoingMailError == .invalidTransition,
                          try await store.fetchAccount(record.accountID)?.isEnabled != true {
                    failure = SMTPSubmissionError(kind: .connection, message: "Delivery paused because the account is unavailable.")
                }
                try await store.recordSubmissionFailure(
                    id: record.id, attemptID: attemptID, failure: failure,
                    retryAt: failure.isRetryable ? retryDate(attempt: record.attemptCount) : nil
                )
            }.value
        }
    }

    private func persistSentCopy(_ record: OutboxRecord) async throws {
        guard let attemptID = record.attemptID,
              let envelope = record.envelope, let byteCount = record.byteCount else {
            throw OutgoingMailError.invalidTransition
        }
        do {
            try Task.checkCancellation()
            let submission = SMTPSubmission(
                fileURL: store.submissionFileURL(id: record.id), byteCount: byteCount, envelope: envelope
            )
            try await saveSentCopy(record, submission)
            try await Task {
                try await store.markSentCopySaved(id: record.id, attemptID: attemptID)
            }.value
        } catch {
            let failure = sentCopyFailure(error)
            try await Task {
                try await store.recordSentCopyFailure(
                    id: record.id, attemptID: attemptID, failure: failure,
                    retryAt: Date().addingTimeInterval(30)
                )
            }.value
        }
    }

    private func prepare(_ record: OutboxRecord) async throws -> SMTPSubmission {
        var attachments: [MIMEComposition.Attachment] = []
        attachments.reserveCapacity(record.content.attachments.count)
        for attachment in record.content.attachments {
            try Task.checkCancellation()
            let url = try await store.draftAttachmentURL(id: attachment.id, accountID: accountID)
            attachments.append(.init(fileURL: url, filename: attachment.filename, mimeType: attachment.mimeType))
        }
        let content = record.content
        let composition = MIMEComposition(
            from: content.from, to: content.to, cc: content.cc, bcc: content.bcc, replyTo: content.replyTo,
            subject: content.subject, plainText: content.plainText, html: content.html,
            messageID: record.messageID, date: record.messageDate,
            inReplyTo: content.inReplyTo, references: content.references, attachments: attachments
        )
        let destination = store.submissionFileURL(id: record.id)
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try MIMEComposer.write(composition, to: staging)
        try Task.checkCancellation()
        // Only preparing attempts replace this file. An accepted message always
        // keeps its exact SMTP bytes for Sent-copy retries.
        let renamed = staging.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return Int32(-1) }
                return rename(source, target)
            }
        }
        guard renamed == 0 else { throw OutgoingMailError.invalidContent("The outgoing MIME file could not be committed.") }
        return SMTPSubmission(fileURL: destination, byteCount: result.byteCount, envelope: result.envelope)
    }

    private func deliveryFailure(_ error: Error) -> SMTPSubmissionError {
        if let failure = error as? SMTPSubmissionError { return failure }
        if error is CancellationError {
            return SMTPSubmissionError(kind: .cancelled, message: "Delivery paused before submission.")
        }
        if error is MIMECompositionError {
            return SMTPSubmissionError(kind: .message, message: "The message could not be prepared. Check its addresses, headers, and attachments.")
        }
        if let error = error as? OutgoingMailError {
            return SMTPSubmissionError(kind: .message, message: error.localizedDescription)
        }
        return SMTPSubmissionError(kind: .message, message: "The message could not be prepared. Check the account settings and available storage.")
    }

    /// Server diagnostics can echo authentication payloads. Persist the failure
    /// category, never an untrusted IMAP response or arbitrary callback error.
    private func sentCopyFailure(_ error: Error) -> SMTPSubmissionError {
        if let failure = error as? IMAPError {
            switch failure {
            case .auth:
                return SMTPSubmissionError(kind: .authentication, message: "The message was sent, but IMAP authentication failed while saving its Sent copy.")
            case .tls:
                return SMTPSubmissionError(kind: .tls, message: "The message was sent, but a secure IMAP connection could not be established for its Sent copy.")
            default:
                break
            }
        }
        return SMTPSubmissionError(kind: .connection, message: "The message was sent, but its Sent copy could not be saved.")
    }

    private func retryDate(attempt: Int) -> Date {
        Date().addingTimeInterval(min(300, 5 * pow(2, Double(min(max(attempt - 1, 0), 6)))))
    }

    private func scheduleWake(at date: Date) {
        alarm?.cancel()
        let continuation = self.continuation
        let delay = max(0.05, date.timeIntervalSinceNow)
        alarm = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
                continuation.yield(())
            } catch is CancellationError {
                // The owner stopped or an explicit queue change woke it sooner.
            } catch {
                continuation.yield(())
            }
        }
    }
}
