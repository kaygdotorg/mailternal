import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(Darwin)
import Darwin
private let automationStreamSocketType = SOCK_STREAM
#elseif canImport(Glibc)
import Glibc
private let automationStreamSocketType = Int32(SOCK_STREAM.rawValue)
#endif

#if canImport(Network)
import Network
#endif

public struct AutomationEndpoint: Hashable, Sendable {
    public let containerURL: URL
    public let socketURL: URL
    public let tokenURL: URL
    public let lockURL: URL
    public let pairingURL: URL
    public let clientPairingURL: URL
    public let tlsIdentityURL: URL
    public let remoteConfigurationURL: URL

    public init(containerURL: URL) {
        let root = containerURL.standardizedFileURL
        self.containerURL = root
        self.tokenURL = root.appendingPathComponent("mailternal.token")
        self.lockURL = root.appendingPathComponent("mailternal.runtime.lock")
        self.pairingURL = root.appendingPathComponent("mailternal.automation-pairing.json")
        self.clientPairingURL = root.appendingPathComponent("mailternal.automation-client.json")
        self.tlsIdentityURL = root.appendingPathComponent("mailternal.automation-identity.json")
        self.remoteConfigurationURL = root.appendingPathComponent("mailternal.automation-remote.json")
        let candidate = root.appendingPathComponent("mailternal.sock")
        self.socketURL = Self.compactSocketURL(for: candidate, containerURL: root)
    }
    private static func compactSocketURL(for candidate: URL, containerURL: URL) -> URL {
#if canImport(Darwin) || canImport(Glibc)
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard candidate.path.utf8.count > limit else { return candidate }
#if canImport(CryptoKit)
        let digest = Data(SHA256.hash(data: Data(containerURL.path.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
#else
        var fallback: UInt64 = 14_695_981_039_346_656_037
        for byte in containerURL.path.utf8 {
            fallback ^= UInt64(byte)
            fallback &*= 1_099_511_628_211
        }
        let digest = String(fallback, radix: 16)
#endif
        let namespace = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("mailternal-automation-\(geteuid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespace.path)
        guard automationSocketNamespaceIsPrivate(namespace) else { return candidate }
        let socket = namespace.appendingPathComponent("mailternal-\(digest).sock")
        return socket.path.utf8.count <= limit ? socket : candidate
#else
        return candidate
#endif
    }
}

public enum AutomationSecurityError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case insecurePermissions(URL)
    case socketUnavailable
    case runtimeOwned
    case runtimeNotOwned
    case pathTooLong
    case malformedFrame
    case requestTooLarge
    case connectionLimit
    case remoteDisabled
    case tlsUnavailable
    case notPaired
    case invalidConfiguration
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "The automation token is invalid."
        case .insecurePermissions(let url): "Automation credentials have insecure permissions: \(url.path)."
        case .socketUnavailable: "The Mailternal automation socket is unavailable."
        case .runtimeOwned: "Another Mailternal runtime already owns this container."
        case .runtimeNotOwned: "This process does not own the automation runtime lock."
        case .pathTooLong: "The automation socket path is too long."
        case .malformedFrame: "The automation request frame is malformed."
        case .requestTooLarge: "The automation request exceeds the maximum frame size."
        case .responseTooLarge: "The automation response exceeds the maximum frame size."
        case .connectionLimit: "The automation server is at its connection limit."
        case .remoteDisabled: "Remote automation is disabled."
        case .tlsUnavailable: "TLS automation is unavailable on this platform."
        case .notPaired: "The automation client is not paired."
        case .invalidConfiguration: "The automation transport configuration is invalid."
        }
    }
}

extension AutomationFailure {
    init(error: any Error) {
        if let commandError = error as? AutomationCommandError {
            self = commandError.failure
        } else if error is AutomationRequestError {
            self = .usage
        } else if let securityError = error as? AutomationSecurityError {
            switch securityError {
            case .invalidToken, .insecurePermissions, .notPaired:
                self = .authorization
            case .socketUnavailable, .runtimeOwned, .runtimeNotOwned,
                 .connectionLimit, .remoteDisabled, .tlsUnavailable:
                self = .unavailable
            case .pathTooLong, .malformedFrame, .requestTooLarge, .invalidConfiguration:
                self = .usage
            case .responseTooLarge:
                self = .domain
            }
        } else if error is DecodingError {
            self = .usage
        } else {
            self = .domain
        }
    }
}

private let automationSocketTimeoutSeconds: Int = 30

/// Retains unread newline-delimited bytes for one socket connection.
///
/// Completed frames are copied out individually. Consumed prefixes are only
/// compacted after they become substantial, so draining coalesced frames does
/// not repeatedly copy the still-unread suffix.
/// The connection owner serializes access; the buffer is not independently
/// synchronized. Incomplete lines resume scanning at the last inspected byte.
final class AutomationFrameBuffer: @unchecked Sendable {
    private let maximumFrameBytes: Int
    private var storage: [UInt8] = []
    private var readOffset = 0
    private var scanOffset = 0
    init(maximumFrameBytes: Int = AutomationLineCodec.maximumFrameBytes) {
        self.maximumFrameBytes = maximumFrameBytes
        storage.reserveCapacity(16 * 1024)
    }

