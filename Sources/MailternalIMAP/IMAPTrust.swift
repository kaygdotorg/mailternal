import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide extra TLS trust roots. Production leaves this empty.
///
/// QA/testing only. Extra PEMs are installed as explicit trust anchors.
/// Hostname verification stays on (`certificateVerification = .fullVerification`).
/// On Apple platforms, the explicit-root branch uses NIOSSL's BoringSSL
/// verifier because the QA Dovecot certificate is a self-signed leaf without
/// CA constraints; the native SecTrust path rejects that fixture even when
/// supplied as an additional anchor. Production leaves this list empty and
/// therefore retains the platform/system trust backend.
/// Thread-safe via a lock. Used by the QA Dovecot (`MAILTERNAL_QA=1`,
/// self-signed `~/mailternal-qa/certs/dovecot.crt`).
///
/// On macOS, the explicit-root branch combines exported system anchors with
/// the extra PEMs. iOS cannot export system roots in this module, so its
/// QA-only explicit-root branch uses the installed PEMs as the complete
/// NIOSSL trust set. This path is entered only after an explicit test root is
/// installed and never disables certificate or hostname verification.
///
/// ## IP-literal endpoints
/// `NIOSSLClientHandler(serverHostname:)` uses one string for SNI **and**
/// hostname verification, and rejects IP literals (`cannotUseIPAddressInSNI`).
/// The explicit QA fixture uses loopback (`127.0.0.1`/`::1`) and includes a
/// `localhost` DNS SAN, so that narrowly scoped endpoint uses `localhost` for
/// SNI and hostname verification while TCP still connects to loopback.
/// Other IP literals fail closed, even when an extra trust root is installed.
///
/// This keeps certificate-chain and hostname verification enabled for
/// production DNS endpoints and the explicit QA loopback endpoint. There is
/// no insecure `serverHostname: nil` fallback for an accepted connection.
enum IMAPTrust {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var pemBlobs: [Data] = []
    }

    private static let storage = Storage()

    static func setAdditionalPEM(_ pem: [Data]) {
        storage.lock.lock()
        storage.pemBlobs = pem
        storage.lock.unlock()
        // Contexts contain the complete trust store and cannot be reused after
        // QA roots change. Invalidation is separate from this lock so a TLS
        // handler can never observe a partially updated root list.
        IMAPTLS.invalidateContextCache()
    }

    /// A value snapshot used as the TLS-context cache key. The PEM bytes are
    /// deliberately part of the key, rather than only an installation flag:
    /// replacing a certificate invalidates the old trust configuration.
    static func additionalPEM() -> [Data] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.pemBlobs
    }

    /// True after ``IMAPSession/installAdditionalTrustRoots(pem:)`` with a
    /// non-empty PEM list. Production never sets this.
    static var additionalTrustRootsInstalled: Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return !storage.pemBlobs.isEmpty
    }

    /// DNS names are used directly for SNI and hostname verification.
    static func sniHostname(for host: String) -> String? {
        isIPAddress(host) ? nil : host
    }

    /// An explicitly installed QA fixture is permitted only for the
    /// loopback endpoint used by the bundled Dovecot service. The fixture
    /// contains a `localhost` DNS SAN, so use that name for SNI and hostname
    /// verification while TCP still connects to loopback.
    static func sniHostname(for host: String, additionalPEM: [Data]) -> String? {
        guard isQALoopback(host), !additionalPEM.isEmpty else {
            return sniHostname(for: host)
        }
        return "localhost"
    }

    /// Production IP literals and arbitrary IP-based accounts are refused so
    /// NIOSSL cannot silently skip hostname verification. QA extras opt into
    /// only the bundled loopback fixture.
    static func requireHostnameVerification(for host: String, additionalPEM: [Data]) throws {
        guard isIPAddress(host) else { return }
        guard isQALoopback(host), !additionalPEM.isEmpty else {
            throw IMAPError.tls("Connect using a hostname, not an IP address.")
        }
    }

    private static func isQALoopback(_ host: String) -> Bool {
        var candidate = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("["), candidate.hasSuffix("]"), candidate.count > 2 {
            candidate = String(candidate.dropFirst().dropLast())
        }
        return candidate == "127.0.0.1" || candidate == "::1"
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
    /// QA/testing only — installs explicit PEM trust anchors while retaining
    /// certificate and hostname verification. Production callers must not
    /// invoke this.
    public static func installAdditionalTrustRoots(pem: [Data]) {
        IMAPTrust.setAdditionalPEM(pem)
    }

    /// Clears ``installAdditionalTrustRoots(pem:)``. Test isolation.
    public static func resetAdditionalTrustRoots() {
        IMAPTrust.setAdditionalPEM([])
    }
}
