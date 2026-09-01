import Foundation
import NIOSSL
#if canImport(Security)
import Security
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide extra TLS trust roots. Production leaves this empty.
///
/// QA/testing only. Extra PEMs are installed as trust anchors. On Apple,
/// `IMAPTLS` selects the BoringSSL backend whenever extras are present so a
/// self-signed QA leaf is actually trusted (SecTrust rejects it). Hostname
/// verification stays on (`certificateVerification = .fullVerification`).
/// Thread-safe via a lock. Used by the QA Dovecot (`MAILTERNAL_QA=1`,
/// self-signed `~/mailternal-qa/certs/dovecot.crt`).
///
/// On Apple, `trustRoots = .default` plus `additionalTrustRoots` is evaluated
/// by SecTrust, which rejects this self-signed leaf (no CA:TRUE). When extras
/// are present the handler therefore uses the BoringSSL path with
/// **system anchors + extras**, so production roots stay in effect.
enum IMAPTrust {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var pemBlobs: [Data] = []
        var systemAnchors: [NIOSSLCertificate]?
    }

    private static let storage = Storage()

    static func setAdditionalPEM(_ pem: [Data]) {
        storage.lock.lock()
        storage.pemBlobs = pem
        storage.lock.unlock()
    }

    static func additionalCertificates() throws -> [NIOSSLCertificate]? {
        storage.lock.lock()
        let blobs = storage.pemBlobs
        storage.lock.unlock()
        if blobs.isEmpty { return nil }
        var certs: [NIOSSLCertificate] = []
        certs.reserveCapacity(blobs.count)
        for blob in blobs {
            certs.append(contentsOf: try NIOSSLCertificate.fromPEMBytes(Array(blob)))
        }
        return certs.isEmpty ? nil : certs
    }

    /// System anchors plus the extra PEMs. Used only when extras are installed.
    static func extendedTrustRoots(_ extras: [NIOSSLCertificate]) -> [NIOSSLCertificate] {
        extras + cachedSystemAnchors()
    }

    static func cachedSystemAnchors() -> [NIOSSLCertificate] {
        storage.lock.lock()
        if let cached = storage.systemAnchors {
            storage.lock.unlock()
            return cached
        }
        storage.lock.unlock()
        let loaded = systemAnchorCertificates()
        storage.lock.lock()
        storage.systemAnchors = loaded
        storage.lock.unlock()
        return loaded
    }

    /// IPv4/IPv6 literals cannot be sent as SNI. Hostname verification then
    /// relies on the IP SAN once the chain is trusted (QA cert includes 127.0.0.1).
    static func sniHostname(for host: String) -> String? {
        isIPAddress(host) ? nil : host
    }
}

extension IMAPSession {
    /// QA/testing only — extends, never replaces, system trust; hostname
    /// verification stays on. Process-wide extra PEM anchors (thread-safe).
    /// Production callers must not invoke this.
    public static func installAdditionalTrustRoots(pem: [Data]) {
        IMAPTrust.setAdditionalPEM(pem)
    }

    /// Clears ``installAdditionalTrustRoots(pem:)``. Test isolation.
    public static func resetAdditionalTrustRoots() {
        IMAPTrust.setAdditionalPEM([])
    }
}

#if canImport(Security)
private func systemAnchorCertificates() -> [NIOSSLCertificate] {
    var anchors: CFArray?
    let status = SecTrustCopyAnchorCertificates(&anchors)
    guard status == errSecSuccess, let certs = anchors as? [SecCertificate] else {
        return []
    }
    return certs.compactMap { cert in
        let data = SecCertificateCopyData(cert) as Data
        return try? NIOSSLCertificate(bytes: Array(data), format: .der)
    }
}
#else
private func systemAnchorCertificates() -> [NIOSSLCertificate] { [] }
#endif

private func isIPAddress(_ host: String) -> Bool {
    host.withCString { cstr in
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, cstr, &v4) == 1 || inet_pton(AF_INET6, cstr, &v6) == 1
    }
}