    func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        storage.append(contentsOf: bytes)
    }

    func nextFrame() throws -> Data? {
        guard readOffset < storage.count else { return nil }
        guard let newline = storage[scanOffset...].firstIndex(of: 0x0A) else {
            scanOffset = storage.count
            guard storage.count - readOffset <= maximumFrameBytes else {
                throw AutomationSecurityError.requestTooLarge
            }
            return nil
        }
        guard newline - readOffset <= maximumFrameBytes else {
            throw AutomationSecurityError.requestTooLarge
        }
        let frame = Data(storage[readOffset..<newline])
        readOffset = newline + 1
        scanOffset = readOffset
        compactIfNeeded()
        return frame
    }

    private func compactIfNeeded() {
        guard readOffset > 0 else { return }
        if readOffset == storage.count {
            storage.removeAll(keepingCapacity: true)
            readOffset = 0
            scanOffset = 0
        } else if readOffset >= 16 * 1024, readOffset >= storage.count / 2 {
            storage.removeFirst(readOffset)
            readOffset = 0
            scanOffset = 0
        }
    }
}

private func automationRetryingRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int) -> Int {
#if canImport(Darwin) || canImport(Glibc)
    while true {
        let result = read(fd, buffer, length)
        if result < 0 && errno == EINTR { continue }
        return result
    }
#else
    return -1
#endif
}

private func automationWriteFile(_ fd: Int32, _ data: Data) throws {
#if canImport(Darwin) || canImport(Glibc)
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { raw in
            write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw AutomationSecurityError.socketUnavailable }
        offset += count
    }
#else
    throw AutomationSecurityError.socketUnavailable
#endif
}

#if canImport(Darwin) || canImport(Glibc)
/// Older app versions created their data directory with the default umask.
/// Tighten that owned directory through a no-follow descriptor before exposing
/// automation files; never repair a symlink or a foreign user's directory.
private func automationPrepareDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw AutomationSecurityError.insecurePermissions(url) }
    defer { _ = close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0,
          (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          status.st_uid == geteuid() else {
        throw AutomationSecurityError.insecurePermissions(url)
    }
    if status.st_mode & 0o077 != 0 {
        guard fchmod(fd, mode_t(0o700)) == 0 else {
            throw AutomationSecurityError.insecurePermissions(url)
        }
    }
}

private func automationSocketNamespaceIsPrivate(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0 &&
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
        status.st_uid == geteuid() &&
        status.st_nlink >= 2 &&
        status.st_mode & 0o077 == 0
}

func automationValidateOpenFile(_ fd: Int32, _ url: URL) throws {
    var status = stat()
    guard fstat(fd, &status) == 0,
          (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          status.st_uid == geteuid(),
          status.st_nlink == 1,
          status.st_mode & 0o077 == 0,
          status.st_size <= 512 else {
        throw AutomationSecurityError.insecurePermissions(url)
    }
}

private func automationReadFile(_ fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw in
            automationRetryingRead(fd, raw.baseAddress!, raw.count)
        }
        if count == 0 { return data }
        guard count > 0 else { throw AutomationSecurityError.socketUnavailable }
        data.append(contentsOf: buffer.prefix(count))
    }
}
#endif

