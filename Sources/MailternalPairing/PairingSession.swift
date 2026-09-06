import Foundation
import Observation
import MailternalInterfaces

#if canImport(CryptoKit) && canImport(Network)
import CryptoKit
import Network

/// A one-shot, direction-free authenticated pairing channel.
///
/// The QR code establishes a short-lived channel key and a Bonjour rendezvous;
/// account data is never placed in the QR payload. Once both peers prove
/// possession of that key, either peer may call `send(_:)`. The recipient must
/// explicitly finish its Keychain import with `completeImport()` before the
/// sender succeeds.
@MainActor
@Observable
public final class PairingSession {
    public enum State: Equatable, Sendable {
        case idle
        case advertising
        case connecting
        case connected
        case sending
        case received
        case completed
        case expired
        case failed
    }

    private enum Wire {
        static let version: UInt8 = 1
        static let serviceType = "_mailternal-pair._tcp"
        static let invitationPrefix = "mtn1."
        static let maximumInvitationCharacters = 4_096
        static let maximumInvitationLifetime: TimeInterval = 5 * 60
        static let maximumFrameBytes = 256 * 1024 + 1_024
        static let maximumBundleBytes = PairingBundleValidation.maximumEncodedBytes
        static let maximumHelloBytes = 1_024
        static let maximumDeviceNameBytes = 128

        enum FrameKind: UInt8 {
            case hello = 1
            case encrypted = 2
        }

        enum PayloadKind: UInt8 {
            case ready = 1
            case transfer = 2
            case importAcknowledgment = 3
            case reject = 4
        }

        struct Invitation: Codable {
            let schema: String
            let sessionID: UUID
            let key: Data
            let serviceName: String
            let expiresAt: Date
        }
    }

    private struct ByteReader {
        let bytes: [UInt8]
        var offset = 0

        init(_ data: Data) {
            bytes = Array(data)
        }

        var isAtEnd: Bool { offset == bytes.count }
        var remaining: Int { bytes.count - offset }

        mutating func readByte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func readData(count: Int) -> Data? {
            guard count >= 0, count <= remaining else { return nil }
            let result = Data(bytes[offset..<(offset + count)])
            offset += count
            return result
        }

        mutating func readUInt16() -> UInt16? {
            guard let first = readByte(), let second = readByte() else { return nil }
            return UInt16(first) << 8 | UInt16(second)
        }

        mutating func readUInt32() -> UInt32? {
            guard let first = readByte(), let second = readByte(),
                  let third = readByte(), let fourth = readByte() else { return nil }
            return UInt32(first) << 24 | UInt32(second) << 16 | UInt32(third) << 8 | UInt32(fourth)
        }

