import Foundation
import Testing
import MailternalAutomation
import MailternalInterfaces

struct CLIArgumentTests {
    @Test func trailingPositionalsAreUsageErrors() {
        for arguments in [
            ["read", "1", "unexpected"],
            ["fetch-attachment", "1", "2", "unexpected"],
            ["undo", "unexpected"]
        ] {
            do {
                _ = try AutomationCLI.parse(arguments)
                #expect(Bool(false), "Expected a usage error for \(arguments)")
            } catch let error as CLIParseError {
                guard case .usage(let message) = error else {
                    #expect(Bool(false), "Expected usage error for \(arguments)")
                    continue
                }
                #expect(!message.isEmpty)
            } catch {
                #expect(Bool(false), "Expected CLIParseError for \(arguments)")
            }
        }
    }

    @Test func localBatchTargetsRemainOneCommandTarget() throws {
        let invocation = try AutomationCLI.parse(["archive", "11,12,13"])
        guard case .command(.archive(.explicit(let ids))) = invocation else {
            #expect(Bool(false), "Expected one explicit batch target")
            return
        }
        #expect(ids == [MessageID(rawValue: 11), MessageID(rawValue: 12), MessageID(rawValue: 13)])
    }

    @Test func malformedAndMixedBatchTargetsAreRejected() {
        for raw in ["", "11,", ",11", "11,,12", "11,mailternal://open/v1/account/11111111-1111-4111-8111-111111111111/folder/path/bWFpbGJveA/message/9/12"] {
            do {
                _ = try AutomationCLI.parse(["trash", raw])
                #expect(Bool(false), "Expected a usage error for malformed target \(raw)")
            } catch CLIParseError.usage {
                // Expected parser boundary.
            } catch {
                #expect(Bool(false), "Expected usage error for malformed target \(raw)")
            }
        }
    }

    @Test func selectionTargetsCarryRevisionAndContextFields() throws {
        let invocation = try AutomationCLI.parse([
            "mark",
            "--selection-revision", "9",
            "--selection-folder", "42",
            "--selection-ids", "11,12",
            "read"
        ])
        guard case .command(.markRead(.selection(let context))) = invocation else {
            #expect(Bool(false), "Expected a revision-checked selection target")
            return
        }
        #expect(context == SelectionContext(
            revision: 9,
            folderID: FolderID(rawValue: 42),
            messageIDs: [MessageID(rawValue: 11), MessageID(rawValue: 12)]
        ))
    }

    @Test func draftAttachmentDownloadRequiresAnExclusiveDestinationOrStream() throws {
        let draftID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let accountID = AccountID(rawValue: "account-1")
        let output = try AutomationCLI.parse([
            "draft", "attachment", draftID.uuidString, "--account", accountID.rawValue,
            "--output", "/tmp/attachment.bin"
        ])
        #expect(output == .attachment(
            .getDraftAttachment(account: accountID, id: draftID),
            output: "/tmp/attachment.bin",
            stream: false
        ))

        let stream = try AutomationCLI.parse([
            "draft", "attachment", draftID.uuidString, "--account", accountID.rawValue, "--stream"
        ])
        #expect(stream == .attachment(
            .getDraftAttachment(account: accountID, id: draftID),
            output: nil,
            stream: true
        ))

        for arguments in [
            ["draft", "attachment", draftID.uuidString, "--account", accountID.rawValue],
            ["draft", "attachment", draftID.uuidString, "--account", accountID.rawValue,
             "--output", "/tmp/attachment.bin", "--stream"]
        ] {
            do {
                _ = try AutomationCLI.parse(arguments)
                #expect(Bool(false), "Expected a rejected download destination choice")
            } catch CLIParseError.usage {
                // Both absence and ambiguity are rejected at the parser boundary.
            } catch {
                #expect(Bool(false), "Expected a usage error for an invalid download choice")
            }
        }
    }

    @Test func stdinAttachmentRequiresAndPreservesFilename() throws {
        let draftID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        do {
            _ = try AutomationCLI.parse([
                "draft", "attach", draftID.uuidString, "--file", "-"
            ])
            #expect(Bool(false), "A stdin upload without a filename must be rejected")
        } catch CLIParseError.usage {
            // A stream has no path-derived filename.
        } catch {
            #expect(Bool(false), "Expected a usage error for an unnamed stdin upload")
        }

        let invocation = try AutomationCLI.parse([
            "draft", "attach", draftID.uuidString, "--file", "-",
            "--filename", "receipt.bin", "--mime", "application/octet-stream"
        ])
        #expect(invocation == .draftAttachment(
            draftID: draftID, path: "-", mimeType: "application/octet-stream", filename: "receipt.bin"
        ))
    }

    @Test func smtpCredentialReuseMustBeExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = AccountID(rawValue: "account-1")
        let config = SMTPConfiguration(
            host: "smtp.example.test", port: 465, security: .implicitTLS,
            username: "sender@example.test", credentialReference: "existing-smtp-key"
        )
        let path = root.appendingPathComponent("smtp.json")
        try JSONEncoder().encode(config).write(to: path)

        let transient = try AutomationCLI.parse([
            "account", "smtp", "configure", accountID.rawValue, "--file", path.path
        ])
        guard case .command(.configureSMTP(let parsedAccount, let parsedConfig, let hasPassword)) = transient else {
            #expect(Bool(false), "Expected SMTP configuration intent")
            return
        }
        #expect(parsedAccount == accountID)
        #expect(parsedConfig == config)
        #expect(hasPassword)

        let useIMAP = try AutomationCLI.parse([
            "account", "smtp", "configure", accountID.rawValue, "--file", path.path,
            "--use-imap-password"
        ])
        guard case .command(.configureSMTP(_, let imapConfig, let imapHasPassword)) = useIMAP else {
            #expect(Bool(false), "Expected explicit IMAP credential reuse intent")
            return
        }
        #expect(try #require(imapConfig).credentialReference == nil)
        #expect(!imapHasPassword)

        let keepSMTP = try AutomationCLI.parse([
            "account", "smtp", "configure", accountID.rawValue, "--file", path.path,
            "--keep-password"
        ])
        guard case .command(.configureSMTP(_, let keptConfig, let keptHasPassword)) = keepSMTP else {
            #expect(Bool(false), "Expected explicit existing SMTP credential reuse intent")
            return
        }
        #expect(try #require(keptConfig).credentialReference == config.credentialReference)
        #expect(!keptHasPassword)

        do {
            _ = try AutomationCLI.parse([
                "account", "smtp", "configure", accountID.rawValue, "--file", path.path,
                "--use-imap-password", "--keep-password"
            ])
            #expect(Bool(false), "Conflicting SMTP credential choices must be rejected")
        } catch CLIParseError.usage {
            // Conflicting credential reuse is a malformed user intent.
        } catch {
            #expect(Bool(false), "Expected a usage error for conflicting credential choices")
        }
    }


}
