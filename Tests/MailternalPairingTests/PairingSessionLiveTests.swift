#if os(macOS) && canImport(CryptoKit) && canImport(Network)
import Foundation
import MailternalInterfaces
import MailternalPairing
import MailternalWorkspace
import Testing

/// Bonjour pairing tests are opt-in because they require local-network
/// permission and two Network.framework endpoints in one process.
private enum PairingQA {
    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["MAILTERNAL_QA"] == "1"
            && environment["MAILTERNAL_QA_PAIRING"] == "1"
    }

    static var expirySmokeEnabled: Bool {
        enabled && ProcessInfo.processInfo.environment["MAILTERNAL_QA_PAIRING_EXPIRY"] == "1"
    }
}

private enum PairingTestError: Error {
    case timeout
    case missingInvitation
    case missingBundle
    case malformedInvitation
}

private actor CompletionProbe {
    private var finished = false
    private var succeeded = false

    func finish(succeeded: Bool) {
        self.finished = true
        self.succeeded = succeeded
    }

    func isFinished() -> Bool { finished }
    func didSucceed() -> Bool { finished && succeeded }
}

/// The invitation is intentionally decoded here only to produce a valid,
/// serialized fixture with one field changed. No account payload is involved.
private struct SerializedInvitation: Codable {
    var schema: String
    var sessionID: UUID
    var key: Data
    var serviceName: String
    var expiresAt: Date
}

@Suite(.serialized)
struct PairingSessionLiveTests {
    @Test(.enabled(if: PairingQA.enabled))
    @MainActor
    func liveAdvertiserToJoinerTransfersBundleAfterImportAcknowledgment() async throws {
        let expected = fixtureBundle(seed: "advertiser-to-joiner")
        try await withFreshPair { advertiser, joiner in
            try await assertTransfer(
                expected,
                sender: advertiser,
                receiver: joiner
            )
        }
    }

    @Test(.enabled(if: PairingQA.enabled))
    @MainActor
    func liveJoinerToAdvertiserTransfersBundleAfterImportAcknowledgment() async throws {
        let expected = fixtureBundle(seed: "joiner-to-advertiser")
        try await withFreshPair { advertiser, joiner in
            try await assertTransfer(
                expected,
                sender: joiner,
                receiver: advertiser
            )
        }
    }

    @Test(.enabled(if: PairingQA.enabled))
    @MainActor
    func liveTamperedRootKeyIsRejectedWithoutAcceptingPeer() async throws {
        let advertiser = PairingSession(deviceName: "Pairing advertiser")
        let joiner = PairingSession(deviceName: "Pairing joiner")
        defer {
            advertiser.cancel()
            joiner.cancel()
        }

        try await withTimeout(.seconds(15)) {
            try await advertiser.showCode()
        }
        guard let invitation = advertiser.invitation else {
            throw PairingTestError.missingInvitation
        }
        let tampered = try mutateInvitation(invitation.qrString) { serialized in
            guard !serialized.key.isEmpty else {
                throw PairingTestError.malformedInvitation
            }
            serialized.key[0] = serialized.key[0] ^ 0xff
        }

        var authenticationFailed = false
        do {
            try await withTimeout(.seconds(15)) {
                try await joiner.join(qrString: tampered)
            }
        } catch let error as PairingError {
            authenticationFailed = error == .authenticationFailed
        } catch {
            // A timeout is a failed test below, not a reason to log transport data.
        }

        #expect(authenticationFailed)
        try await waitUntil(timeout: .seconds(5)) {
            advertiser.state == .advertising
        }
        #expect(advertiser.peerName == nil)
        #expect(joiner.state == .failed)
    }

    /// Manual-only smoke coverage for the real advertiser expiry task. Keep
    /// this disabled in CI; the serialized expired-code test above is the
    /// permanent, no-sleep expiry contract.
    @Test(.enabled(if: PairingQA.expirySmokeEnabled))
    @MainActor
    func smokeLiveAdvertiserExpiresInvitation() async throws {
        let advertiser = PairingSession(deviceName: "Pairing advertiser")
        defer { advertiser.cancel() }

        try await withTimeout(.seconds(15)) {
            try await advertiser.showCode()
        }
        try await waitUntil(timeout: .seconds(5 * 60 + 20), poll: .seconds(1)) {
            advertiser.state == .expired
        }
        #expect(advertiser.invitation == nil)
    }

    /// This stays permanently runnable: it exercises serialized invitation
    /// validation and never starts Bonjour or waits for the five-minute expiry.
    @Test
    @MainActor
    func expiredSerializedInvitationIsRejectedBeforeNetworkDiscovery() async throws {
        let invitation = SerializedInvitation(
            schema: PairingBundle.schemaIdentifier,
            sessionID: UUID(uuidString: "8A8B8C8D-8E8F-4090-8102-030405060708")!,
            key: Data(repeating: 0x4a, count: 32),
            serviceName: "mailternal-expired-fixture",
            expiresAt: Date(timeIntervalSinceNow: -1)
        )
        let qrString = try encodeInvitation(invitation)
        let joiner = PairingSession(deviceName: "Pairing joiner")

        await #expect(throws: PairingError.invitationExpired) {
            try await joiner.join(qrString: qrString)
        }
        #expect(joiner.state == .idle)
        #expect(joiner.invitation == nil)
    }
}