        mutating func readUInt64() -> UInt64? {
            var value: UInt64 = 0
            for _ in 0..<8 {
                guard let byte = readByte() else { return nil }
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
    }

    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let networkQueue = DispatchQueue(
        label: "org.kayg.mailternal.pairing.network"
    )

    public private(set) var state: State = .idle
    public private(set) var invitation: PairingInvitation?
    public private(set) var peerName: String?
    public private(set) var receivedBundle: PairingBundle?
    public private(set) var errorMessage: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var listenerWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var connectionWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var sendWaiter: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var importAckWaiter: CheckedContinuation<Void, Error>?

    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var serviceName: String?
    @ObservationIgnored private var rootKey: SymmetricKey?
    @ObservationIgnored private var localChallenge: Data?
    @ObservationIgnored private var remoteChallenge: Data?
    @ObservationIgnored private var remoteDeviceName: String?
    @ObservationIgnored private var isAdvertiser = false
    @ObservationIgnored private var localHelloSent = false
    @ObservationIgnored private var keysEstablished = false
    @ObservationIgnored private var readySent = false
    @ObservationIgnored private var authenticated = false
    @ObservationIgnored private var readyReceived = false
    @ObservationIgnored private var outgoingSequence: UInt64 = 0
    @ObservationIgnored private var incomingSequence: UInt64 = 0
    @ObservationIgnored private var pendingTransferSequence: UInt64?
    @ObservationIgnored private var pendingReceivedSequence: UInt64?
    @ObservationIgnored private var sendKey: SymmetricKey?
    @ObservationIgnored private var receiveKey: SymmetricKey?
    @ObservationIgnored private var sendNonceKey: SymmetricKey?
    @ObservationIgnored private var receiveNonceKey: SymmetricKey?
    @ObservationIgnored private var operationGeneration: UInt64 = 0

    public init(deviceName: String) {
        self.deviceName = Self.boundedDeviceName(deviceName)
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        handshakeTimeoutTask?.cancel()
        expiryTask?.cancel()
    }

    /// Creates a one-time QR invitation and publishes its Bonjour service.
    ///
    /// This method returns after Bonjour reports the listener ready. It does not
    /// choose a transfer direction; either peer may later call `send(_:)`.
    public func showCode() async throws {
        guard state == .idle else { throw PairingError.invalidState }
        guard !deviceName.isEmpty else {
            throw PairingError.transport("A device name is required for pairing.")
        }

        let sessionID = UUID()
        let rootKey = SymmetricKey(size: .bits256)
        let keyData = Data(rootKey.withUnsafeBytes { Data($0) })
        let serviceName = "mailternal-\(sessionID.uuidString.lowercased())"
        let expiresAt = Date().addingTimeInterval(Wire.maximumInvitationLifetime)
        let wireInvitation = Wire.Invitation(
            schema: PairingBundle.schemaIdentifier,
            sessionID: sessionID,
            key: keyData,
            serviceName: serviceName,
            expiresAt: expiresAt
        )
        let qrString = try Self.encodeInvitation(wireInvitation)

        self.sessionID = sessionID
        self.serviceName = serviceName
        self.rootKey = rootKey
        self.localChallenge = Self.randomBytes(count: 32)
        self.isAdvertiser = true
        self.invitation = PairingInvitation(expiresAt: expiresAt, qrString: qrString)
        self.errorMessage = nil
        self.state = .advertising
        scheduleExpiry(expiresAt)

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            let pairingError = PairingError.transport("Pairing listener could not start.")
            terminate(state: .failed, error: pairingError)
            throw pairingError
        }
        listener.service = NWListener.Service(name: serviceName, type: Wire.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.listenerStateChanged(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        self.listener = listener

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listenerWaiter = continuation
                listener.start(queue: networkQueue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Scans an invitation and connects to its exact Bonjour service.
    ///
    /// Authentication is completed before this method returns. Invalid peers
    /// do not consume an advertiser's invitation; the advertiser continues to
    /// listen until a valid peer arrives or the invitation expires.
    public func join(qrString: String) async throws {
        guard state == .idle else { throw PairingError.invalidState }
        let wireInvitation = try Self.decodeInvitation(qrString)
        guard wireInvitation.expiresAt > Date() else {
            throw PairingError.invitationExpired
        }

        self.sessionID = wireInvitation.sessionID
        self.serviceName = wireInvitation.serviceName
        self.rootKey = SymmetricKey(data: wireInvitation.key)
        self.localChallenge = Self.randomBytes(count: 32)
        self.isAdvertiser = false
        self.invitation = PairingInvitation(
            expiresAt: wireInvitation.expiresAt,
            qrString: qrString
        )
        self.errorMessage = nil
        self.state = .connecting
        scheduleExpiry(wireInvitation.expiresAt)

        let browser = NWBrowser(
            for: .bonjour(type: Wire.serviceType, domain: "local."),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.browserStateChanged(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.browseResultsChanged(results)
            }
        }
        self.browser = browser

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connectionWaiter = continuation
                browser.start(queue: networkQueue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Sends a user-confirmed bundle in either direction and waits for the
    /// recipient's completed-import acknowledgment.
    public func send(_ bundle: PairingBundle) async throws {
        guard state == .connected, authenticated else { throw PairingError.invalidState }
        guard sendWaiter == nil, importAckWaiter == nil else {
            throw PairingError.invalidState
        }

        let encoded: Data
        do {
            encoded = try Self.encoder.encode(bundle)
        } catch {
            throw PairingError.malformedBundle
        }
        guard encoded.count <= Wire.maximumBundleBytes else {
            throw PairingError.frameTooLarge
        }
        guard bundle.schema == PairingBundle.schemaIdentifier,
              PairingBundleValidation.isAcceptable(bundle) else {
            throw PairingError.malformedBundle
        }

        guard let activeConnection = connection else { throw PairingError.invalidState }
        operationGeneration &+= 1
        let generation = operationGeneration
        let sequence = outgoingSequence
        pendingTransferSequence = sequence
        state = .sending

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sendWaiter = continuation
                sendEncrypted(.transfer, body: Self.lengthPrefixed(encoded)) { [weak self] error in
                    guard let self,
                          self.operationGeneration == generation,
                          self.state == .sending,
                          self.sendWaiter != nil,
                          self.connection === activeConnection else { return }
                    if let error {
                        self.fail(error: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPendingSend() }
        }
    }

    /// A recipient calls this only after its durable Keychain/import callback
    /// has completed successfully. The sender is not released before the ACK
    /// frame has been accepted by the transport.
    public func completeImport() async throws {
        guard state == .received, authenticated,
              let sequence = pendingReceivedSequence else {
            throw PairingError.invalidState
        }
        guard importAckWaiter == nil,
              let activeConnection = connection else {
            throw PairingError.invalidState
        }

        operationGeneration &+= 1
        let generation = operationGeneration
        state = .sending
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                importAckWaiter = continuation
                var body = Data(capacity: 8)
                body.appendUInt64(sequence)
                sendEncrypted(.importAcknowledgment, body: body) { [weak self] error in
                    guard let self,
                          self.operationGeneration == generation,
                          self.state == .sending,
                          self.importAckWaiter != nil,
                          self.connection === activeConnection else { return }
                    if let error {
                        self.fail(error: error)
                    } else {
                        self.finishCompleted()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// Cancels the one-shot session and invalidates its invitation.
    public func cancel() {
        guard state != .completed, state != .expired else { return }
        terminate(state: .failed, error: .cancelled)
    }

    // MARK: - Listener/browser lifecycle

    private func listenerStateChanged(_ state: NWListener.State) {
        guard self.state == .advertising, listener != nil else { return }
        switch state {
        case .ready:
            if let waiter = listenerWaiter {
                listenerWaiter = nil
                waiter.resume()
            }
        case .failed(let error):
            let pairingError = PairingError.transport("Pairing listener failed: \(error.localizedDescription)")
            if let waiter = listenerWaiter {
                listenerWaiter = nil
                waiter.resume(throwing: pairingError)
            }
            terminate(state: .failed, error: pairingError)
        default:
            break
        }
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        guard self.state == .connecting, browser != nil else { return }
        if case .failed(let error) = state {
            let pairingError = PairingError.transport("Pairing discovery failed: \(error.localizedDescription)")
            if let waiter = connectionWaiter {
                connectionWaiter = nil
                waiter.resume(throwing: pairingError)
            }
            terminate(state: .failed, error: pairingError)
        }
    }

    private func browseResultsChanged(_ results: Set<NWBrowser.Result>) {
        guard state == .connecting, connection == nil,
              let expectedService = serviceName else { return }
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  name == expectedService else { continue }
            browser?.browseResultsChangedHandler = nil
            browser?.cancel()
            browser = nil
            localChallenge = Self.randomBytes(count: 32)
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            self.connection = connection
            configure(connection)
            connection.start(queue: networkQueue)
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard state == .advertising, self.connection == nil else {
            connection.cancel()
            return
        }
        localChallenge = Self.randomBytes(count: 32)
        self.connection = connection
        configure(connection)
        connection.start(queue: networkQueue)
    }

    private func configure(_ connection: NWConnection) {
        let expected = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.connectionStateChanged(state, for: expected)
            }
        }
        scheduleHandshakeTimeout(for: connection)
    }

    private func connectionStateChanged(_ state: NWConnection.State, for connection: NWConnection) {
        guard self.connection === connection else { return }
        switch state {
        case .ready:
            guard !localHelloSent else { return }
            do {
                let hello = try makeHelloFrame()
                localHelloSent = true
                sendRawFrame(hello, on: connection) { [weak self] error in
                    guard let self, self.connection === connection else { return }
                    if let error, !self.authenticated {
                        self.unauthenticatedConnectionFailed(error)
                    }
                }
                receiveNextFrame(on: connection)
            } catch {
                unauthenticatedConnectionFailed(error)
            }
        case .failed(_):
            if authenticated {
                terminate(state: .failed, error: .peerDisconnected)
            } else if isAdvertiser {
                resetUnauthenticatedConnection(connection)
            } else {
                terminate(state: .failed, error: .authenticationFailed)
            }
        case .cancelled:
            if authenticated {
                terminate(state: .failed, error: .peerDisconnected)
            } else if isAdvertiser {
                resetUnauthenticatedConnection(connection)
            } else {
                terminate(state: .failed, error: .authenticationFailed)
            }
        default:
            break
        }
    }

    private func sendRawFrame(
        _ frame: Data,
        on connection: NWConnection?,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        guard let connection else {
            completion(PairingError.invalidState)
            return
        }
        guard !frame.isEmpty, frame.count <= Wire.maximumFrameBytes else {
            completion(PairingError.frameTooLarge)
            return
        }
        let packet = Self.lengthPrefixed(frame)
        connection.send(content: packet, completion: .contentProcessed { error in
            Task { @MainActor in
                completion(error)
            }
        })
    }

    private func sendEncrypted(
        _ kind: Wire.PayloadKind,
        body: Data,
        completion: (@MainActor (Error?) -> Void)? = nil
    ) {
        do {
            let frame = try makeEncryptedFrame(kind: kind, body: body)
            sendRawFrame(frame, on: connection) { error in completion?(error) }
        } catch {
            completion?(error)
        }
    }

    private func scheduleHandshakeTimeout(for connection: NWConnection) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.handshakeTimedOut(connection)
        }
    }

    private func handshakeTimedOut(_ connection: NWConnection) {
        guard self.connection === connection, !authenticated else { return }
        if isAdvertiser {
            resetUnauthenticatedConnection(connection)
        } else {
            terminate(state: .failed, error: .authenticationFailed)
        }
    }

    private func resetUnauthenticatedConnection(_ connection: NWConnection) {
        guard self.connection === connection, !authenticated else { return }
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        connection.stateUpdateHandler = nil
        self.connection = nil
        connection.cancel()
        keysEstablished = false
        readySent = false
        sendKey = nil
        receiveKey = nil
        sendNonceKey = nil
        receiveNonceKey = nil
        outgoingSequence = 0
        incomingSequence = 0
        localHelloSent = false
        remoteChallenge = nil
        remoteDeviceName = nil
        readyReceived = false
    }

    private func unauthenticatedConnectionFailed(_ error: Error) {
        guard let connection else { return }
        if isAdvertiser {
            resetUnauthenticatedConnection(connection)
        } else {
            terminate(state: .failed, error: (error as? PairingError) ?? .authenticationFailed)
        }
    }

    // MARK: - Wire protocol

    private func makeHelloFrame() throws -> Data {
        guard let sessionID, let rootKey, let challenge = localChallenge else {
            throw PairingError.invalidState
        }
        let nameData = Data(deviceName.utf8)
        guard !nameData.isEmpty, nameData.count <= Wire.maximumDeviceNameBytes else {
            throw PairingError.transport("The device name is too long for pairing.")
        }

        var frame = Data(capacity: 1 + 1 + 16 + 32 + 2 + nameData.count + 32)
        frame.append(Wire.FrameKind.hello.rawValue)
        frame.append(Wire.version)
        frame.appendUUID(sessionID)
        frame.append(challenge)
        frame.appendUInt16(UInt16(nameData.count))
        frame.append(nameData)
        frame.append(Self.helloMAC(
            key: rootKey,
            sessionID: sessionID,
            challenge: challenge,
            deviceName: nameData
        ))
        guard frame.count <= Wire.maximumHelloBytes else { throw PairingError.frameTooLarge }
        return frame
    }

    private func handleFrame(_ frame: Data, on connection: NWConnection) {
        guard self.connection === connection else { return }
        guard !frame.isEmpty, frame.count <= Wire.maximumFrameBytes else {
            if authenticated {
                terminate(state: .failed, error: .frameTooLarge)
            } else {
                unauthenticatedConnectionFailed(PairingError.frameTooLarge)
            }
            return
        }
        if !keysEstablished {
            guard frame.first == Wire.FrameKind.hello.rawValue,
                  frame.count <= Wire.maximumHelloBytes else {
                unauthenticatedConnectionFailed(PairingError.authenticationFailed)
                return
            }
            do {
                try acceptHello(frame)
                if localHelloSent, remoteChallenge != nil {
                    try establishSessionKeys()
                }
            } catch {
                unauthenticatedConnectionFailed(error)
            }
            return
        }

        do {
            try acceptEncryptedFrame(frame)
        } catch {
            let pairingError = error as? PairingError ?? .protocolViolation("Invalid pairing frame.")
            if !authenticated, isAdvertiser {
                resetUnauthenticatedConnection(connection)
            } else {
                terminate(state: .failed, error: pairingError)
            }
        }
    }

    private func acceptHello(_ frame: Data) throws {
        guard let sessionID, let rootKey, let localChallenge else {
            throw PairingError.invalidState
        }
        var reader = ByteReader(frame)
        guard reader.readByte() == Wire.FrameKind.hello.rawValue,
              reader.readByte() == Wire.version,
              let receivedID = reader.readData(count: 16),
              let challenge = reader.readData(count: 32),
              let nameLength = reader.readUInt16(),
              nameLength > 0,
              Int(nameLength) <= Wire.maximumDeviceNameBytes,
              let nameData = reader.readData(count: Int(nameLength)),
              let mac = reader.readData(count: 32),
              reader.isAtEnd,
              Self.uuid(from: receivedID) == sessionID,
              challenge != localChallenge,
              let peerName = String(data: nameData, encoding: .utf8),
              !peerName.isEmpty,
              Self.boundedDeviceName(peerName) == peerName else {
            throw PairingError.authenticationFailed
        }
        let expectedMAC = Self.helloMAC(
            key: rootKey,
            sessionID: sessionID,
            challenge: challenge,
            deviceName: nameData
        )
        guard Self.constantTimeEqual(mac, expectedMAC) else {
            throw PairingError.authenticationFailed
        }
        guard remoteChallenge == nil else { throw PairingError.protocolViolation("Duplicate pairing handshake.") }
        remoteChallenge = challenge
        remoteDeviceName = peerName
    }

    private func establishSessionKeys() throws {
        guard !authenticated,
              let sessionID,
              let rootKey,
              let localChallenge,
              let remoteChallenge,
              let remoteDeviceName else { return }
        guard localChallenge != remoteChallenge else { throw PairingError.authenticationFailed }

        let localName = Data(deviceName.utf8)
        let transcript: Data
        if Self.lexicographicallyPrecedes(localChallenge, remoteChallenge) {
            transcript = Self.transcript(
                sessionID: sessionID,
                firstChallenge: localChallenge,
                firstName: localName,
                secondChallenge: remoteChallenge,
                secondName: Data(remoteDeviceName.utf8)
            )
        } else {
            transcript = Self.transcript(
                sessionID: sessionID,
                firstChallenge: remoteChallenge,
                firstName: Data(remoteDeviceName.utf8),
                secondChallenge: localChallenge,
                secondName: localName
            )
        }
        let localIsFirst = Self.lexicographicallyPrecedes(localChallenge, remoteChallenge)
        let localLabel = localIsFirst ? "first-to-second" : "second-to-first"
        let remoteLabel = localIsFirst ? "second-to-first" : "first-to-second"
        sendKey = Self.deriveKey(rootKey, transcript: transcript, label: localLabel + ".key")
        sendNonceKey = Self.deriveKey(rootKey, transcript: transcript, label: localLabel + ".nonce")
        receiveKey = Self.deriveKey(rootKey, transcript: transcript, label: remoteLabel + ".key")
        receiveNonceKey = Self.deriveKey(rootKey, transcript: transcript, label: remoteLabel + ".nonce")
        guard let activeConnection = connection else { throw PairingError.invalidState }
        keysEstablished = true
        sendEncrypted(.ready, body: Data()) { [weak self] error in
            guard let self, self.connection === activeConnection, !self.authenticated else { return }
            if let error {
                self.unauthenticatedConnectionFailed(error)
            } else {
                self.readySent = true
                self.maybeCompleteAuthentication()
            }
        }
        maybeCompleteAuthentication()
    }
    private func maybeCompleteAuthentication() {
        guard !authenticated, keysEstablished, readySent, readyReceived,
              let remoteDeviceName else { return }
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        authenticated = true
        peerName = remoteDeviceName
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        browser?.cancel()
        browser = nil
        state = .connected
        if let waiter = connectionWaiter {
            connectionWaiter = nil
            waiter.resume()
        }
    }

    private func acceptEncryptedFrame(_ frame: Data) throws {
        guard frame.count >= 1 + 8 + 16,
              frame.first == Wire.FrameKind.encrypted.rawValue,
              let receiveKey,
              let receiveNonceKey,
              let sessionID else {
            throw PairingError.protocolViolation("Malformed encrypted pairing frame.")
        }
        var reader = ByteReader(frame)
        _ = reader.readByte()
        guard let sequence = reader.readUInt64(),
              sequence == incomingSequence,
              let sealedData = reader.readData(count: reader.remaining),
              sealedData.count >= 16 else {
            throw sequenceMismatch(frame)
        }
        let ciphertext = sealedData.dropLast(16)
        let tag = sealedData.suffix(16)
        let nonce = try Self.frameNonce(key: receiveNonceKey, sequence: sequence)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try AES.GCM.open(
            sealedBox,
            using: receiveKey,
            authenticating: Self.associatedData(sessionID: sessionID, sequence: sequence)
        )
        guard let kind = plaintext.first.flatMap(Wire.PayloadKind.init(rawValue:)) else {
            throw PairingError.protocolViolation("Unknown pairing payload.")
        }
        incomingSequence += 1
        let body = Data(plaintext.dropFirst())
        switch kind {
        case .ready:
            guard body.isEmpty, !authenticated else {
                throw PairingError.protocolViolation("Malformed pairing readiness.")
            }
            readyReceived = true
            maybeCompleteAuthentication()
        case .transfer:
            try receiveTransfer(body, sequence: sequence)
        case .importAcknowledgment:
            try receiveImportAcknowledgment(body, sequence: sequence)
        case .reject:
            throw PairingError.simultaneousTransfer
        }
    }

    private func receiveTransfer(_ body: Data, sequence: UInt64) throws {
        guard authenticated else {
            throw PairingError.protocolViolation("Pairing transfer arrived before key confirmation.")
        }
        guard state != .received, state != .completed else {
            throw PairingError.protocolViolation("Unexpected pairing transfer.")
        }
        guard state != .sending else {
            throw PairingError.simultaneousTransfer
        }
        var reader = ByteReader(body)
        guard let length = reader.readUInt32(),
              Int(length) <= Wire.maximumBundleBytes,
              Int(length) == reader.remaining,
              let encoded = reader.readData(count: Int(length)),
              reader.isAtEnd else {
            throw body.count > Wire.maximumBundleBytes + 4 ? PairingError.frameTooLarge : PairingError.malformedBundle
        }
        let bundle: PairingBundle
        do {
            bundle = try Self.decoder.decode(PairingBundle.self, from: encoded)
        } catch {
            throw PairingError.malformedBundle
        }
        guard bundle.schema == PairingBundle.schemaIdentifier,
              PairingBundleValidation.isAcceptable(bundle) else {
            throw bundle.schema == PairingBundle.schemaIdentifier
                ? PairingError.malformedBundle
                : PairingError.unsupportedBundleSchema
        }
        pendingReceivedSequence = sequence
        receivedBundle = bundle
        state = .received
    }

    private func receiveImportAcknowledgment(_ body: Data, sequence: UInt64) throws {
        var reader = ByteReader(body)
        guard let acknowledged = reader.readUInt64(), reader.isAtEnd,
              state == .sending,
              let pendingTransferSequence,
              acknowledged == pendingTransferSequence else {
            throw PairingError.importAcknowledgmentMissing
        }
        guard let waiter = sendWaiter else {
            throw PairingError.protocolViolation("Unexpected pairing acknowledgment.")
        }
        sendWaiter = nil
        self.pendingTransferSequence = nil
        waiter.resume()
        finishCompleted()
    }


    private func makeEncryptedFrame(kind: Wire.PayloadKind, body: Data) throws -> Data {
        guard let sendKey,
              let sendNonceKey,
              let sessionID,
              outgoingSequence < UInt64.max else {
            throw PairingError.invalidState
        }
        var plaintext = Data(capacity: 1 + body.count)
        plaintext.append(kind.rawValue)
        plaintext.append(body)
        let sequence = outgoingSequence
        let nonce = try Self.frameNonce(key: sendNonceKey, sequence: sequence)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: sendKey,
            nonce: nonce,
            authenticating: Self.associatedData(sessionID: sessionID, sequence: sequence)
        )
        var sealedData = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
        sealedData.append(sealed.ciphertext)
        sealedData.append(sealed.tag)
        var frame = Data(capacity: 1 + 8 + sealedData.count)
        frame.append(Wire.FrameKind.encrypted.rawValue)
        frame.appendUInt64(sequence)
        frame.append(sealedData)
        guard frame.count <= Wire.maximumFrameBytes else { throw PairingError.frameTooLarge }
        outgoingSequence += 1
        return frame
    }

    private func receiveNextFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let error {
                    self.connectionReceiveFailed(error)
                    return
                }
                guard let data, data.count == 4 else {
                    self.connectionReceiveFailed(isComplete ? PairingError.peerDisconnected : PairingError.protocolViolation("Malformed pairing length."))
                    return
                }
                let length = Self.uint32(data)
                guard length > 0, length <= Wire.maximumFrameBytes else {
                    self.handleFrameTooLarge(on: connection)
                    return
                }
                self.receiveBody(length: length, on: connection, isComplete: isComplete)
            }
        }
    }

    private func receiveBody(length: Int, on connection: NWConnection, isComplete: Bool) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, bodyComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let error {
                    self.connectionReceiveFailed(error)
                    return
                }
                guard let data, data.count == length else {
                    self.connectionReceiveFailed(PairingError.peerDisconnected)
                    return
                }
                self.handleFrame(data, on: connection)
                guard self.connection === connection,
                      self.state != .failed,
                      self.state != .expired,
                      self.state != .completed else { return }
                if isComplete || bodyComplete {
                    self.connectionReceiveFailed(PairingError.peerDisconnected)
                } else {
                    self.receiveNextFrame(on: connection)
                }
            }
        }
    }

