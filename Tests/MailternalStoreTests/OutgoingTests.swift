import Foundation
import Testing
@testable import MailternalStore

private let outgoingTestEpoch = Date(timeIntervalSince1970: 1_700_100_000)
private let outgoingStagingExpiryEpoch: TimeInterval = 1_700_100_000 + (2 * 24 * 60 * 60)

private func outgoingContent(subject: String = "Subject", attachments: [DraftAttachment] = []) -> DraftContent {
    DraftContent(
        from: MailAddress(displayName: "Sender", address: "sender@example.com"),
        to: [MailAddress(displayName: "Recipient", address: "recipient@example.com")],
        subject: subject,
        plainText: "Body",
        attachments: attachments
    )
}

private func outgoingAccount(_ id: String, enabled: Bool = true) -> AccountConfig {
    var account = sampleAccount(id)
    account.accountLinkID = AccountLinkID(rawValue: UUID())
    account.isEnabled = enabled
    account.smtp = SMTPConfiguration(
        host: "smtp.example.com",
        port: 465,
        security: .implicitTLS,
        username: account.username
    )
    return account
}

@Test func staleCompleteDraftEditIsPreservedAsConflictFork() async throws {
    try await withStore { store, _ in
        let account = outgoingAccount("conflict")
        try await store.upsertAccount(account)
        let draftID = UUID()
        let initial = try await store.createDraft(
            id: draftID,
            accountID: account.id,
            content: outgoingContent(subject: "Initial"),
            at: outgoingTestEpoch
        )
        let current = try await store.saveDraft(
            id: draftID,
            expectedRevision: initial.revision,
            content: outgoingContent(subject: "Current"),
            at: outgoingTestEpoch.addingTimeInterval(1)
        ).saved
        var staleSnapshot = outgoingContent(subject: "Conflict")
        staleSnapshot.to = []
        let result = try await store.saveDraft(
            id: draftID,
            expectedRevision: initial.revision,
            content: staleSnapshot,
            at: outgoingTestEpoch.addingTimeInterval(2)
        )

        #expect(result.conflictWith == current)
        #expect(result.saved.conflictOf == draftID)
        #expect(result.saved.content.to.isEmpty)
        #expect(result.saved.content.subject == "Conflict")
        #expect(try await store.draft(id: draftID)?.content.subject == "Current")
        #expect(try await store.drafts(account: account.id, limit: 10).count == 2)
    }
}

@Test func enqueueIsIdempotentAndLateAttemptCannotAdvanceState() async throws {
    try await withStore { store, dir in
        let account = outgoingAccount("idempotent")
        try await store.upsertAccount(account)
        let draftID = UUID()
        let draft = try await store.createDraft(
            id: draftID,
            accountID: account.id,
            content: outgoingContent(),
            at: outgoingTestEpoch
        )
        let submissionID = UUID()
        let first = try await store.enqueueSubmission(
            id: submissionID,
            draftID: draftID,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch.addingTimeInterval(3)
        )
        let second = try await store.enqueueSubmission(
            id: submissionID,
            draftID: draftID,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch.addingTimeInterval(99)
        )
        #expect(first == second)
        let replay = try await store.enqueueSubmission(
            id: UUID(),
            draftID: draftID,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch.addingTimeInterval(100)
        )
        #expect(replay == first)

        let reopened = try MailStore(
            databaseURL: dir.appendingPathComponent("mail.sqlite"),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        )
        let firstClaim = try #require(await reopened.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        let firstAttempt = try #require(firstClaim.attemptID)
        try await reopened.recoverOutgoing(at: outgoingTestEpoch)
        let claimed = try #require(await reopened.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        let attempt = try #require(claimed.attemptID)
        #expect(attempt != firstAttempt)
        try Data(repeating: 0x41, count: 1).write(to: reopened.submissionFileURL(id: submissionID))
        let wrongAttempt = UUID()
        await #expect(throws: OutgoingMailError.invalidTransition) {
            try await reopened.markSubmissionPrepared(
                id: submissionID,
                attemptID: wrongAttempt,
                envelope: SMTPEnvelope(sender: "sender@example.com", recipients: ["recipient@example.com"], requiresSMTPUTF8: false),
                byteCount: 1
            )
        }
        try await reopened.markSubmissionPrepared(
            id: submissionID,
            attemptID: attempt,
            envelope: SMTPEnvelope(sender: "sender@example.com", recipients: ["recipient@example.com"], requiresSMTPUTF8: false),
            byteCount: 1
        )
        try await reopened.markSubmissionCommitStarted(id: submissionID, attemptID: attempt)
        await #expect(throws: OutgoingMailError.invalidTransition) {
            try await reopened.markSubmissionAccepted(
                id: submissionID,
                attemptID: wrongAttempt,
                receipt: SMTPSubmissionReceipt(acceptedAt: outgoingTestEpoch, replyCode: 250)
            )
        }
    }
}