#if canImport(Darwin) || canImport(Glibc)
private func automationSocketFlags() -> Int32 {
#if canImport(Glibc)
    return Int32(MSG_NOSIGNAL)
#else
    return 0
#endif
}

private func automationSend(_ fd: Int32, _ data: Data) throws {
    var offset = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { raw in
            send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, automationSocketFlags())
        }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw AutomationSecurityError.socketUnavailable }
        offset += count
    }
}
private func automationReadFrame(_ fd: Int32, using frameBuffer: AutomationFrameBuffer) throws -> Data {
    if let frame = try frameBuffer.nextFrame() { return frame }
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(automationSocketTimeoutSeconds) * 1_000_000_000
    while true {
        var descriptor = pollfd()
        descriptor.fd = fd
        descriptor.events = Int16(POLLIN | POLLHUP | POLLERR)
        descriptor.revents = 0
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw AutomationSecurityError.socketUnavailable }
            let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
            let result = poll(&descriptor, 1, Int32(min(remainingMilliseconds, Int(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw AutomationSecurityError.socketUnavailable }
            break
        }
        let count = buffer.withUnsafeMutableBytes { raw in
            automationRetryingRead(fd, raw.baseAddress!, raw.count)
        }
        if count == 0 { throw AutomationSecurityError.socketUnavailable }
        guard count > 0 else { throw AutomationSecurityError.socketUnavailable }
        frameBuffer.append(buffer[0..<count])
        if let frame = try frameBuffer.nextFrame() { return frame }
    }
}

private func automationSetTimeouts(_ fd: Int32) {
    var timeout = timeval(tv_sec: automationSocketTimeoutSeconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
#if canImport(Darwin)
    var noSIGPIPE: Int32 = 1
    _ = withUnsafePointer(to: &noSIGPIPE) {
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }
#endif
}
#endif

/// The token is generated per app launch and is never derived from account data.
public final class AutomationTokenStore: @unchecked Sendable {
    public let endpoint: AutomationEndpoint

    public init(endpoint: AutomationEndpoint) { self.endpoint = endpoint }

    public func create() throws -> String {
        let token = Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }).base64EncodedString()
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try automationPrepareDirectory(endpoint.containerURL)
#if canImport(Darwin) || canImport(Glibc)
        let flags = O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW
        let fd = open(endpoint.tokenURL.path, flags, mode_t(0o600))
        guard fd >= 0 else { throw AutomationSecurityError.socketUnavailable }
        defer { _ = close(fd) }
        try automationValidateOpenFile(fd, endpoint.tokenURL)
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw AutomationSecurityError.insecurePermissions(endpoint.tokenURL) }
        guard ftruncate(fd, 0) == 0 else { throw AutomationSecurityError.socketUnavailable }
        try automationWriteFile(fd, Data(token.utf8))
#else
        try token.data(using: .utf8)!.write(to: endpoint.tokenURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpoint.tokenURL.path)
#endif
        return token
    }
    public func read() throws -> String {
#if canImport(Darwin) || canImport(Glibc)
        let fd = open(endpoint.tokenURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { throw AutomationSecurityError.socketUnavailable }
            throw AutomationSecurityError.insecurePermissions(endpoint.tokenURL)
        }
        defer { _ = close(fd) }
        try automationValidateOpenFile(fd, endpoint.tokenURL)
        return try String(decoding: automationReadFile(fd), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
#else
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: endpoint.tokenURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw AutomationSecurityError.insecurePermissions(endpoint.tokenURL)
        }
        return try String(contentsOf: endpoint.tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
#endif
    }

    public func validate(_ candidate: String) -> Bool {
        guard let expected = try? read() else { return false }
        return Self.constantTimeEqual(Data(expected.utf8), Data(candidate.utf8))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}

/// One runtime owns the container through an OS descriptor lock. The lock file
/// intentionally remains after release: flock ownership, not file existence,
/// is the authority and therefore survives SIGKILL without bricking restart.
public final class AutomationRuntimeLease: @unchecked Sendable {
    public let endpoint: AutomationEndpoint
    private var descriptor: Int32 = -1
    private let lock = NSLock()

    public init(endpoint: AutomationEndpoint) { self.endpoint = endpoint }

    public func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor < 0 else { return }
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try automationPrepareDirectory(endpoint.containerURL)
#if canImport(Darwin) || canImport(Glibc)
        let fd = open(endpoint.lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AutomationSecurityError.socketUnavailable }
        do {
            try automationValidateOpenFile(fd, endpoint.lockURL)
        } catch {
            _ = close(fd)
            throw error
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            if errno == EWOULDBLOCK || errno == EAGAIN { throw AutomationSecurityError.runtimeOwned }
            throw AutomationSecurityError.socketUnavailable
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            _ = flock(fd, LOCK_UN); _ = close(fd)
            throw AutomationSecurityError.insecurePermissions(endpoint.lockURL)
        }
        descriptor = fd
        _ = ftruncate(fd, 0)
        let pid = Data(String(getpid()).utf8)
        try? automationWriteFile(fd, pid)
#else
        throw AutomationSecurityError.socketUnavailable
#endif
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard descriptor >= 0 else { return }
#if canImport(Darwin) || canImport(Glibc)
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
#endif
        descriptor = -1
    }

    public var isOwner: Bool { lock.withLock { descriptor >= 0 } }
    deinit { release() }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

/// Newline-delimited JSON with an explicit bounded frame size.
public enum AutomationLineCodec {
    public static let maximumFrameBytes = 4 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encode(value, oversizedError: .requestTooLarge)
    }

    public static func encode(_ response: AutomationResponse) throws -> Data {
        try encode(response, oversizedError: .responseTooLarge)
    }

    private static func encode<T: Encodable>(_ value: T,
                                             oversizedError: AutomationSecurityError) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(value)
        guard data.count <= maximumFrameBytes - 1 else { throw oversizedError }
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumFrameBytes else { throw AutomationSecurityError.requestTooLarge }
        let body = data.prefix { $0 != 0x0A }
        guard !body.isEmpty else { throw AutomationSecurityError.malformedFrame }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: body)
    }
}