    private func connectionReceiveFailed(_ error: Error) {
        guard ![.completed, .expired].contains(state) else { return }
        if !authenticated, isAdvertiser, let connection {
            resetUnauthenticatedConnection(connection)
        } else {
            terminate(state: .failed, error: error as? PairingError ?? .peerDisconnected)
        }
    }

    private func handleFrameTooLarge(on connection: NWConnection) {
        if authenticated {
            terminate(state: .failed, error: .frameTooLarge)
        } else if isAdvertiser {
            resetUnauthenticatedConnection(connection)
        } else {
            terminate(state: .failed, error: .frameTooLarge)
        }
    }

    private func sequenceMismatch(_ frame: Data) -> PairingError {
        guard frame.count >= 9 else { return .protocolViolation("Malformed encrypted pairing frame.") }
        return .replayDetected
    }

    // MARK: - Terminal states

    private func scheduleExpiry(_ expiresAt: Date) {
        expiryTask?.cancel()
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            let nanoseconds = UInt64(min(delay, Wire.maximumInvitationLifetime) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.expireIfNeeded(expiresAt)
        }
    }

    private func expireIfNeeded(_ expiresAt: Date) {
        guard let invitation, invitation.expiresAt == expiresAt,
              Date() >= expiresAt,
              state != .completed else { return }
        terminate(state: .expired, error: .invitationExpired)
    }

