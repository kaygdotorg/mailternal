import XCTest
import MailternalInterfaces
import MailternalAutomation

final class ComposerSafetyTests: XCTestCase {
    @MainActor
    func testPostAdmissionFailureCannotSendAnEditedSecondCopy() async throws {
        let facade = MockMailFacade()
        let account = AccountConfig(
            id: AccountID(rawValue: "composer-safety"),
            accountLinkID: .random(),
            displayName: "Composer safety",
            emailAddress: "sender@example.test",
            username: "sender@example.test",
            imap: IMAPEndpoint(host: "imap.example.test", port: 993, security: .implicitTLS),
            smtp: SMTPConfiguration(host: "smtp.example.test", port: 465, security: .implicitTLS,
                                    username: "sender@example.test")
        )
        try await facade.addAccount(account, password: "test-password")
        let draft = try await facade.createDraft(
            id: UUID(), accountID: account.id,
            content: DraftContent(from: MailAddress(displayName: nil, address: account.emailAddress),
                                  to: [MailAddress(displayName: nil, address: "recipient@example.test")],
                                  subject: "Do not duplicate", plainText: "One submission")
        )
        var rejectsBeforeAdmission = true
        let controller = MailComposerController(facade: facade) { command, _ in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            switch command {
            case .getDraft(let id):
                return CommandResult(command: command.name, data: try encoder.encode(try await facade.draft(id: id)))
            case .saveDraft(let id, let revision, let content):
                let saved = try await facade.saveDraft(id: id, expectedRevision: revision, content: content)
                return CommandResult(command: command.name, data: try encoder.encode(saved))
            case .importDraftAttachment(let id, let account, let source, let filename, let mimeType):
                guard case .localFile(let url) = source else { throw MailAccountError("Expected local fixture") }
                let attachment = try await facade.importDraftAttachment(
                    id: id, accountID: account, sourceURL: url, filename: filename, mimeType: mimeType
                )
                return CommandResult(command: command.name, data: try encoder.encode(attachment))
            case .sendDraft(let id, let draftID, let revision):
                if rejectsBeforeAdmission { throw MailAccountError("Rejected before queue admission") }
                _ = try await facade.enqueueSubmission(id: id, draftID: draftID, expectedRevision: revision)
                // The effect succeeded; only its completion acknowledgement failed.
                throw CommandEffectAppliedError(commandID: UUID(), message: "Completion could not be persisted")
            default:
                throw MailAccountError("Unexpected command in composer safety scenario")
            }
        }
        await controller.openDraft(draft.id)
        let editor = try XCTUnwrap(controller.editor)
        editor.body = "Typed body retained across admission"
        let attachmentURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([7, 8, 9]).write(to: attachmentURL)
        defer { try? FileManager.default.removeItem(at: attachmentURL) }
        await editor.addAttachments([attachmentURL])
        await controller.send()
        XCTAssertNotNil(controller.editor, "A definitely unsent failure must retain editable content")
        XCTAssertTrue(editor.canSend, "A pre-effect failure must release the busy state for retry")
        let unadmitted = try await facade.outbox(accounts: nil, limit: 50)
        XCTAssertTrue(unadmitted.isEmpty)
        rejectsBeforeAdmission = false
        await controller.send()
        XCTAssertNil(controller.editor, "An uncertain accepted send must leave the editable send-again surface")
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(controller.returnsToLibrary)
        XCTAssertNotNil(controller.errorMessage)

        // This reproduces the dangerous follow-on action if the failed send left
        // an editor open: editing creates a new revision, bypassing same-revision
        // outbox idempotency, and a second Send would queue another message.
        controller.editor?.subject = "Edited after ambiguous acknowledgement"
        await controller.send()
        let submissions = try await facade.outbox(accounts: nil, limit: 50)
        XCTAssertEqual(submissions.count, 1)
        let submission = try await facade.outbox(id: XCTUnwrap(submissions.first).id)
        XCTAssertEqual(submission?.content.subject, "Do not duplicate")
        XCTAssertEqual(submission?.content.plainText, "Typed body retained across admission")
        XCTAssertEqual(submission?.content.attachments.count, 1)
        let savedAttachment = try XCTUnwrap(submission?.content.attachments.first)
        let savedURL = try await facade.draftAttachmentURL(id: savedAttachment.id, accountID: account.id)
        defer { try? FileManager.default.removeItem(at: savedURL) }
        XCTAssertEqual(try Data(contentsOf: savedURL), Data([7, 8, 9]))
    }
}