@Test func disabledAccountCannotClaimOutgoingSubmission() async throws {
    try await withStore { store, _ in
        let account = outgoingAccount("disabled", enabled: false)
        try await store.upsertAccount(account)
        #expect(try await store.fetchAccount(account.id)?.smtp == account.smtp)
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(),
            at: outgoingTestEpoch
        )
        _ = try await store.enqueueSubmission(
            id: UUID(),
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch
        )
        #expect(try await store.claimNextSubmission(account: account.id, at: outgoingTestEpoch) == nil)
        #expect(try await store.claimNextSubmission(account: AccountID(rawValue: "missing"), at: outgoingTestEpoch) == nil)
        #expect(try await store.nextOutgoingAttempt(account: account.id) == nil)
        var enabled = account
        enabled.isEnabled = true
        try await store.upsertAccount(enabled)
        #expect(try await store.nextOutgoingAttempt(account: account.id) == Date(timeIntervalSince1970: 0))
    }
}

@Test func awaitingAcceptanceRecoveryBecomesUnknownUntilAcknowledged() async throws {
    try await withStore { store, _ in
        let account = outgoingAccount("unknown-recovery")
        try await store.upsertAccount(account)
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(),
            at: outgoingTestEpoch
        )
        let submissionID = UUID()
        _ = try await store.enqueueSubmission(
            id: submissionID,
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch
        )
        let claimed = try #require(await store.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        let attempt = try #require(claimed.attemptID)
        try Data(repeating: 0x41, count: 10).write(to: store.submissionFileURL(id: submissionID))
        try await store.markSubmissionPrepared(
            id: submissionID,
            attemptID: attempt,
            envelope: SMTPEnvelope(sender: "sender@example.com", recipients: ["recipient@example.com"], requiresSMTPUTF8: false),
            byteCount: 10
        )
        try await store.markSubmissionCommitStarted(id: submissionID, attemptID: attempt)
        try await store.recoverOutgoing(at: outgoingTestEpoch)
        let unknown = try #require(await store.outbox(id: submissionID))
        #expect(unknown.state == .deliveryUnknown)
        #expect(unknown.failure?.kind == .deliveryUnknown)
        await #expect(throws: OutgoingMailError.duplicateRiskRequiresAcknowledgement) {
            try await store.retrySubmission(id: submissionID, acknowledgeDuplicateRisk: false, at: outgoingTestEpoch)
        }
        let queued = try await store.retrySubmission(
            id: submissionID,
            acknowledgeDuplicateRisk: true,
            at: outgoingTestEpoch
        )
        #expect(queued.state == .queued)
        let retried = try #require(await store.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        #expect(retried.attemptID != attempt)
        #expect(retried.messageID == unknown.messageID)
    }
}

@Test func attachmentOwnershipAndExactMetadataAreEnforced() async throws {
    try await withStore { store, dir in
        let owner = outgoingAccount("attachment-owner")
        let other = outgoingAccount("attachment-other")
        try await store.upsertAccount(owner)
        try await store.upsertAccount(other)
        let source = dir.appendingPathComponent("source.bin")
        try Data(repeating: 0x5A, count: 131_073).write(to: source)
        let attachmentID = UUID()
        let attachment = try await store.importDraftAttachment(
            id: attachmentID,
            accountID: owner.id,
            sourceURL: source,
            filename: "report.bin",
            mimeType: "application/octet-stream"
        )
        let storedURL = try await store.draftAttachmentURL(id: attachment.id, accountID: owner.id)
        #expect(try Data(contentsOf: storedURL).count == 131_073)
        await #expect(throws: OutgoingMailError.attachmentNotFound) {
            try await store.draftAttachmentURL(id: attachment.id, accountID: other.id)
        }
        await #expect(throws: OutgoingMailError.invalidContent("Draft attachment metadata does not match its registered file.")) {
            try await store.createDraft(
                id: UUID(),
                accountID: owner.id,
                content: outgoingContent(
                    attachments: [DraftAttachment(id: attachment.id, filename: "wrong.bin", mimeType: attachment.mimeType, byteCount: attachment.byteCount)]
                ),
                at: outgoingTestEpoch
            )
        }
    }
}