@MainActor
private func withFreshPair(
    _ operation: @escaping @MainActor (PairingSession, PairingSession) async throws -> Void
) async throws {
    let advertiser = PairingSession(deviceName: "Pairing advertiser")
    let joiner = PairingSession(deviceName: "Pairing joiner")
    defer {
        advertiser.cancel()
        joiner.cancel()
    }

    try await withTimeout(.seconds(15)) {
        try await advertiser.showCode()
    }
    guard let qrString = advertiser.invitation?.qrString else {
        throw PairingTestError.missingInvitation
    }
    try await withTimeout(.seconds(15)) {
        try await joiner.join(qrString: qrString)
    }
    try await waitUntil(timeout: .seconds(10)) {
        advertiser.state == .connected && joiner.state == .connected
    }
    #expect(advertiser.peerName == "Pairing joiner")
    #expect(joiner.peerName == "Pairing advertiser")
    try await operation(advertiser, joiner)
}

@MainActor
private func assertTransfer(
    _ expected: PairingBundle,
    sender: PairingSession,
    receiver: PairingSession
) async throws {
    let probe = CompletionProbe()
    let sendTask = Task { @MainActor in
        do {
            try await sender.send(expected)
            await probe.finish(succeeded: true)
        } catch {
            await probe.finish(succeeded: false)
        }
    }

    do {
        try await waitUntil(timeout: .seconds(10)) {
            sender.state == .sending && receiver.state == .received
        }
        try await Task.sleep(for: .milliseconds(150))

        let completedBeforeImport = await probe.isFinished()
        #expect(!completedBeforeImport)
        #expect(sender.state == .sending)

        guard let received = receiver.receivedBundle else {
            throw PairingTestError.missingBundle
        }
        #expect(bundleMatches(received, expected: expected))

        try await withTimeout(.seconds(10)) {
            try await receiver.completeImport()
        }
        try await waitUntil(timeout: .seconds(10)) {
            await probe.isFinished()
        }
        #expect(await probe.didSucceed())
        #expect(sender.state == .completed)
        #expect(receiver.state == .completed)
        await sendTask.value
    } catch {
        sender.cancel()
        receiver.cancel()
        sendTask.cancel()
        await sendTask.value
        throw error
    }
}

@MainActor
private func waitUntil(
    timeout: Duration,
    poll: Duration = .milliseconds(20),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: poll)
    }
    guard await condition() else { throw PairingTestError.timeout }
}

private func withTimeout(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw PairingTestError.timeout
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}

private func fixtureBundle(seed: String) -> PairingBundle {
    let account = AccountConfig(
        id: AccountID(rawValue: "pairing-\(seed)"),
        accountLinkID: AccountLinkID(
            rawValue: UUID(uuidString: "10111213-1415-4617-9819-1a1b1c1d1e1f")!
        ),
        displayName: "Fixture account \(seed)",
        emailAddress: "fixture-\(seed)@mailternal.test",
        username: "fixture-\(seed)",
        imap: IMAPEndpoint(host: "imap.fixture.test", port: 993, security: .implicitTLS),
        isEnabled: true
    )
    let secondaryAccount = AccountConfig(
        id: AccountID(rawValue: "pairing-\(seed)-secondary"),
        accountLinkID: AccountLinkID(
            rawValue: UUID(uuidString: "20212223-2425-4627-a829-2a2b2c2d2e2f")!
        ),
        displayName: "Secondary fixture account \(seed)",
        emailAddress: "secondary-\(seed)@mailternal.test",
        username: "secondary-\(seed)",
        imap: IMAPEndpoint(host: "imap2.fixture.test", port: 143, security: .startTLS),
        isEnabled: false
    )
    return PairingBundle(
        accounts: [
            PairingAccount(config: account, credential: "fixture-credential-\(seed)"),
            PairingAccount(config: secondaryAccount, credential: "secondary-credential-\(seed)")
        ],
        settings: [
            "appearance.theme": .string("dark"),
            "messageList.showUnread": .bool(true),
            "messageList.rowHeight": .number(1.25),
            "messageList.columnOrder": .data(Data([0x00, 0x7f, 0xa5, 0xff]))
        ]
    )
}

private func bundleMatches(_ actual: PairingBundle, expected: PairingBundle) -> Bool {
    guard actual.schema == expected.schema,
          actual.accounts.count == expected.accounts.count,
          actual.settings == expected.settings else {
        return false
    }
    return zip(actual.accounts, expected.accounts).allSatisfy { actualAccount, expectedAccount in
        actualAccount.config == expectedAccount.config
            && actualAccount.credential == expectedAccount.credential
    }
}

private func mutateInvitation(
    _ qrString: String,
    _ mutate: (inout SerializedInvitation) throws -> Void
) throws -> String {
    var invitation = try decodeInvitation(qrString)
    try mutate(&invitation)
    return try encodeInvitation(invitation)
}

private func decodeInvitation(_ qrString: String) throws -> SerializedInvitation {
    guard qrString.hasPrefix("mtn1.") else {
        throw PairingTestError.malformedInvitation
    }
    let encoded = String(qrString.dropFirst(5))
    let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/") + padding) else {
        throw PairingTestError.malformedInvitation
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    do {
        return try decoder.decode(SerializedInvitation.self, from: data)
    } catch {
        throw PairingTestError.malformedInvitation
    }
}

private func encodeInvitation(_ invitation: SerializedInvitation) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var encoded = try encoder.encode(invitation).base64EncodedString()
    encoded = encoded
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "mtn1." + encoded
}
#endif