    private func cancelPendingSend() {
        guard sendWaiter != nil else { return }
        terminate(state: .failed, error: .cancelled)
    }

    private func fail(error: Error) {
        let pairingError = error as? PairingError ?? .transport(error.localizedDescription)
        terminate(state: .failed, error: pairingError)
    }

    private func finishCompleted() {
        guard state == .sending else { return }
        let waiter = importAckWaiter
        importAckWaiter = nil
        receivedBundle = nil
        pendingReceivedSequence = nil
        terminate(state: .completed, error: nil)
        waiter?.resume()
    }

    private func terminate(state terminalState: State, error: PairingError?) {
        guard self.state != .completed,
              self.state != .failed,
              self.state != .expired else { return }
        operationGeneration &+= 1
        let listenerWaiter = self.listenerWaiter
        let connectionWaiter = self.connectionWaiter
        let sendWaiter = self.sendWaiter
        let importAckWaiter = self.importAckWaiter
        self.listenerWaiter = nil
        self.connectionWaiter = nil
        self.sendWaiter = nil
        self.importAckWaiter = nil
        tearDownTransport()
        self.state = terminalState
        self.errorMessage = error?.localizedDescription
        listenerWaiter?.resume(throwing: error ?? PairingError.cancelled)
        connectionWaiter?.resume(throwing: error ?? PairingError.cancelled)
        sendWaiter?.resume(throwing: error ?? PairingError.cancelled)
        importAckWaiter?.resume(throwing: error ?? PairingError.cancelled)
    }