@Test func attachmentImportUsesStableIDsAndNeverOverwritesCollisions() async throws {
    try await withStore { store, dir in
        let owner = outgoingAccount("stable-owner")
        let other = outgoingAccount("stable-other")
        try await store.upsertAccount(owner)
        try await store.upsertAccount(other)

        let firstSource = dir.appendingPathComponent("first.bin")
        let secondSource = dir.appendingPathComponent("second.bin")
        try Data([1, 2, 3]).write(to: firstSource)
        try Data([4, 5, 6, 7]).write(to: secondSource)
        let id = UUID()
        let first = try await store.importDraftAttachment(
            id: id,
            accountID: owner.id,
            sourceURL: firstSource,
            filename: "first.bin",
            mimeType: "application/octet-stream"
        )
        let retry = try await store.importDraftAttachment(
            id: id,
            accountID: owner.id,
            sourceURL: secondSource,
            filename: "changed.bin",
            mimeType: "application/x-changed"
        )
        #expect(retry == first)
        await #expect(throws: OutgoingMailError.invalidContent("An attachment identifier belongs to another account.")) {
            try await store.importDraftAttachment(
                id: id,
                accountID: other.id,
                sourceURL: secondSource,
                filename: "second.bin",
                mimeType: "application/octet-stream"
            )
        }

        let collisionID = UUID()
        let collisionPath = store.outgoingDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(collisionID.uuidString.lowercased())
        let original = Data([9, 8, 7])
        try original.write(to: collisionPath)
        var collisionFailed = false
        do {
            _ = try await store.importDraftAttachment(
                id: collisionID,
                accountID: owner.id,
                sourceURL: secondSource,
                filename: "collision.bin",
                mimeType: "application/octet-stream"
            )
        } catch {
            collisionFailed = true
        }
        #expect(collisionFailed)
        #expect(try Data(contentsOf: collisionPath) == original)
    }
}

@Test func expiredUnreferencedAttachmentIsReclaimed() async throws {
    try await withStore { store, dir in
        let account = outgoingAccount("expired-staging")
        try await store.upsertAccount(account)
        let source = dir.appendingPathComponent("expired.bin")
        try Data([1, 2, 3]).write(to: source)
        let attachment = try await store.importDraftAttachment(
            id: UUID(),
            accountID: account.id,
            sourceURL: source,
            filename: "expired.bin",
            mimeType: "application/octet-stream"
        )
        try await store.write { db in
            try db.execute(
                sql: "UPDATE draft_attachments SET unreferenced_at = ?, reclaiming_at = NULL WHERE id = ?",
                arguments: [0, attachment.id.uuidString.lowercased()]
            )
        }
        try await store.recoverOutgoing(at: Date(timeIntervalSince1970: outgoingStagingExpiryEpoch))
        await #expect(throws: OutgoingMailError.attachmentNotFound) {
            try await store.draftAttachmentURL(id: attachment.id, accountID: account.id)
        }
    }
}

@Test func removingLastDraftReferenceAllowsAttachmentReclamation() async throws {
    try await withStore { store, dir in
        let account = outgoingAccount("removed-reference")
        try await store.upsertAccount(account)
        let source = dir.appendingPathComponent("removed.bin")
        try Data([1, 2, 3]).write(to: source)
        let attachment = try await store.importDraftAttachment(
            id: UUID(),
            accountID: account.id,
            sourceURL: source,
            filename: "removed.bin",
            mimeType: "application/octet-stream"
        )
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(attachments: [attachment]),
            at: outgoingTestEpoch
        )
        try await store.deleteDraft(id: draft.id, expectedRevision: draft.revision)
        let removalTime = Date()
        try await store.recoverOutgoing(at: removalTime.addingTimeInterval(3600))
        let retainedURL = try await store.draftAttachmentURL(id: attachment.id, accountID: account.id)
        #expect(try Data(contentsOf: retainedURL) == Data([1, 2, 3]))
        try await store.recoverOutgoing(at: removalTime.addingTimeInterval(2 * 24 * 60 * 60))
        await #expect(throws: OutgoingMailError.attachmentNotFound) {
            try await store.draftAttachmentURL(id: attachment.id, accountID: account.id)
        }
    }
}

