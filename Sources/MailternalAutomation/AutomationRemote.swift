import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if canImport(Network)
import Network
#endif

#if canImport(Security)
import Security
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct AutomationRemoteConfiguration: Codable, Equatable, Hashable, Sendable {
    public let enabled: Bool
    public let bindHost: String
    public let port: UInt16
    public let allowWildcard: Bool

    public init(enabled: Bool = false, bindHost: String, port: UInt16,
                allowWildcard: Bool = false) throws {
        let host = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !enabled || port != 0 else { throw AutomationSecurityError.invalidConfiguration }
        let wildcard = Self.isWildcardHost(host)
        guard !wildcard || allowWildcard else { throw AutomationSecurityError.invalidConfiguration }
        self.enabled = enabled
        self.bindHost = host
        self.port = port
        self.allowWildcard = allowWildcard
    }

    private static func isWildcardHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "*" { return true }
#if canImport(Darwin) || canImport(Glibc)
        if !normalized.contains(":") {
            var address = in_addr()
            let parsed = normalized.withCString { inet_pton(AF_INET, $0, &address) }
            if parsed == 1, address.s_addr == 0 { return true }
            if normalized.allSatisfy({ $0.isNumber || $0 == "." }) {
                let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
                if octets.count == 4, octets.allSatisfy({ octet in
                    guard let value = Int(octet) else { return false }
                    return value == 0
                }) { return true }
            }
            return false
        }
        guard normalized.contains(":") else { return false }
        var address = in6_addr()
        let parsed = normalized.withCString { inet_pton(AF_INET6, $0, &address) }
        if parsed == 1 {
            return withUnsafeBytes(of: &address) { bytes in
                bytes.allSatisfy { $0 == 0 }
            }
        }
#endif
        return normalized == "0.0.0.0" || normalized == "::"
    }

    public static var disabled: AutomationRemoteConfiguration {
        // A disabled configuration is still explicit about its eventual bind.
        try! AutomationRemoteConfiguration(bindHost: "127.0.0.1", port: 0)
    }
}

public final class AutomationRemoteConfigurationStore: @unchecked Sendable {
    public let endpoint: AutomationEndpoint
    private let lock = NSLock()

    public init(endpoint: AutomationEndpoint) { self.endpoint = endpoint }

    public func load() throws -> AutomationRemoteConfiguration {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: endpoint.remoteConfigurationURL.path) else {
            return .disabled
        }
        try AutomationProtectedFile.requirePrivate(endpoint.remoteConfigurationURL)
        let data = try Data(contentsOf: endpoint.remoteConfigurationURL)
        let decoded = try JSONDecoder().decode(AutomationRemoteConfiguration.self, from: data)
        return try AutomationRemoteConfiguration(enabled: decoded.enabled, bindHost: decoded.bindHost,
                                                 port: decoded.port, allowWildcard: decoded.allowWildcard)
    }

    public func save(_ configuration: AutomationRemoteConfiguration) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(configuration)
        try AutomationProtectedFile.write(data, to: endpoint.remoteConfigurationURL)
    }
}

public struct AutomationPairedClient: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let grant: AutomationGrant
    public let tokenDigest: Data
    public let createdAt: Date
    public var revokedAt: Date?

    public init(id: UUID = UUID(), grant: AutomationGrant, tokenDigest: Data,
                createdAt: Date = Date(), revokedAt: Date? = nil) {
        self.id = id
        self.grant = grant
        self.tokenDigest = tokenDigest
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }
}

public struct AutomationPairingOffer: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let grant: AutomationGrant
    public let codeDigest: Data
    public let createdAt: Date
    public let expiresAt: Date
    public var consumedAt: Date?

    fileprivate init(id: UUID = UUID(), grant: AutomationGrant, codeDigest: Data,
                     createdAt: Date = Date(), expiresAt: Date, consumedAt: Date? = nil) {
        self.id = id
        self.grant = grant
        self.codeDigest = codeDigest
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
    }
}

public struct AutomationPairingOfferMaterial: Sendable, Equatable {
    public let offer: AutomationPairingOffer
    /// The one-time code is returned only to the local authorized creator.
    public let code: String

    fileprivate init(offer: AutomationPairingOffer, code: String) {
        self.offer = offer
        self.code = code
    }
}

public struct AutomationPairingMaterial: Sendable, Equatable {
    public let client: AutomationPairedClient
    /// Returned only at enrollment and intended for protected client storage.
    public let bearerToken: String

    public init(client: AutomationPairedClient, bearerToken: String) {
        self.client = client
        self.bearerToken = bearerToken
    }
}