#if canImport(Darwin) || canImport(Glibc)
private func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    let offset = MemoryLayout<sockaddr_un>.size - pathCapacity
    let maximum = pathCapacity - 1
    guard pathBytes.count <= maximum else { throw AutomationSecurityError.pathTooLong }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: UInt8.self, capacity: pathCapacity) { bytes in
            pathBytes.withUnsafeBytes { source in
                memcpy(bytes, source.baseAddress!, pathBytes.count)
                bytes[pathBytes.count] = 0
            }
        }
    }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(offset + pathBytes.count + 1))
        }
    }
}

@inline(__always)
private func automationConnect(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
#if canImport(Darwin)
    return Darwin.connect(descriptor, address, length)
#elseif canImport(Glibc)
    return Glibc.connect(descriptor, address, length)
#else
    return -1
#endif
}

private final class AutomationSocketConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private let frameLock = NSLock()
    private let frameBuffer = AutomationFrameBuffer()
    private var descriptor: Int32
    private var activeOperations = 0
    private var closing = false

    init(descriptor: Int32) { self.descriptor = descriptor }

    func close() {
        condition.lock()
        guard descriptor >= 0, !closing else {
            condition.unlock()
            return
        }
        closing = true
        _ = shutdown(descriptor, CInt(SHUT_RDWR))
        while activeOperations > 0 {
            condition.wait()
        }
#if canImport(Darwin)
        _ = Darwin.close(descriptor)
#elseif canImport(Glibc)
        _ = Glibc.close(descriptor)
#endif
        descriptor = -1
        condition.broadcast()
        condition.unlock()
    }

    func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        condition.lock()
        guard descriptor >= 0, !closing else {
            condition.unlock()
            throw AutomationSecurityError.socketUnavailable
        }
        let fd = descriptor
        activeOperations += 1
        condition.unlock()
        defer {
            condition.lock()
            activeOperations -= 1
            if activeOperations == 0 { condition.broadcast() }
            condition.unlock()
        }
        return try body(fd)
    }

    func readFrame() throws -> Data {
        try withDescriptor { fd in
            try frameLock.withLock {
                try automationReadFrame(fd, using: frameBuffer)
            }
        }
    }

    deinit { close() }
}