@Test func frozenOutboxAndConflictReferencesKeepAttachmentAlive() async throws {
    try await withStore { store, dir in
        let account = outgoingAccount("frozen-references")
        try await store.upsertAccount(account)
        let source = dir.appendingPathComponent("frozen.bin")
        try Data([1, 2, 3]).write(to: source)
        let attachment = try await store.importDraftAttachment(
            id: UUID(),
            accountID: account.id,
            sourceURL: source,
            filename: "frozen.bin",
            mimeType: "application/octet-stream"
        )
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(attachments: [attachment]),
            at: outgoingTestEpoch
        )
        _ = try await store.enqueueSubmission(
            id: UUID(),
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch
        )
        let updated = try await store.saveDraft(
            id: draft.id,
            expectedRevision: draft.revision,
            content: outgoingContent(),
            at: outgoingTestEpoch.addingTimeInterval(1)
        ).saved
        let conflict = try await store.saveDraft(
            id: draft.id,
            expectedRevision: draft.revision,
            content: outgoingContent(attachments: [attachment]),
            at: outgoingTestEpoch.addingTimeInterval(2)
        ).saved
        try await store.deleteDraft(id: draft.id, expectedRevision: updated.revision)
        try await store.deleteDraft(id: conflict.id, expectedRevision: conflict.revision)
        try await store.recoverOutgoing(at: Date(timeIntervalSince1970: outgoingStagingExpiryEpoch))
        #expect(try await store.draftAttachmentURL(id: attachment.id, accountID: account.id).lastPathComponent == attachment.id.uuidString.lowercased())
    }
}

