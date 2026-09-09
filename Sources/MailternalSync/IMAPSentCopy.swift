import Foundation
import MailternalInterfaces
import MailternalIMAP

/// Saves only a message already accepted by SMTP. Each retry first searches the
/// actual Sent mailbox by the frozen Message-ID, so a lost APPEND acknowledgement
/// does not blindly append again. This module never performs SMTP submission.
public enum IMAPSentCopy {
    public static func save(
        _ record: OutboxRecord,
        submission: SMTPSubmission,
        account: AccountConfig,
        password: String
    ) async throws {
        guard record.accountID == account.id, account.isEnabled,
              record.state == .sentCopyPending, record.acceptedAt != nil else {
            throw OutgoingMailError.invalidTransition
        }
        let session = IMAPSession(endpoint: account.imap, username: account.username, password: password)
        try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                try await session.connect()
                let discovery = try await session.listFolders()
                let destination: String
                if let sent = discovery.folders.first(where: { $0.role == .sent }) {
                    destination = sent.path
                } else {
                    do {
                        try await session.createMailbox("Sent")
                        destination = "Sent"
                    } catch {
                        // Another client can create the mailbox after LIST.
                        // Only a fresh successful discovery permits continuing.
                        let refreshed = try await session.listFolders()
                        guard let sent = refreshed.folders.first(where: { $0.role == .sent }) else {
                            throw error
                        }
                        destination = sent.path
                    }
                }
                _ = try await session.select(destination)
                let exists = try await session.containsMessageID(record.messageID)
                if !exists {
                    try await session.append(
                        fileURL: submission.fileURL, byteCount: submission.byteCount,
                        to: destination, date: record.messageDate
                    )
                }
                await session.close()
            } catch {
                await session.close()
                throw error
            }
        }, onCancel: {
            Task { await session.close() }
        })
    }
}