public final class AutomationSocketClient: @unchecked Sendable {
    public let endpoint: AutomationEndpoint
    public init(endpoint: AutomationEndpoint) { self.endpoint = endpoint }
    public func request(_ request: AutomationRequest) throws -> AutomationResponse {
        let connection = try connect()
        defer { connection.close() }
        let output = try AutomationLineCodec.encode(request)
        try connection.withDescriptor { try automationSend($0, output) }
        let frame = try connection.readFrame()
        return try AutomationLineCodec.decode(AutomationResponse.self, from: frame)
    }

    public func request(_ request: AutomationRequest) async throws -> AutomationResponse {
        let connection = try connect()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [connection] in
                defer { connection.close() }
                let output = try AutomationLineCodec.encode(request)
                try connection.withDescriptor { try automationSend($0, output) }
                let frame = try connection.readFrame()
                return try AutomationLineCodec.decode(AutomationResponse.self, from: frame)
            }.value
        } onCancel: {
            connection.close()
        }
    }

    /// Sends one observer request, then yields every ordered response until the
    /// server closes the stream or the task is cancelled.
    public func observe(
        _ request: AutomationRequest,
        onResponse: @escaping @Sendable (AutomationResponse) async -> Void
    ) async throws {
        let connection = try connect()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [connection] in
                defer { connection.close() }
                let observerRequest = AutomationRequest(
                    requestID: request.requestID, token: request.token, origin: request.origin,
                    clientID: request.clientID, command: request.command, control: request.control,
                    wantsState: request.wantsState, wantsGUIState: request.wantsGUIState,
                    observesState: true,
                    afterRevision: request.afterRevision, secret: request.secret,
                    pairingCode: request.pairingCode,
                    pairingClientName: request.pairingClientName,
                    pairingGrant: request.pairingGrant,
                    transferID: request.transferID,
                    transferOffset: request.transferOffset,
                    transferLength: request.transferLength,
                    transferSequence: request.transferSequence,
                    transferTotalBytes: request.transferTotalBytes,
                    transferData: request.transferData,
                    transferFinal: request.transferFinal,
                    transferFilename: request.transferFilename,
                    transferContentType: request.transferContentType
                )
                let output = try AutomationLineCodec.encode(observerRequest)
                try connection.withDescriptor { try automationSend($0, output) }
                while true {
                    let frame = try connection.readFrame()
                    let response = try AutomationLineCodec.decode(AutomationResponse.self, from: frame)
                    await onResponse(response)
                }
            }.value
        } onCancel: {
            connection.close()
        }
    }

    private func connect() throws -> AutomationSocketConnection {
        let fd = socket(AF_UNIX, automationStreamSocketType, 0)
        guard fd >= 0 else { throw AutomationSecurityError.socketUnavailable }
        automationSetTimeouts(fd)
        do {
            try withUnixAddress(endpoint.socketURL.path) { pointer, length in
                while automationConnect(fd, pointer, length) != 0 {
                    if errno == EINTR { continue }
                    throw AutomationSecurityError.socketUnavailable
                }
            }
            return AutomationSocketConnection(descriptor: fd)
        } catch {
#if canImport(Darwin)
            _ = Darwin.close(fd)
#elseif canImport(Glibc)
            _ = Glibc.close(fd)
#endif
            throw error
        }
    }
}