@Test func stagingAdmissionCountsBytesBeforeCopy() async throws {
    try await withStore { store, dir in
        let account = outgoingAccount("staging-boundary")
        try await store.upsertAccount(account)
        let heldID = UUID()
        try await store.write { db in
            try db.execute(
                sql: """
                    INSERT INTO draft_attachments
                    (id, account_id, filename, mime_type, byte_count, created_at, unreferenced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    heldID.uuidString.lowercased(), account.id.rawValue, "held.bin",
                    "application/octet-stream", 1_073_741_824, Date().timeIntervalSince1970,
                    Date().timeIntervalSince1970
                ]
            )
        }
        let source = dir.appendingPathComponent("boundary.bin")
        try Data([1]).write(to: source)
        await #expect(throws: OutgoingMailError.invalidContent("The account attachment staging limit has been reached.")) {
            try await store.importDraftAttachment(
                id: UUID(),
                accountID: account.id,
                sourceURL: source,
                filename: "boundary.bin",
                mimeType: "application/octet-stream"
            )
        }
    }
}

@Test func sentCopyFailureIsCopyOnlyAndRetryNeverResendsSMTP() async throws {
    try await withStore { store, _ in
        let account = outgoingAccount("copy-only")
        try await store.upsertAccount(account)
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(),
            at: outgoingTestEpoch
        )
        let submissionID = UUID()
        _ = try await store.enqueueSubmission(
            id: submissionID,
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch
        )
        let claimed = try #require(await store.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        let attempt = try #require(claimed.attemptID)
        let envelope = SMTPEnvelope(sender: "sender@example.com", recipients: ["recipient@example.com"], requiresSMTPUTF8: false)
        try Data(repeating: 0x41, count: 10).write(to: store.submissionFileURL(id: submissionID))
        try await store.markSubmissionPrepared(id: submissionID, attemptID: attempt, envelope: envelope, byteCount: 10)
        try await store.markSubmissionCommitStarted(id: submissionID, attemptID: attempt)
        try await store.markSubmissionAccepted(
            id: submissionID,
            attemptID: attempt,
            receipt: SMTPSubmissionReceipt(acceptedAt: outgoingTestEpoch, replyCode: 250)
        )

        try await store.recordSentCopyFailure(
            id: submissionID,
            attemptID: attempt,
            failure: SMTPSubmissionError(kind: .connection, message: "Sent copy unavailable"),
            retryAt: outgoingTestEpoch.addingTimeInterval(60)
        )
        #expect(try await store.nextSentCopy(account: account.id, at: outgoingTestEpoch) == nil)
        let retry = try #require(await store.nextSentCopy(account: account.id, at: outgoingTestEpoch.addingTimeInterval(60)))
        #expect(retry.state == .sentCopyPending)
        #expect(retry.attemptID == attempt)
        let scheduled = try await store.retrySubmission(
            id: submissionID,
            acknowledgeDuplicateRisk: false,
            at: outgoingTestEpoch.addingTimeInterval(60)
        )
        #expect(scheduled.state == .sentCopyPending)
        #expect(scheduled.acceptedAt?.timeIntervalSince1970 == outgoingTestEpoch.timeIntervalSince1970)
        #expect(scheduled.attemptID == attempt)
        try await store.markSentCopySaved(id: submissionID, attemptID: attempt)
        #expect(try await store.outbox(id: submissionID)?.state == .sent)
        await #expect(throws: OutgoingMailError.invalidTransition) {
            try await store.markSubmissionAccepted(
                id: submissionID,
                attemptID: attempt,
                receipt: SMTPSubmissionReceipt(acceptedAt: outgoingTestEpoch, replyCode: 250)
            )
        }
    }
}

@Test func disablingAccountBetweenPreparationAndCommitPreventsCommit() async throws {
    try await withStore { store, _ in
        let account = outgoingAccount("disable-before-commit")
        try await store.upsertAccount(account)
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(),
            at: outgoingTestEpoch
        )
        let submissionID = UUID()
        _ = try await store.enqueueSubmission(
            id: submissionID,
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch
        )
        let claimed = try #require(await store.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        let attempt = try #require(claimed.attemptID)
        try Data(repeating: 0x41, count: 10).write(to: store.submissionFileURL(id: submissionID))
        try await store.markSubmissionPrepared(
            id: submissionID,
            attemptID: attempt,
            envelope: SMTPEnvelope(sender: "sender@example.com", recipients: ["recipient@example.com"], requiresSMTPUTF8: false),
            byteCount: 10
        )

        var disabled = account
        disabled.isEnabled = false
        try await store.upsertAccount(disabled)
        await #expect(throws: OutgoingMailError.invalidTransition) {
            try await store.markSubmissionCommitStarted(id: submissionID, attemptID: attempt)
        }
        #expect(try await store.outbox(id: submissionID)?.state == .sending)
    }
}

@Test func acceptedRevisionLeavesDraftHeadAvailableForLaterEdit() async throws {
    try await withStore { store, _ in
        let account = outgoingAccount("accepted-draft")
        try await store.upsertAccount(account)
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(subject: "Original"),
            at: outgoingTestEpoch
        )
        let submissionID = UUID()
        _ = try await store.enqueueSubmission(
            id: submissionID,
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch
        )
        let claimed = try #require(await store.claimNextSubmission(account: account.id, at: outgoingTestEpoch))
        let attempt = try #require(claimed.attemptID)
        try Data(repeating: 0x41, count: 10).write(to: store.submissionFileURL(id: submissionID))
        let envelope = SMTPEnvelope(sender: "sender@example.com", recipients: ["recipient@example.com"], requiresSMTPUTF8: false)
        try await store.markSubmissionPrepared(id: submissionID, attemptID: attempt, envelope: envelope, byteCount: 10)
        try await store.markSubmissionCommitStarted(id: submissionID, attemptID: attempt)
        try await store.markSubmissionAccepted(
            id: submissionID,
            attemptID: attempt,
            receipt: SMTPSubmissionReceipt(acceptedAt: outgoingTestEpoch, replyCode: 250)
        )

        #expect(try await store.drafts(account: account.id, limit: 10).isEmpty)
        #expect(try await store.hasUnsentOutgoing(account: account.id))
        try await store.markSentCopySaved(id: submissionID, attemptID: attempt)
        #expect(!(try await store.hasUnsentOutgoing(account: account.id)))

        let later = try await store.saveDraft(
            id: draft.id,
            expectedRevision: draft.revision,
            content: outgoingContent(subject: "Later"),
            at: outgoingTestEpoch.addingTimeInterval(1)
        ).saved
        let drafts = try await store.drafts(account: account.id, limit: 10)
        #expect(drafts.count == 1)
        #expect(drafts.first?.id == draft.id)
        #expect(drafts.first?.revision == later.revision)
        #expect(drafts.first?.subject == "Later")
    }
}

@Test func outgoingObservationPublishesBoundedBodyFreeTransitions() async throws {
    try await withStore(observationDebounce: .milliseconds(0)) { store, _ in
        let account = outgoingAccount("outgoing-observation")
        try await store.upsertAccount(account)
        let draft = try await store.createDraft(
            id: UUID(),
            accountID: account.id,
            content: outgoingContent(subject: "Observed"),
            at: outgoingTestEpoch
        )
        var iterator = store.observeOutgoing(account: account.id, limit: 10).makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.drafts.count == 1)
        #expect(initial.outbox.isEmpty)

        _ = try await store.enqueueSubmission(
            id: UUID(),
            draftID: draft.id,
            expectedRevision: draft.revision,
            at: outgoingTestEpoch.addingTimeInterval(1)
        )
        let queued = try #require(await iterator.next())
        #expect(queued.drafts.count == 1)
        #expect(queued.outbox.count == 1)
        #expect(queued.outbox.first?.subject == "Observed")
        let encoded = String(data: try JSONEncoder().encode(queued), encoding: .utf8) ?? ""
        #expect(!encoded.contains("plainText"))
        #expect(!encoded.contains("Body"))
    }
}