    private func tearDownTransport() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        browser?.browseResultsChangedHandler = nil
        browser?.stateUpdateHandler = nil
        keysEstablished = false
        readySent = false
        browser?.cancel()
        browser = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        expiryTask?.cancel()
        expiryTask = nil
        invitation = nil
        rootKey = nil
        localChallenge = nil
        remoteChallenge = nil
        remoteDeviceName = nil
        sendKey = nil
        receiveKey = nil
        sendNonceKey = nil
        receiveNonceKey = nil
        authenticated = false
        localHelloSent = false
        outgoingSequence = 0
        incomingSequence = 0
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        pendingTransferSequence = nil
        pendingReceivedSequence = nil
        receivedBundle = nil
    }

    // MARK: - Encoding and cryptographic helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static func encodeInvitation(_ invitation: Wire.Invitation) throws -> String {
        let data = try encoder.encode(invitation)
        var encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        encoded = encoded.replacingOccurrences(of: "=", with: "")
        let qrString = Wire.invitationPrefix + encoded
        guard qrString.utf8.count <= Wire.maximumInvitationCharacters else {
            throw PairingError.invitationTooLong
        }
        return qrString
    }

    private static func decodeInvitation(_ qrString: String) throws -> Wire.Invitation {
        guard qrString.utf8.count <= Wire.maximumInvitationCharacters,
              qrString.hasPrefix(Wire.invitationPrefix) else {
            throw qrString.utf8.count > Wire.maximumInvitationCharacters
                ? PairingError.invitationTooLong
                : PairingError.invalidInvitation
        }
        let encoded = String(qrString.dropFirst(Wire.invitationPrefix.count))
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy({
                  $0.value < 128 && (
                      ($0.value >= 48 && $0.value <= 57) ||
                      ($0.value >= 65 && $0.value <= 90) ||
                      ($0.value >= 97 && $0.value <= 122) ||
                      $0.value == 45 || $0.value == 95
                  )
              }) else {
            throw PairingError.invalidInvitation
        }
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding),
            data.count <= 2_048 else {
            throw PairingError.invalidInvitation
        }
        let invitation: Wire.Invitation
        do {
            invitation = try decoder.decode(Wire.Invitation.self, from: data)
        } catch {
            throw PairingError.invalidInvitation
        }
        guard invitation.schema == PairingBundle.schemaIdentifier,
              invitation.key.count == 32,
              invitation.serviceName.utf8.count > 0,
              invitation.serviceName.utf8.count <= 63,
              invitation.expiresAt > Date(),
              invitation.expiresAt.timeIntervalSinceNow <= Wire.maximumInvitationLifetime,
              invitation.serviceName.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
            throw invitation.expiresAt <= Date() ? PairingError.invitationExpired : PairingError.invalidInvitation
        }
        return invitation
    }

    private static func boundedDeviceName(_ input: String) -> String {
        var result = ""
        var byteCount = 0
        for character in input {
            guard character.unicodeScalars.allSatisfy(Self.isSafeNameScalar) else { continue }
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= Wire.maximumDeviceNameBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func isSafeNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...0x1F, 0x7F...0x9F,
             0x00AD, 0x061C, 0x180E,
             0x200B...0x200F, 0x2028...0x202E,
             0x2060...0x206F, 0xFEFF, 0xFFF9...0xFFFB,
             0x1D173...0x1D17A:
            return false
        default:
            return true
        }
    }

    private static func randomBytes(count: Int) -> Data {
        let key = SymmetricKey(size: .bits256)
        return Data(key.withUnsafeBytes { Data($0.prefix(count)) })
    }

    private static func helloMAC(
        key: SymmetricKey,
        sessionID: UUID,
        challenge: Data,
        deviceName: Data
    ) -> Data {
        var message = Data("mailternal.pairing.hello.v1".utf8)
        message.appendUUID(sessionID)
        message.append(challenge)
        message.appendUInt16(UInt16(deviceName.count))
        message.append(deviceName)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private static func transcript(
        sessionID: UUID,
        firstChallenge: Data,
        firstName: Data,
        secondChallenge: Data,
        secondName: Data
    ) -> Data {
        var result = Data("mailternal.pairing.transcript.v1".utf8)
        result.appendUUID(sessionID)
        result.append(firstChallenge)
        result.appendUInt16(UInt16(firstName.count))
        result.append(firstName)
        result.append(secondChallenge)
        result.appendUInt16(UInt16(secondName.count))
        result.append(secondName)
        return result
    }

    private static func deriveKey(_ root: SymmetricKey, transcript: Data, label: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root,
            salt: transcript,
            info: Data(("mailternal.pairing." + label).utf8),
            outputByteCount: 32
        )
    }

    private static func frameNonce(key: SymmetricKey, sequence: UInt64) throws -> AES.GCM.Nonce {
        var input = Data("mailternal.pairing.nonce.v1".utf8)
        input.appendUInt64(sequence)
        let digest = HMAC<SHA256>.authenticationCode(for: input, using: key)
        return try digest.withUnsafeBytes { bytes in
            try AES.GCM.Nonce(data: Data(bytes.prefix(12)))
        }
    }

    private static func associatedData(sessionID: UUID, sequence: UInt64) -> Data {
        var result = Data("mailternal.pairing.frame.v1".utf8)
        result.appendUUID(sessionID)
        result.appendUInt64(sequence)
        return result
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func lexicographicallyPrecedes(_ lhs: Data, _ rhs: Data) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return lhs.count < rhs.count
    }

    private static func uuid(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: data)
        }
        return UUID(uuid: value)
    }

    private static func uint32(_ data: Data) -> Int {
        let bytes = Array(data)
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var result = Data(capacity: 4 + data.count)
        result.appendUInt32(UInt32(data.count))
        result.append(data)
        return result
    }

}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUUID(_ uuid: UUID) {
        var value = uuid.uuid
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
#endif
