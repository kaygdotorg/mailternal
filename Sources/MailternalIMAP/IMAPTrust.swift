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
///
/// ## IP-literal endpoints
/// `NIOSSLClientHandler(serverHostname:)` uses one string for SNI **and**
/// hostname verification, and rejects IP literals (`cannotUseIPAddressInSNI`).
/// Passing `serverHostname: nil` disables hostname verification entirely:
/// the chain is still checked, but any trusted certificate can MITM the IP
/// (violates product.md: hostname + system-trust, no insecure fallback).
///
/// Option (a) — `NIOSSLCustomVerificationCallback` that re-implements chain
/// evaluation **and** IP-SAN matching — is not a clean NIOSSL fit: the
/// callback *replaces* NIOSSL's verifier rather than adding a SAN check, and
/// Apple SecTrust rejects the QA self-signed Dovecot leaf (the reason extras
/// already force BoringSSL). So we **fail closed** (option b): IP-literal
/// endpoints throw `IMAPError.tls` ("use a hostname") unless extra QA trust
/// roots are installed via ``IMAPSession/installAdditionalTrustRoots(pem:)``.
/// Production must use a DNS hostname so `.fullVerification` applies. The QA
/// `127.0.0.1` + extras path is unchanged.
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

    /// True after ``IMAPSession/installAdditionalTrustRoots(pem:)`` with a
    /// non-empty PEM list. Production never sets this.
    static var additionalTrustRootsInstalled: Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return !storage.pemBlobs.isEmpty
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

    /// Production IP literals are refused so NIOSSL cannot skip hostname
    /// verification. QA extras (`installAdditionalTrustRoots`) opt in.
    static func requireHostnameVerification(for host: String) throws {
        guard isIPAddress(host) else { return }
        guard additionalTrustRootsInstalled else {
            throw IMAPError.tls("Connect using a hostname, not an IP address.")
        }
    }

    static func isIPAddress(_ host: String) -> Bool {
        var candidate = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count > 2 {
            candidate = String(candidate.dropFirst().dropLast())
        }
        return candidate.withCString { cstr in
            var v4 = in_addr()
            var v6 = in6_addr()
            return inet_pton(AF_INET, cstr, &v4) == 1 || inet_pton(AF_INET6, cstr, &v6) == 1
        }
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
