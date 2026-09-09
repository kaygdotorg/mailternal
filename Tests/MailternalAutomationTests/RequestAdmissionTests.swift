import Foundation
import Testing
import MailternalInterfaces
@testable import MailternalAutomation
#if os(macOS)
import Darwin
#endif

struct RequestAdmissionTests {

    @Test func unixServerRejectsAmbiguousOperationsWithoutCallingHandler() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let endpoint = AutomationEndpoint(containerURL: root)
        let tokenStore = AutomationTokenStore(endpoint: endpoint)
        let token = try tokenStore.create()
        let server = AutomationSocketServer(endpoint: endpoint, tokenStore: tokenStore)
        let calls = HandlerCallCounter()
        let eventCalls = HandlerCallCounter()
        try await server.start(
            handler: { _, _ in
                await calls.increment()
                return AutomationResponse(requestID: UUID(), ok: true)
            },
            events: { _, _ in
                await eventCalls.increment()
                return AsyncStream { $0.finish() }
            }
        )
        defer { server.stop() }

        let requests = [
            AutomationRequest(token: token, origin: .localCLI,
                              command: .search("invoice", 1), control: .remoteStatus),
            AutomationRequest(token: token, origin: .localCLI,
                              command: .search("invoice", 1), wantsState: true, observesState: true),
            AutomationRequest(token: token, origin: .localCLI,
                              control: .remoteStatus, wantsState: true),
            AutomationRequest(token: token, origin: .localCLI,
                              control: .remoteStatus, wantsGUIState: true),
            AutomationRequest(token: token, origin: .localCLI,
                              wantsState: true, afterRevision: 9)
        ]
        for request in requests {
            let response = try await AutomationSocketClient(endpoint: endpoint).request(request)
            #expect(response.requestID == request.requestID)
            #expect(!response.ok)
            #expect(response.failure == .usage)
        }
        #expect(await calls.value == 0)
        #expect(await eventCalls.value == 0)
    }

    @Test func unixAuthenticationFailurePrecedesOperationValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let endpoint = AutomationEndpoint(containerURL: root)
        let tokenStore = AutomationTokenStore(endpoint: endpoint)
        _ = try tokenStore.create()
        let server = AutomationSocketServer(endpoint: endpoint, tokenStore: tokenStore)
        let calls = HandlerCallCounter()
        try await server.start(
            handler: { _, _ in
                await calls.increment()
                return AutomationResponse(requestID: UUID(), ok: true)
            },
            events: { _, _ in AsyncStream { $0.finish() } }
        )
        defer { server.stop() }

        let request = AutomationRequest(token: "not-the-token", origin: .localCLI,
                                        command: .search("invoice", 1), wantsState: true)
        let response = try await AutomationSocketClient(endpoint: endpoint).request(request)
        #expect(response.requestID == request.requestID)
        #expect(!response.ok)
        #expect(response.failure == .authorization)
        #expect(await calls.value == 0)
    }
    @Test func transferRequestsRequireBoundedSequentialFields() {
        let transferID = UUID()
        let valid = AutomationRequest(
            token: "token",
            origin: .localCLI,
            control: .transferRead,
            transferID: transferID,
            transferOffset: 0,
            transferLength: AutomationTransferPolicy.chunkBytes
        )
        do {
            try valid.validateOperation()
        } catch {
            #expect(Bool(false), "Expected a valid bounded transfer request")
        }

        let invalidRequests = [
            AutomationRequest(
                token: "token",
                origin: .localCLI,
                control: .transferRead,
                transferID: transferID,
                transferOffset: 0,
                transferLength: AutomationTransferPolicy.chunkBytes + 1
            ),
            AutomationRequest(
                token: "token",
                origin: .localCLI,
                control: .transferRead,
                transferID: transferID,
                transferOffset: nil,
                transferLength: 1
            ),
            AutomationRequest(
                token: "token",
                origin: .localCLI,
                control: .transferCancel,
                transferID: transferID,
                transferOffset: 0
            ),
            AutomationRequest(
                token: "token",
                origin: .localCLI,
                command: .search("unexpected", 1),
                transferID: transferID,
                transferOffset: 0,
                transferLength: 1
            )
        ]

        for request in invalidRequests {
            do {
                try request.validateOperation()
                #expect(Bool(false), "Expected malformed transfer request to be rejected")
            } catch AutomationRequestError.invalidTransferRequest {
                // Expected admission boundary.
            } catch {
                #expect(Bool(false), "Expected invalidTransferRequest, got \(error)")
            }
        }
    }

    @Test func streamedAttachmentRejectsBadFinalMarkerBeforeEmittingItsBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = AutomationEndpoint(containerURL: root)
        let tokens = AutomationTokenStore(endpoint: endpoint)
        let token = try tokens.create()
        let server = AutomationSocketServer(endpoint: endpoint, tokenStore: tokens)
        let descriptor = AutomationTransferDescriptor(
            kind: .attachment, size: UInt64(AutomationTransferPolicy.chunkBytes + 1)
        )
        try await server.start(
            handler: { request, _ in
                do {
                    let encoder = JSONEncoder()
                    let data: Data
                    switch request.control {
                    case .engineStatus:
                        data = try encoder.encode(AutomationRuntimeStatus(kind: .daemon, ready: true))
                    case .transferRead:
                        let offset = request.transferOffset ?? 0
                        data = try encoder.encode(AutomationTransferChunk(
                            transferID: descriptor.transferID,
                            sequence: offset / UInt64(AutomationTransferPolicy.chunkBytes), offset: offset,
                            totalBytes: descriptor.size,
                            data: offset == 0 ? Data(repeating: 0xFF, count: AutomationTransferPolicy.chunkBytes) : Data([0x00]),
                            final: false
                        ))
                    case .transferCancel:
                        return AutomationResponse(requestID: request.requestID, ok: true)
                    default:
                        guard let command = request.command, case .fetchAttachment = command else {
                            return AutomationResponse(requestID: request.requestID, ok: false, failure: .usage)
                        }
                        data = try encoder.encode(CommandResult(
                            command: command.name, data: encoder.encode(descriptor), stateRevision: 42
                        ))
                    }
                    return AutomationResponse(requestID: request.requestID, ok: true, result: data)
                } catch {
                    return AutomationResponse(requestID: request.requestID, ok: false, failure: .domain)
                }
            },
            events: { _, _ in AsyncStream { $0.finish() } }
        )
        defer { server.stop() }

        let (status, output) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Int32, Data), Never>) in
            DispatchQueue.global().async {
                var output = Data()
                let status = AutomationCLI.execute(
                    ["--no-start", "fetch-attachment", "1", "part", "--stream"],
                    endpoint: endpoint, token: token, emit: { output.append($0) }
                )
                continuation.resume(returning: (status, output))
            }
        }
        #expect(status != 0)
        #expect(output == Data(repeating: 0xFF, count: AutomationTransferPolicy.chunkBytes))
    }

    #if os(macOS)
    @Test func tlsLoopbackListenerRejectsUnpairedRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let endpoint = AutomationEndpoint(containerURL: root)
        let identity = try AutomationTLSIdentityStore(endpoint: endpoint).loadOrCreate()
        let port = try unusedLoopbackPort()
        let configuration = try AutomationRemoteConfiguration(enabled: true, bindHost: "127.0.0.1", port: port)
        let listener = try AutomationTLSListener(
            endpoint: endpoint, configuration: configuration, pairings: AutomationPairingStore(endpoint: endpoint)
        )
        try await listener.start(
            handler: { request, _ in AutomationResponse(requestID: request.requestID, ok: true) },
            events: { _, _ in AsyncStream { $0.finish() } }
        )
        defer { listener.stop() }

        let client = try AutomationTLSSocketClient(
            host: "127.0.0.1", port: port, bearerToken: "unpaired-token", pinnedFingerprint: identity.fingerprint
        )
        let response = try await client.request(
            AutomationRequest(token: "unpaired-token", origin: .pairedRemote, command: .search("private", 1))
        )
        #expect(!response.ok)
        #expect(response.failure == .authorization)
    }
    #endif

}



private actor HandlerCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

#if os(macOS)
private func unusedLoopbackPort() throws -> UInt16 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    try withUnsafeMutablePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            try #require(Darwin.bind(descriptor, pointer, length) == 0)
            try #require(Darwin.getsockname(descriptor, pointer, &length) == 0)
        }
    }
    return UInt16(bigEndian: address.sin_port)
}
#endif