public struct AutomationPairedEndpoint: Codable, Equatable, Hashable, Sendable {
    public let clientID: UUID
    public let host: String
    public let port: UInt16
    public let bearerToken: String
    public let pinnedFingerprint: String

    public init(clientID: UUID, host: String, port: UInt16, bearerToken: String,
                pinnedFingerprint: String) throws {
        guard !host.isEmpty, port != 0, pinnedFingerprint.count == 64 else {
            throw AutomationSecurityError.invalidConfiguration
        }
        self.clientID = clientID
        self.host = host
        self.port = port
        self.bearerToken = bearerToken
        self.pinnedFingerprint = pinnedFingerprint.lowercased()
    }
}

/// Protected client-side storage for the bearer/fingerprint delivered by
/// pairing. It is deliberately separate from account-transfer PairingBundle.
public final class AutomationPairedEndpointStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(endpoint: AutomationEndpoint) {
        self.fileURL = endpoint.clientPairingURL
    }

    public func load() throws -> AutomationPairedEndpoint {
        lock.lock(); defer { lock.unlock() }
        try AutomationProtectedFile.requirePrivate(fileURL)
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AutomationPairedEndpoint.self, from: data)
    }

    public func save(_ record: AutomationPairedEndpoint) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AutomationProtectedFile.write(try JSONEncoder().encode(record), to: fileURL)
    }

    public func revoke() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public final class AutomationPairingStore: @unchecked Sendable {
    public let endpoint: AutomationEndpoint
    private var clients: [AutomationPairedClient]
    private var offers: [AutomationPairingOffer]
    private let lock = NSLock()

    private var offerURL: URL {
        endpoint.containerURL.appendingPathComponent("mailternal.automation-pairing-offers.json")
    }

    public init(endpoint: AutomationEndpoint) throws {
        self.endpoint = endpoint
        self.clients = []
        self.offers = []
        try reloadLocked()
        try reloadOffersLocked()
    }

    public func list() -> [AutomationPairedClient] {
        lock.withLock {
            try? reloadLocked()
            return clients
        }
    }

    public func enroll(grant: AutomationGrant) throws -> AutomationPairingMaterial {
        let token = AutomationTokenDigest.randomToken()
        guard let digest = AutomationTokenDigest.make(token) else { throw AutomationSecurityError.tlsUnavailable }
        lock.lock(); defer { lock.unlock() }
        return try withPersistentLock {
            try reloadLocked()
            guard clients.lazy.filter({ $0.revokedAt == nil }).count < 256 else { throw AutomationSecurityError.connectionLimit }
            let client = AutomationPairedClient(grant: grant, tokenDigest: digest)
            clients.append(client)
            do {
                try persistLocked()
            } catch {
                clients.removeAll { $0.id == client.id }
                throw error
            }
            return AutomationPairingMaterial(client: client, bearerToken: token)
        }
    }

    /// Creates a short-lived offer whose capability grant remains server-side.
    /// Only the local authenticated runtime may call this method.
    public func createOffer(grant: AutomationGrant, lifetime: TimeInterval = 300) throws -> AutomationPairingOfferMaterial {
        guard lifetime > 0, lifetime <= 900 else { throw AutomationSecurityError.invalidConfiguration }
        let code = AutomationPairingStore.makeOfferCode()
        guard let digest = AutomationTokenDigest.make(code) else { throw AutomationSecurityError.tlsUnavailable }
        let now = Date()
        let offer = AutomationPairingOffer(grant: grant, codeDigest: digest,
                                           createdAt: now, expiresAt: now.addingTimeInterval(lifetime))
        lock.lock(); defer { lock.unlock() }
        return try withPersistentLock {
            try reloadOffersLocked()
            offers.removeAll { $0.expiresAt <= now || $0.consumedAt != nil }
            guard offers.count < 64 else { throw AutomationSecurityError.connectionLimit }
            offers.append(offer)
            try persistOffersLocked()
            return AutomationPairingOfferMaterial(offer: offer, code: code)
        }
    }

    public func consumeOffer(code rawCode: String) throws -> AutomationPairingMaterial {
        let code = Self.normalizeOfferCode(rawCode)
        guard !code.isEmpty, let digest = AutomationTokenDigest.make(code) else {
            throw AutomationSecurityError.notPaired
        }
        lock.lock(); defer { lock.unlock() }
        return try withPersistentLock {
            try reloadLocked()
            try reloadOffersLocked()
            let now = Date()
            guard let offerIndex = offers.firstIndex(where: {
                $0.consumedAt == nil && $0.expiresAt > now &&
                AutomationTokenDigest.equal($0.codeDigest, digest)
            }) else {
                throw AutomationSecurityError.notPaired
            }
            let offer = offers[offerIndex]
            let bearer = AutomationTokenDigest.randomToken()
            guard let tokenDigest = AutomationTokenDigest.make(bearer) else {
                throw AutomationSecurityError.tlsUnavailable
            }
            guard clients.lazy.filter({ $0.revokedAt == nil }).count < 256 else { throw AutomationSecurityError.connectionLimit }
            let client = AutomationPairedClient(grant: offer.grant, tokenDigest: tokenDigest)
            clients.append(client)
            offers[offerIndex].consumedAt = now
            do {
                try persistLocked()
                try persistOffersLocked()
            } catch {
                clients.removeAll { $0.id == client.id }
                offers[offerIndex].consumedAt = nil
                try? persistLocked()
                try? persistOffersLocked()
                throw error
            }
            return AutomationPairingMaterial(client: client, bearerToken: bearer)
        }
    }

    @discardableResult
    public func revoke(clientID: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try withPersistentLock {
            try reloadLocked()
            guard let index = clients.firstIndex(where: { $0.id == clientID && $0.revokedAt == nil }) else { return false }
            let previous = clients[index].revokedAt
            clients[index].revokedAt = Date()
            do {
                try persistLocked()
            } catch {
                clients[index].revokedAt = previous
                throw error
            }
            return true
        }
    }
    public func context(forBearer token: String) -> AutomationClientContext? {
        guard let digest = AutomationTokenDigest.make(token) else { return nil }
        return lock.withLock {
            guard (try? withPersistentLock({ try reloadLocked() })) != nil,
                  let client = clients.first(where: { $0.revokedAt == nil &&
                    AutomationTokenDigest.equal($0.tokenDigest, digest) }) else { return nil }
            return AutomationClientContext(origin: .pairedRemote, grant: client.grant, clientID: client.id)
        }
    }

    private static func makeOfferCode() -> String {
        AutomationTokenDigest.randomToken()
    }

    private static func normalizeOfferCode(_ raw: String) -> String {
        // Hyphens belong to the generated base64url alphabet, not formatting.
        raw.filter { !$0.isWhitespace }
    }

    private func reloadLocked() throws {
        guard FileManager.default.fileExists(atPath: endpoint.pairingURL.path) else {
            clients = []
            return
        }
        try AutomationProtectedFile.requirePrivate(endpoint.pairingURL)
        let data = try Data(contentsOf: endpoint.pairingURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        clients = try decoder.decode([AutomationPairedClient].self, from: data)
    }
    private func reloadOffersLocked() throws {
        guard FileManager.default.fileExists(atPath: offerURL.path) else {
            offers = []
            return
        }
        try AutomationProtectedFile.requirePrivate(offerURL)
        let data = try Data(contentsOf: offerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        offers = try decoder.decode([AutomationPairingOffer].self, from: data)
    }

    private func persistOffersLocked() throws {
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AutomationProtectedFile.write(try encoder.encode(offers), to: offerURL)
    }

    private func withPersistentLock<T>(_ body: () throws -> T) throws -> T {
#if canImport(Darwin) || canImport(Glibc)
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The runtime holds its lease for its whole lifetime. Pairing
        // transactions must serialize on a separate lock, including token reads.
        let lockURL = endpoint.pairingURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AutomationSecurityError.socketUnavailable }
        defer {
#if canImport(Darwin)
            _ = Darwin.close(fd)
#else
            _ = Glibc.close(fd)
#endif
        }
        try automationValidateOpenFile(fd, lockURL)
        guard flock(fd, LOCK_EX) == 0 else { throw AutomationSecurityError.socketUnavailable }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
#else
        return try body()
#endif
    }

    private func persistLocked() throws {
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try AutomationProtectedFile.write(try encoder.encode(clients), to: endpoint.pairingURL)
    }
}

private enum AutomationTokenDigest {
    static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func make(_ token: String) -> Data? {
#if canImport(CryptoKit)
        return Data(SHA256.hash(data: Data(token.utf8)))
#elseif canImport(Crypto)
        return Data(Crypto.SHA256.hash(data: Data(token.utf8)))
#else
        return nil
#endif
    }

    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

private enum AutomationProtectedFile {
    static func requirePrivate(_ url: URL) throws {
#if canImport(Darwin) || canImport(Glibc)
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_uid == geteuid(), status.st_nlink == 1,
              status.st_mode & 0o077 == 0 else {
            throw AutomationSecurityError.insecurePermissions(url)
        }
#else
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0 else {
            throw AutomationSecurityError.insecurePermissions(url)
        }
#endif
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct AutomationTLSIdentityRecord: Codable, Equatable, Sendable {
    public let certificateDER: Data
    public let privateKeyData: Data
    public let fingerprint: String
    public let createdAt: Date

    public init(certificateDER: Data, privateKeyData: Data,
                fingerprint: String, createdAt: Date = Date()) {
        self.certificateDER = certificateDER
        self.privateKeyData = privateKeyData
        self.fingerprint = fingerprint
        self.createdAt = createdAt
    }
}

public final class AutomationTLSIdentityStore: @unchecked Sendable {
    public let endpoint: AutomationEndpoint
    private let lock = NSLock()

    public init(endpoint: AutomationEndpoint) { self.endpoint = endpoint }

    public func loadOrCreate() throws -> AutomationTLSIdentityRecord {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: endpoint.tlsIdentityURL.path) {
            try AutomationProtectedFile.requirePrivate(endpoint.tlsIdentityURL)
            let record = try JSONDecoder().decode(AutomationTLSIdentityRecord.self,
                                                   from: Data(contentsOf: endpoint.tlsIdentityURL))
            guard record.fingerprint == Self.fingerprint(certificateDER: record.certificateDER) else {
                throw AutomationSecurityError.tlsUnavailable
            }
            return record
        }
#if canImport(Security) && canImport(CryptoKit)
        let record = try Self.makeIdentity()
        try FileManager.default.createDirectory(at: endpoint.containerURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AutomationProtectedFile.write(try JSONEncoder().encode(record), to: endpoint.tlsIdentityURL)
        return record
#else
        throw AutomationSecurityError.tlsUnavailable
#endif
    }

    public static func fingerprint(certificateDER: Data) -> String {
#if canImport(CryptoKit)
        return SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
#elseif canImport(Crypto)
        return Crypto.SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined()
#else
        return ""
#endif
    }

#if canImport(Security) && canImport(CryptoKit)
    private static func makeIdentity() throws -> AutomationTLSIdentityRecord {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError),
              let privateData = SecKeyCopyExternalRepresentation(key, &keyError) as Data?,
              let publicKey = SecKeyCopyPublicKey(key),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &keyError) as Data? else {
            throw AutomationSecurityError.tlsUnavailable
        }
        let tbs = Self.makeTBSCertificate(publicKey: publicData)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256,
                                                    tbs as CFData, &keyError) as Data? else {
            throw AutomationSecurityError.tlsUnavailable
        }
        var certificate = Data()
        certificate.append(DER.sequence([tbs, DER.sequence([DER.oid(Self.sha256WithECDSA), DER.null]),
                                         DER.bitString(signature)]))
        guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
            throw AutomationSecurityError.tlsUnavailable
        }
        return AutomationTLSIdentityRecord(certificateDER: certificate, privateKeyData: privateData,
                                           fingerprint: fingerprint(certificateDER: certificate))
    }

    private static let sha256WithECDSA: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]
    private static let ecPublicKey: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    private static let prime256v1: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]

    private static func makeTBSCertificate(publicKey: Data) -> Data {
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([0x55, 0x04, 0x03]), DER.utf8("Mailternal Automation")])])])
        let now = Date()
        let validity = DER.sequence([DER.utcTime(now), DER.utcTime(now.addingTimeInterval(10 * 365 * 24 * 60 * 60))])
        let serial = DER.integer(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let algorithm = DER.sequence([DER.oid(sha256WithECDSA), DER.null])
        let publicAlgorithm = DER.sequence([DER.oid(ecPublicKey), DER.oid(prime256v1)])
        let subjectKey = DER.sequence([publicAlgorithm, DER.bitString(publicKey)])
        let basicConstraints = DER.sequence([DER.oid([0x55, 0x1d, 0x13]), DER.octetString(DER.sequence([]))])
        let keyUsage = DER.sequence([DER.oid([0x55, 0x1d, 0x0f]), DER.octetString(DER.bitString(Data([0xa0])))])
        let subjectAltName = DER.sequence([DER.oid([0x55, 0x1d, 0x11]), DER.octetString(DER.sequence([DER.context(2, Data("localhost".utf8))]))])
        let extensions = DER.explicit(3, DER.sequence([basicConstraints, keyUsage, subjectAltName]))
        return DER.sequence([
            DER.explicit(0, DER.integer(Data([2]))), serial, algorithm, name, validity, name, subjectKey, extensions,
        ])
    }
