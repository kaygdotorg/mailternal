import Foundation
import MailternalInterfaces
import Testing
@testable import MailternalAutomation

struct TransferRegistryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @Test func attachmentSurvivesCacheEvictionWithoutFollowingReplacementPath() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cached-attachment")
        let firstBytes = Data(repeating: 0x31, count: AutomationTransferPolicy.chunkBytes)
        let lastBytes = Data("last attachment chunk".utf8)
        try (firstBytes + lastBytes).write(to: source)
        let registry = AutomationTransferRegistry()
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        let descriptor = try await registry.create(fileURL: source, kind: .attachment, context: context)
        try FileManager.default.removeItem(at: source)
        try Data("replacement inode must not be read".utf8).write(to: source)
        let first = try await registry.read(
            transferID: descriptor.transferID, offset: 0, length: firstBytes.count, context: context
        )
        let last = try await registry.read(
            transferID: descriptor.transferID, offset: UInt64(firstBytes.count), length: lastBytes.count, context: context
        )
        #expect(first.data == firstBytes)
        #expect(!first.final)
        #expect(last.data == lastBytes)
        #expect(last.sequence == first.sequence + 1)
        #expect(last.final)
        #expect(try Data(contentsOf: source) == Data("replacement inode must not be read".utf8))
    }

    @Test func readsRequireCurrentOwnerAndAccountGrantButRevokedOwnerCanCancel() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let account = AccountLinkID(rawValue: UUID())
        let owner = UUID()
        let grant = AutomationGrant(accountLinkIDs: [account], canRead: true)
        let context = AutomationClientContext(origin: .pairedRemote, grant: grant, clientID: owner)
        let descriptor = try await registry.create(data: Data("private bytes".utf8), kind: .commandResult, context: context)
        let stranger = AutomationClientContext(origin: .pairedRemote, grant: grant, clientID: UUID())
        await #expect(throws: AutomationCommandError.permissionDenied(.read)) {
            try await registry.read(transferID: descriptor.transferID, offset: 0, length: 1, context: stranger)
        }
        let unscoped = AutomationClientContext(
            origin: .pairedRemote, grant: AutomationGrant(canRead: true), clientID: owner
        )
        await #expect(throws: AutomationCommandError.permissionDenied(.read)) {
            try await registry.read(transferID: descriptor.transferID, offset: 0, length: 1, context: unscoped)
        }
        let first = try await registry.read(transferID: descriptor.transferID, offset: 0, length: 7, context: context)
        #expect(first.data == Data("private".utf8))
        let revoked = AutomationClientContext(origin: .pairedRemote, grant: AutomationGrant(), clientID: owner)
        await #expect(throws: AutomationCommandError.permissionDenied(.read)) {
            try await registry.read(transferID: descriptor.transferID, offset: 7, length: 1, context: revoked)
        }
        try await registry.cancel(transferID: descriptor.transferID, context: revoked)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func invalidOwnerSequenceReleasesPrivateSpool() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        let descriptor = try await registry.create(data: Data("payload".utf8), kind: .commandResult, context: context)
        await #expect(throws: AutomationCommandError.self) {
            try await registry.read(transferID: descriptor.transferID, offset: 1, length: 1, context: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: AutomationCommandError.self) {
            try await registry.read(transferID: descriptor.transferID, offset: 0, length: 1, context: context)
        }
    }

    @Test func idleExpiryRemovesPrivateSpoolWithoutAnotherRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .milliseconds(200), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        _ = try await registry.create(data: Data("private mail".utf8), kind: .commandResult, context: context)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await registry.shutdown()
    }

    @Test func finishingEmptyTransferReleasesCapacityAndShutdownClosesAdmission() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        var descriptors: [AutomationTransferDescriptor] = []
        for _ in 0..<16 {
            descriptors.append(try await registry.create(data: Data(), kind: .commandResult, context: context))
        }
        await #expect(throws: AutomationCommandError.self) {
            try await registry.create(data: Data(), kind: .commandResult, context: context)
        }
        let empty = try await registry.read(transferID: descriptors[0].transferID, offset: 0, length: 0, context: context)
        #expect(empty.final && empty.data.isEmpty)
        let replacement = try await registry.create(data: Data([0x61]), kind: .commandResult, context: context)
        let chunk = try await registry.read(transferID: replacement.transferID, offset: 0, length: 1, context: context)
        #expect(chunk.data == Data([0x61]))
        await registry.shutdown()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: AutomationCommandError.appUnavailable) {
            try await registry.create(data: Data(), kind: .commandResult, context: context)
        }
    }
    @Test func clientUploadWritesBinaryChunksToPrivateSpool() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        let first = Data(repeating: 0xA5, count: AutomationTransferPolicy.chunkBytes)
        let second = Data([0x00, 0xFF, 0x7E, 0x10])
        let descriptor = try await registry.createUpload(
            size: UInt64(first.count + second.count),
            filename: "binary.dat",
            contentType: "application/octet-stream",
            context: context
        )
        let spool = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: spool.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try await registry.write(
            transferID: descriptor.transferID, sequence: 0, offset: 0,
            totalBytes: descriptor.size, data: first, final: false, context: context
        )
        try await registry.write(
            transferID: descriptor.transferID, sequence: 1, offset: UInt64(first.count),
            totalBytes: descriptor.size, data: second, final: true, context: context
        )
        let finalized = try await registry.finalizeUpload(
            transferID: descriptor.transferID, context: context
        )
        #expect(try Data(contentsOf: finalized) == first + second)

        try await registry.release(transferID: descriptor.transferID, context: context)
        #expect(!FileManager.default.fileExists(atPath: finalized.path))
    }

    @Test func incompleteUploadCannotBeFinalizedOrReadAsDownload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        let descriptor = try await registry.createUpload(
            size: 2, filename: "partial.bin", contentType: "application/octet-stream", context: context
        )
        try await registry.write(
            transferID: descriptor.transferID, sequence: 0, offset: 0,
            totalBytes: descriptor.size, data: Data([0x01]), final: false, context: context
        )

        await #expect(throws: AutomationCommandError.self) {
            try await registry.finalizeUpload(transferID: descriptor.transferID, context: context)
        }
        await #expect(throws: AutomationCommandError.self) {
            try await registry.read(transferID: descriptor.transferID, offset: 0, length: 1, context: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func anotherPairedOwnerCannotOverwriteCancelOrFinalizeUpload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let account = AccountLinkID(rawValue: UUID())
        let grant = AutomationGrant(accountLinkIDs: [account], canRead: true, canMutate: true)
        let owner = AutomationClientContext(origin: .pairedRemote, grant: grant, clientID: UUID())
        let other = AutomationClientContext(origin: .pairedRemote, grant: grant, clientID: UUID())
        let incomplete = try await registry.createUpload(
            size: 1, filename: "partial.bin", contentType: "application/octet-stream", context: owner
        )
        let complete = try await registry.createUpload(
            size: 1, filename: "complete.bin", contentType: "application/octet-stream", context: owner
        )
        try await registry.write(
            transferID: complete.transferID, sequence: 0, offset: 0,
            totalBytes: complete.size, data: Data([0x42]), final: true, context: owner
        )

        await #expect(throws: AutomationCommandError.self) {
            try await registry.write(
                transferID: incomplete.transferID, sequence: 0, offset: 0,
                totalBytes: incomplete.size, data: Data([0x99]), final: true, context: other
            )
        }
        await #expect(throws: AutomationCommandError.self) {
            try await registry.cancel(transferID: incomplete.transferID, context: other)
        }
        await #expect(throws: AutomationCommandError.self) {
            try await registry.finalizeUpload(transferID: complete.transferID, context: other)
        }

        try await registry.cancel(transferID: incomplete.transferID, context: owner)
        try await registry.release(transferID: complete.transferID, context: owner)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func revokedAccountOrMutationGrantBlocksContinuationButOwnerMayCancel() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let account = AccountLinkID(rawValue: UUID())
        let ownerID = UUID()
        let grant = AutomationGrant(accountLinkIDs: [account], canRead: true, canMutate: true)
        let owner = AutomationClientContext(origin: .pairedRemote, grant: grant, clientID: ownerID)
        let revokedAccount = AutomationClientContext(
            origin: .pairedRemote,
            grant: AutomationGrant(canRead: true, canMutate: true),
            clientID: ownerID
        )
        let revokedMutation = AutomationClientContext(
            origin: .pairedRemote,
            grant: AutomationGrant(accountLinkIDs: [account], canRead: true),
            clientID: ownerID
        )

        let accountTransfer = try await registry.createUpload(
            size: 1, filename: "account.bin", contentType: "application/octet-stream", context: owner
        )
        await #expect(throws: AutomationCommandError.self) {
            try await registry.write(
                transferID: accountTransfer.transferID, sequence: 0, offset: 0,
                totalBytes: accountTransfer.size, data: Data([0x01]), final: true, context: revokedAccount
            )
        }
        let mutationTransfer = try await registry.createUpload(
            size: 1, filename: "mutation.bin", contentType: "application/octet-stream", context: owner
        )
        await #expect(throws: AutomationCommandError.self) {
            try await registry.write(
                transferID: mutationTransfer.transferID, sequence: 0, offset: 0,
                totalBytes: mutationTransfer.size, data: Data([0x02]), final: true, context: revokedMutation
            )
        }
        let cancelable = try await registry.createUpload(
            size: 1, filename: "cancel.bin", contentType: "application/octet-stream", context: owner
        )
        try await registry.cancel(transferID: cancelable.transferID, context: revokedMutation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func invalidUploadSequenceOffsetOrFinalFlagReleasesOwnedSpool() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)

        let badSequence = try await registry.createUpload(
            size: 1, filename: "sequence.bin", contentType: "application/octet-stream", context: context
        )
        await #expect(throws: AutomationCommandError.self) {
            try await registry.write(
                transferID: badSequence.transferID, sequence: 1, offset: 0,
                totalBytes: badSequence.size, data: Data([0x01]), final: true, context: context
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let badOffset = try await registry.createUpload(
            size: 1, filename: "offset.bin", contentType: "application/octet-stream", context: context
        )
        await #expect(throws: AutomationCommandError.self) {
            try await registry.write(
                transferID: badOffset.transferID, sequence: 0, offset: 1,
                totalBytes: badOffset.size, data: Data([0x01]), final: true, context: context
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let badFinal = try await registry.createUpload(
            size: 1, filename: "final.bin", contentType: "application/octet-stream", context: context
        )
        await #expect(throws: AutomationCommandError.self) {
            try await registry.write(
                transferID: badFinal.transferID, sequence: 0, offset: 0,
                totalBytes: badFinal.size, data: Data([0x01]), final: false, context: context
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func emptyUploadFinalizesAndExplicitReleaseFreesSpool() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = AutomationTransferRegistry(idleTimeout: .seconds(60), temporaryDirectory: root)
        let context = AutomationClientContext(origin: .localCLI, grant: .local)
        let descriptor = try await registry.createUpload(
            size: 0, filename: "empty.bin", contentType: "application/octet-stream", context: context
        )
        try await registry.write(
            transferID: descriptor.transferID, sequence: 0, offset: 0,
            totalBytes: 0, data: Data(), final: true, context: context
        )
        let finalized = try await registry.finalizeUpload(
            transferID: descriptor.transferID, context: context
        )
        #expect(try Data(contentsOf: finalized).isEmpty)
        try await registry.release(transferID: descriptor.transferID, context: context)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