/// Bounded Unix-domain JSON server. The asynchronous serving path is kept
/// separate from accept() so app actors are never blocked by socket I/O.
public final class AutomationSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AutomationRequest, AutomationClientContext) async -> AutomationResponse
    public typealias Events = @Sendable (AutomationRequest, AutomationClientContext) async -> AsyncStream<AutomationResponse>

    public let endpoint: AutomationEndpoint
    private let tokenStore: AutomationTokenStore
    private var descriptor: Int32 = -1
    private var socketFileNumber: UInt64?
    private let lock = NSLock()
    private let activeConnections = DispatchSemaphore(value: 32)

    public init(endpoint: AutomationEndpoint, tokenStore: AutomationTokenStore) {
        self.endpoint = endpoint
        self.tokenStore = tokenStore
    }
    public func start(handler: @escaping Handler, events: @escaping Events) async throws {
        try startSynchronous(handler: handler, events: events)
    }

    private func startSynchronous(handler: @escaping Handler, events: @escaping Events) throws {
        lock.lock(); defer { lock.unlock() }
        guard descriptor < 0 else { return }
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try removeStaleSocketIfSafe()
        let fd = socket(AF_UNIX, automationStreamSocketType, 0)
        guard fd >= 0 else { throw AutomationSecurityError.socketUnavailable }
        var didBind = false
        do {
            try withUnixAddress(endpoint.socketURL.path) { pointer, length in
                guard bind(fd, pointer, length) == 0 else { throw AutomationSecurityError.socketUnavailable }
                didBind = true
            }
            guard chmod(endpoint.socketURL.path, mode_t(0o600)) == 0,
                  listen(fd, 32) == 0 else { throw AutomationSecurityError.socketUnavailable }
            automationSetTimeouts(fd)
            descriptor = fd
            socketFileNumber = Self.fileNumber(at: endpoint.socketURL)
            let queue = DispatchQueue(label: "org.kayg.mailternal.automation.accept", qos: .userInitiated)
            queue.async { [weak self] in self?.acceptLoop(fd: fd, handler: handler, events: events) }
        } catch {
            _ = close(fd)
            if didBind { try? FileManager.default.removeItem(at: endpoint.socketURL) }
            throw error
        }
    }

    public func stop() {
        let fd: Int32?
        lock.lock()
        fd = descriptor >= 0 ? descriptor : nil
        descriptor = -1
        lock.unlock()
        guard let fd else { return }
        _ = shutdown(fd, CInt(SHUT_RDWR))
        _ = close(fd)
        unlinkOwnedSocket()
    }

    private func acceptLoop(fd: Int32, handler: @escaping Handler, events: @escaping Events) {
        while lock.withLock({ descriptor == fd }) {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if lock.withLock({ descriptor != fd }) { break }
                continue
            }
            guard activeConnections.wait(timeout: .now()) == .success else {
                _ = shutdown(client, CInt(SHUT_RDWR)); _ = close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                Task { [weak self] in
                    defer { self?.activeConnections.signal() }
                    await self?.serve(client: client, handler: handler, events: events)
                }
            }
        }
    }

    private func serve(client: Int32, handler: @escaping Handler, events: @escaping Events) async {
        defer { _ = shutdown(client, CInt(SHUT_RDWR)); _ = close(client) }
        automationSetTimeouts(client)
        let frameBuffer = AutomationFrameBuffer()
        var requestID = UUID()
        do {
            let requestData = try automationReadFrame(client, using: frameBuffer)
            let request = try AutomationLineCodec.decode(AutomationRequest.self, from: requestData)
            requestID = request.requestID
            guard request.schema == AutomationProtocol.commandSchema,
                  request.version == AutomationProtocol.version else {
                try send(AutomationResponse(requestID: request.requestID, ok: false,
                                            error: "Unsupported automation protocol.", failure: .usage), to: client)
                return
            }
            guard tokenStore.validate(request.token) else {
                try send(AutomationResponse(requestID: request.requestID, ok: false,
                                            error: AutomationSecurityError.invalidToken.localizedDescription,
                                            failure: .authorization), to: client)
                return
            }
            try request.validateOperation()
            let context = AutomationClientContext(
                origin: .localCLI,
                grant: .local,
                clientID: request.clientID.flatMap(UUID.init(uuidString:))
            )
            if request.observesState {
                let stream = await events(request, context)
                let eventTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        for await response in stream {
                            try self.send(response, to: client)
                            if Task.isCancelled { break }
                        }
                    } catch {
                        _ = shutdown(client, CInt(SHUT_RDWR))
                    }
                }
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await Self.waitForDisconnect(client) }
                    group.addTask {
                        await eventTask.value
                        return false
                    }
                    _ = await group.next()
                    eventTask.cancel()
                    group.cancelAll()
                }
                eventTask.cancel()
            } else {
                try send(await handler(request, context), to: client)
            }
        } catch {
            let response = AutomationResponse(
                requestID: requestID, ok: false, error: error.localizedDescription,
                failure: AutomationFailure(error: error)
            )
            try? send(response, to: client)
        }
    }

    private static func waitForDisconnect(_ client: Int32) async -> Bool {
        let monitor = dup(client)
        guard monitor >= 0 else { return false }
        defer { _ = close(monitor) }
        let flags = fcntl(monitor, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(monitor, F_SETFL, flags | O_NONBLOCK) }
        while !Task.isCancelled {
            var descriptor = pollfd()
            descriptor.fd = monitor
            descriptor.events = Int16(POLLIN | POLLHUP | POLLERR)
            descriptor.revents = 0
            let result = poll(&descriptor, 1, 1_000)
            if result < 0 {
                if errno == EINTR { continue }
                _ = shutdown(client, CInt(SHUT_RDWR))
                return true
            }
            guard result > 0 else { continue }
            var byte: UInt8 = 0
            let count = withUnsafeMutablePointer(to: &byte) { pointer in
                read(monitor, pointer, 1)
            }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                _ = shutdown(client, CInt(SHUT_RDWR))
                return true
            }
        }
        return false
    }

    private func send(_ response: AutomationResponse, to client: Int32) throws {
        do {
            try automationSend(client, AutomationLineCodec.encode(response))
        } catch AutomationSecurityError.responseTooLarge {
            let fallback = AutomationResponse(requestID: response.requestID, ok: false,
                                              error: AutomationSecurityError.responseTooLarge.localizedDescription,
                                              failure: .domain)
            try automationSend(client, AutomationLineCodec.encode(fallback))
        }
    }

    private func removeStaleSocketIfSafe() throws {
        guard FileManager.default.fileExists(atPath: endpoint.socketURL.path) else { return }
        let probe = socket(AF_UNIX, automationStreamSocketType, 0)
        automationSetTimeouts(probe)
        defer { _ = close(probe) }
        let connected = (try? withUnixAddress(endpoint.socketURL.path) { pointer, length in
            while connect(probe, pointer, length) != 0 {
                if errno == EINTR { continue }
                return false
            }
            return true
        }) ?? false
        if connected { throw AutomationSecurityError.runtimeOwned }
        let attributes = try? FileManager.default.attributesOfItem(atPath: endpoint.socketURL.path)
        guard (attributes?[.type] as? FileAttributeType) == .typeSocket else {
            throw AutomationSecurityError.socketUnavailable
        }
        try FileManager.default.removeItem(at: endpoint.socketURL)
    }

    private func unlinkOwnedSocket() {
        guard let expected = socketFileNumber,
              let actual = Self.fileNumber(at: endpoint.socketURL),
              actual == expected else { return }
        try? FileManager.default.removeItem(at: endpoint.socketURL)
    }

    private static func fileNumber(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return number.uint64Value
    }

    deinit { stop() }
}
#endif