#endif
}

private enum DER {
    static let null = Data([0x05, 0x00])

    static func sequence(_ values: [Data]) -> Data { tagged(0x30, values.reduce(into: Data()) { $0.append($1) }) }
    static func set(_ values: [Data]) -> Data { tagged(0x31, values.reduce(into: Data()) { $0.append($1) }) }
    static func explicit(_ tag: UInt8, _ value: Data) -> Data { tagged(0xa0 | tag, value) }
    static func context(_ tag: UInt8, _ value: Data) -> Data { tagged(0x80 | tag, value) }
    static func octetString(_ value: Data) -> Data { tagged(0x04, value) }
    static func utf8(_ value: String) -> Data { tagged(0x0c, Data(value.utf8)) }
    static func bitString(_ value: Data) -> Data { tagged(0x03, Data([0]) + value) }
    static func oid(_ value: [UInt8]) -> Data { tagged(0x06, Data(value)) }
    static func integer(_ value: Data) -> Data {
        var bytes = value
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        if bytes.first.map({ $0 & 0x80 != 0 }) == true { bytes.insert(0, at: 0) }
        return tagged(0x02, bytes)
    }
    static func utcTime(_ date: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        let value = formatter.string(from: date).replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "")
            .replacingOccurrences(of: "Z", with: "")
        let body = String(value.dropFirst(2).prefix(12)) + "Z"
        return tagged(0x17, Data(body.utf8))
    }
    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        Data([tag]) + length(value.count) + value
    }
    private static func length(_ value: Int) -> Data {
        guard value >= 128 else { return Data([UInt8(value)]) }
        var bytes = [UInt8](); var remaining = value
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xff), at: 0); remaining >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}

