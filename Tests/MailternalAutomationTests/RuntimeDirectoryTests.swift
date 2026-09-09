import Foundation
import Testing
import MailternalAutomation

struct RuntimeDirectoryTests {
    @Test func existingOwnedDirectoryIsMadePrivateBeforeAcquiringLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let lease = AutomationRuntimeLease(endpoint: AutomationEndpoint(containerURL: root))
        defer { lease.release() }
        try lease.acquire()
        #expect(lease.isOwner)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test func symlinkContainerIsRejectedWithoutChangingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let lease = AutomationRuntimeLease(endpoint: AutomationEndpoint(containerURL: link))
        defer { lease.release() }
        #expect(throws: (any Error).self) { try lease.acquire() }
        #expect(!lease.isOwner)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
    }

    @Test func rejectedHardLinkedTokenDoesNotTruncateItsOtherName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AutomationEndpoint(containerURL: root)
        let protectedFile = root.appendingPathComponent("preserved-data")
        let original = Data("preserve this data".utf8)
        try original.write(to: protectedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: protectedFile.path)
        try FileManager.default.linkItem(at: protectedFile, to: endpoint.tokenURL)
        let tokens = AutomationTokenStore(endpoint: endpoint)
        #expect(throws: (any Error).self) { try tokens.create() }
        #expect(try Data(contentsOf: protectedFile) == original)
    }

    @Test func pairingRemainsAvailableWhileRuntimeOwnsContainer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AutomationEndpoint(containerURL: root)
        let lease = AutomationRuntimeLease(endpoint: endpoint)
        try lease.acquire()
        defer { lease.release() }
        // Release a deadlocked implementation so this regression reports a
        // failure rather than hanging the suite. This is not a timing assertion.
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(5))
            lease.release()
        }
        defer { watchdog.cancel() }
        let pairings = try AutomationPairingStore(endpoint: endpoint)
        let material = try await Task.detached {
            let offer = try pairings.createOffer(grant: AutomationGrant(canRead: true))
            return try pairings.consumeOffer(code: offer.code)
        }.value
        #expect(pairings.context(forBearer: material.bearerToken) != nil)
        #expect(try pairings.revoke(clientID: material.client.id))
        #expect(pairings.context(forBearer: material.bearerToken) == nil)
        let contender = AutomationRuntimeLease(endpoint: endpoint)
        defer { contender.release() }
        #expect(throws: AutomationSecurityError.runtimeOwned) {
            try contender.acquire()
        }
    }

    @Test func persistedURLSafeOfferPreservesHyphensAndConsumesOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let code = "A-_BCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
        let formatter = ISO8601DateFormatter()
        let grant = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AutomationGrant(canRead: true))
        )
        // A restored offer exercises the full URL-safe alphabet deterministically,
        // rather than depending on a randomly generated code containing a hyphen.
        let record: [String: Any] = [
            "id": UUID().uuidString, "grant": grant,
            "codeDigest": "/mQXLRT8Ak4GnxnLY8JvAOFxrQTXNdpnM74gXNVNaw0=",
            "createdAt": formatter.string(from: Date()),
            "expiresAt": formatter.string(from: Date().addingTimeInterval(300))
        ]
        let file = root.appendingPathComponent("mailternal.automation-pairing-offers.json")
        try JSONSerialization.data(withJSONObject: [record]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let pairings = try AutomationPairingStore(endpoint: AutomationEndpoint(containerURL: root))
        let material = try pairings.consumeOffer(code: " \n\(code)\t")
        #expect(pairings.context(forBearer: material.bearerToken) != nil)
        #expect(throws: AutomationSecurityError.notPaired) {
            try pairings.consumeOffer(code: code)
        }
    }
}