private final class AutomationContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

#if canImport(Network) && canImport(Security)
public final class AutomationTLSListener: @unchecked Sendable {
    public typealias Handler = AutomationSocketServer.Handler
    public typealias Events = AutomationSocketServer.Events

    private let endpoint: AutomationEndpoint
    private let configuration: AutomationRemoteConfiguration
    private let pairings: AutomationPairingStore
    private let identityStore: AutomationTLSIdentityStore
    private let queue = DispatchQueue(label: "org.kayg.mailternal.automation.tls", qos: .userInitiated)
    /// Authenticated requests/observers may use all 32 slots. TLS handshakes
    /// and bearer validation use a separate, much smaller admission pool.
    private let activeConnections = DispatchSemaphore(value: 32)
    private let preAuthConnections = DispatchSemaphore(value: 8)
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var preAuthPeers: [String: Int] = [:]
    private var activeByClient: [UUID: Int] = [:]
    private var activeAnonymous = 0
    private var identityFingerprint = ""

    public init(endpoint: AutomationEndpoint, configuration: AutomationRemoteConfiguration,
                pairings: AutomationPairingStore) {
        self.endpoint = endpoint
        self.configuration = configuration
        self.pairings = pairings
        self.identityStore = AutomationTLSIdentityStore(endpoint: endpoint)
    }
    public func start(handler: @escaping Handler, events: @escaping Events) async throws {
        guard configuration.enabled else { throw AutomationSecurityError.remoteDisabled }
        let identityRecord = try identityStore.loadOrCreate()
        identityFingerprint = identityRecord.fingerprint
        guard let identity = try Self.secIdentity(for: identityRecord),
              let localIdentity = sec_identity_create(identity) else {
            throw AutomationSecurityError.tlsUnavailable
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        let parameters = NWParameters(tls: tls)
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else { throw AutomationSecurityError.invalidConfiguration }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindHost), port: port)
        // Passing `on:` as well as the configured local endpoint fails with EINVAL.
        let listener = try NWListener(using: parameters)
        guard lock.withLock({ self.listener == nil }) else { return }
        lock.withLock { self.listener = listener }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completionState = AutomationContinuationState()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard completionState.claim() else { return }
                        continuation.resume()
                    case .failed(let error):
                        guard completionState.claim() else { return }
                        continuation.resume(throwing: error)
                    case .cancelled:
                        guard completionState.claim() else { return }
                        continuation.resume(throwing: AutomationSecurityError.socketUnavailable)
                    default:
                        break
                    }
                }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                guard self.preAuthConnections.wait(timeout: .now()) == .success else {
                    connection.cancel()
                    return
                }
                let peer = Self.peerKey(for: connection)
                guard self.reservePreAuth(peer) else {
                    self.preAuthConnections.signal()
                    connection.cancel()
                    return
                }
                self.lock.withLock {
                    self.connections[ObjectIdentifier(connection)] = connection
                }
                connection.start(queue: self.queue)
                Task {
                    defer {
                        self.lock.withLock {
                            self.connections.removeValue(forKey: ObjectIdentifier(connection))
                        }
                    }
                    await self.serve(connection, peer: peer, handler: handler, events: events)
                }
            }
            listener.start(queue: queue)
            }
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let connections = Array(self.connections.values)
        self.connections.removeAll()
        lock.unlock()
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private static func peerKey(for connection: NWConnection) -> String {
        switch connection.endpoint {
        case let .hostPort(host, _):
            return host.debugDescription.lowercased()
        default:
            return connection.endpoint.debugDescription.lowercased()
        }
    }

    private func reservePreAuth(_ peer: String) -> Bool {
        lock.withLock {
            let count = preAuthPeers[peer, default: 0]
            guard count < 2 else { return false }
            preAuthPeers[peer] = count + 1
            return true
        }
    }

    private func releasePreAuth(_ peer: String) {
        lock.withLock {
            guard let count = preAuthPeers[peer] else { return }
            if count <= 1 {
                preAuthPeers.removeValue(forKey: peer)
            } else {
                preAuthPeers[peer] = count - 1
            }
        }
    }

    private func acquireActiveConnection(clientID: UUID?) -> Bool {
        guard activeConnections.wait(timeout: .now()) == .success else { return false }
        let allowed = lock.withLock {
            if let clientID {
                let count = activeByClient[clientID, default: 0]
                guard count < 4 else { return false }
                activeByClient[clientID] = count + 1
            } else {
                guard activeAnonymous < 4 else { return false }
                activeAnonymous += 1
            }
            return true
        }
        if !allowed { activeConnections.signal() }
        return allowed
    }

    private func releaseActiveConnection(clientID: UUID?) {
        lock.withLock {
            if let clientID, let count = activeByClient[clientID] {
                if count <= 1 { activeByClient.removeValue(forKey: clientID) }
                else { activeByClient[clientID] = count - 1 }
            } else if clientID == nil, activeAnonymous > 0 {
                activeAnonymous -= 1
            }
        }
        activeConnections.signal()
    }

    private func serve(
        _ connection: NWConnection,
        peer: String,
        handler: @escaping Handler,
        events: @escaping Events
    ) async {
        var preAuthHeld = true
        var authenticated = false
        var activeClientID: UUID?
        defer {
            if preAuthHeld {
                preAuthConnections.signal()
                releasePreAuth(peer)
            }
            connection.cancel()
            if authenticated {
                releaseActiveConnection(clientID: activeClientID)
            }
        }
        var requestID: UUID?
        let frameBuffer = AutomationFrameBuffer()
        do {
            let frame = try await Self.receiveFrame(connection, using: frameBuffer, timeout: .seconds(5))
            let request = try AutomationLineCodec.decode(AutomationRequest.self, from: frame)
            requestID = request.requestID
            guard request.schema == AutomationProtocol.commandSchema,
                  request.version == AutomationProtocol.version else {
                try await Self.send(AutomationResponse(requestID: request.requestID, ok: false,
                                                        error: "Unsupported automation protocol.", failure: .usage), on: connection)
                return
            }
            if request.control == .pairingClaim {
                guard request.token.isEmpty, request.command == nil,
                      !request.wantsState, !request.wantsGUIState, !request.observesState,
                      request.afterRevision == nil, request.secret == nil,
                      request.pairingGrant == nil,
                      let pairingCode = request.pairingCode else {
                    try await Self.send(AutomationResponse(requestID: request.requestID, ok: false,
                                                            error: AutomationSecurityError.invalidToken.localizedDescription,
                                                            failure: .authorization), on: connection)
                    return
                }
                let material = try pairings.consumeOffer(code: pairingCode)
                preAuthHeld = false
                preAuthConnections.signal()
                releasePreAuth(peer)
                let endpoint = try AutomationPairedEndpoint(
                    clientID: material.client.id,
                    host: configuration.bindHost,
                    port: configuration.port,
                    bearerToken: material.bearerToken,
                    pinnedFingerprint: identityFingerprint
                )
                let result = AutomationPairingClaimResult(endpoint: endpoint)
                try await Self.send(AutomationResponse(requestID: request.requestID, ok: true,
                                                        result: try AutomationLineCodec.encode(result)), on: connection)
                return
            }
            if request.control == .pairingCreate {
                try await Self.send(AutomationResponse(requestID: request.requestID, ok: false,
                                                        error: AutomationSecurityError.invalidToken.localizedDescription,
                                                        failure: .authorization), on: connection)
                return
            }
            guard let context = pairings.context(forBearer: request.token) else {
                try await Self.send(AutomationResponse(requestID: request.requestID, ok: false,
                                                        error: AutomationSecurityError.invalidToken.localizedDescription,
                                                        failure: .authorization), on: connection)
                return
            }
            try request.validateOperation()
            preAuthHeld = false
            preAuthConnections.signal()
            releasePreAuth(peer)
            guard acquireActiveConnection(clientID: context.clientID) else {
                try await Self.send(AutomationResponse(requestID: request.requestID, ok: false,
                                                        error: AutomationSecurityError.connectionLimit.localizedDescription,
                                                        failure: .unavailable), on: connection)
                return
            }
            activeClientID = context.clientID
            authenticated = true
            if request.observesState {
                let stream = await events(request, context)
                let eventTask = Task {
                    do {
                        for await response in stream {
                            guard pairings.context(forBearer: request.token) != nil else {
                                connection.cancel()
                                break
                            }
                            try await Self.send(response, on: connection)
                            if Task.isCancelled { break }
                        }
                    } catch {
                        connection.cancel()
                    }
                }
                let revocationTask = Task { () -> Bool in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            return false
                        }
                        guard pairings.context(forBearer: request.token) != nil else {
                            connection.cancel()
                            return true
                        }
                    }
                    return false
                }
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask { await Self.waitForDisconnect(connection) }
                    group.addTask {
                        await eventTask.value
                        return false
                    }
                    group.addTask { await revocationTask.value }
                    _ = await group.next()
                    eventTask.cancel()
                    revocationTask.cancel()
                    group.cancelAll()
                }
                eventTask.cancel()
                revocationTask.cancel()
            } else {
                try await Self.send(await handler(request, context), on: connection)
            }
        } catch {
            // Failed framing/authentication deadlines close immediately. Once
            // a request is decoded, return a correlated, typed failure.
            if let requestID {
                try? await Self.send(
                    AutomationResponse(
                        requestID: requestID, ok: false, error: error.localizedDescription,
                        failure: AutomationFailure(error: error)
                    ),
                    on: connection
                )
            }
        }
    }

    private static func waitForDisconnect(_ connection: NWConnection) async -> Bool {
        while !Task.isCancelled {
            do {
                let (data, complete) = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<(Data, Bool), Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                        data, _, complete, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data {
                            continuation.resume(returning: (data, complete))
                        } else {
                            continuation.resume(returning: (Data(), complete))
                        }
                    }
                }
                if complete && data.isEmpty { return true }
            } catch {
                return true
            }
        }
        return false
    }

    private static func secIdentity(for record: AutomationTLSIdentityRecord) throws -> SecIdentity? {
        guard let certificate = SecCertificateCreateWithData(nil, record.certificateDER as CFData) else {
            return nil
        }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(record.privateKeyData as CFData, attrs as CFDictionary, &error) else {
            return nil
        }
#if os(macOS)
        return SecIdentityCreate(nil, certificate, key)
#else
        return nil
#endif
    }

    fileprivate static func receiveFrame(
        _ connection: NWConnection,
        using frameBuffer: AutomationFrameBuffer,
        timeout duration: Duration = .seconds(30)
    ) async throws -> Data {
        if let frame = try frameBuffer.nextFrame() { return frame }
        let timeout = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { connection.cancel() }
        }
        defer { timeout.cancel() }
        while true {
            let (data, complete) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: (data, complete))
                    } else if complete {
                        continuation.resume(throwing: AutomationSecurityError.socketUnavailable)
                    } else {
                        continuation.resume(throwing: AutomationSecurityError.socketUnavailable)
                    }
                }
            }
            frameBuffer.append(data)
            if let frame = try frameBuffer.nextFrame() { return frame }
            if complete { throw AutomationSecurityError.socketUnavailable }
        }
    }

    private static func send(_ response: AutomationResponse, on connection: NWConnection) async throws {
        let data: Data
        do {
            data = try AutomationLineCodec.encode(response)
        } catch AutomationSecurityError.responseTooLarge {
            let fallback = AutomationResponse(requestID: response.requestID, ok: false,
                                              error: AutomationSecurityError.responseTooLarge.localizedDescription,
                                              failure: .domain)
            data = try AutomationLineCodec.encode(fallback)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

public final class AutomationTLSSocketClient: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let bearerToken: String
    public let clientID: UUID?
    public let pinnedFingerprint: String

    public init(host: String, port: UInt16, bearerToken: String, clientID: UUID? = nil,
                pinnedFingerprint: String) throws {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, port != 0,
              pinnedFingerprint.count == 64 else { throw AutomationSecurityError.invalidConfiguration }
        self.host = host; self.port = port; self.bearerToken = bearerToken
        self.clientID = clientID; self.pinnedFingerprint = pinnedFingerprint.lowercased()
    }

    /// Performs the pre-bearer TLS pairing claim. Certificate verification is
    /// completed by `makeConnection` before this one-time code is sent.
    public func claim(code: String, clientName: String? = nil) async throws -> AutomationPairedEndpoint {
        let claimRequest = AutomationRequest(
            token: "",
            origin: .pairedRemote,
            control: .pairingClaim,
            pairingCode: code,
            pairingClientName: clientName
        )
        let response = try await request(claimRequest)
        guard response.ok, let data = response.result else {
            throw AutomationSecurityError.notPaired
        }
        return try AutomationLineCodec.decode(AutomationPairingClaimResult.self, from: data).endpoint
    }

    public func request(_ request: AutomationRequest) async throws -> AutomationResponse {
        let connection = try makeConnection()
        let frameBuffer = AutomationFrameBuffer()
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await start(connection)
            let request = AutomationRequest(
                requestID: request.requestID, token: bearerToken, origin: request.origin,
                clientID: clientID?.uuidString, command: request.command, control: request.control,
                wantsState: request.wantsState, wantsGUIState: request.wantsGUIState,
                observesState: request.observesState,
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
            try await Self.send(request, on: connection)
            return try await Self.receiveResponse(connection, using: frameBuffer)
        } onCancel: {
            connection.cancel()
        }
    }

    public func observe(_ request: AutomationRequest,
                        onResponse: @escaping @Sendable (AutomationResponse) async -> Void) async throws {
        let connection = try makeConnection()
        let frameBuffer = AutomationFrameBuffer()
        try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await start(connection)
            let request = AutomationRequest(
                requestID: request.requestID, token: bearerToken, origin: request.origin,
                clientID: clientID?.uuidString, command: request.command, control: request.control,
                wantsState: request.wantsState, wantsGUIState: request.wantsGUIState,
                observesState: true, afterRevision: request.afterRevision, secret: request.secret,
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
            try await Self.send(request, on: connection)
            while true {
                await onResponse(try await Self.receiveResponse(connection, using: frameBuffer))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func makeConnection() throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = SecTrustGetCertificateAtIndex(secTrust, 0) else { complete(false); return }
            let data = SecCertificateCopyData(certificate) as Data
            complete(AutomationTLSIdentityStore.fingerprint(certificateDER: data).lowercased() == self.pinnedFingerprint)
        }, Self.queue)
        let parameters = NWParameters(tls: tls)
        guard let port = NWEndpoint.Port(rawValue: port) else { throw AutomationSecurityError.invalidConfiguration }
        return NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    }

    private func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completionState = AutomationContinuationState()
            let timeout = Task {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, completionState.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: AutomationSecurityError.socketUnavailable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard completionState.claim() else { return }
                    timeout.cancel()
                    continuation.resume()
                case .failed(let error):
                    guard completionState.claim() else { return }
                    timeout.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard completionState.claim() else { return }
                    timeout.cancel()
                    continuation.resume(throwing: AutomationSecurityError.socketUnavailable)
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    private static let queue = DispatchQueue(label: "org.kayg.mailternal.automation.tls-client", qos: .userInitiated)

    private static func send(_ request: AutomationRequest, on connection: NWConnection) async throws {
        let data = try AutomationLineCodec.encode(request)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receiveResponse(
        _ connection: NWConnection,
        using frameBuffer: AutomationFrameBuffer
    ) async throws -> AutomationResponse {
        let frame = try await AutomationTLSListener.receiveFrame(connection, using: frameBuffer)
        return try AutomationLineCodec.decode(AutomationResponse.self, from: frame)
    }
}
#else
public final class AutomationTLSListener: @unchecked Sendable {
    public typealias Handler = AutomationSocketServer.Handler
    public typealias Events = AutomationSocketServer.Events
    public init(endpoint: AutomationEndpoint, configuration: AutomationRemoteConfiguration,
                pairings: AutomationPairingStore) { }
    public func start(handler: @escaping Handler, events: @escaping Events) async throws { throw AutomationSecurityError.tlsUnavailable }
    public func stop() { }
}

#if !os(Linux)
public final class AutomationTLSSocketClient: @unchecked Sendable {
    public init(host: String, port: UInt16, bearerToken: String, clientID: UUID? = nil,
                pinnedFingerprint: String) throws { throw AutomationSecurityError.tlsUnavailable }
    public func claim(code: String, clientName: String? = nil) async throws -> AutomationPairedEndpoint {
        throw AutomationSecurityError.tlsUnavailable
    }
    public func request(_ request: AutomationRequest) async throws -> AutomationResponse { throw AutomationSecurityError.tlsUnavailable }
    public func observe(_ request: AutomationRequest,
                        onResponse: @escaping @Sendable (AutomationResponse) async -> Void) async throws { throw AutomationSecurityError.tlsUnavailable }
}
#endif
#endif

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
