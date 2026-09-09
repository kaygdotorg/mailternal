import Foundation
import NIOSSL
#if os(macOS)
import Security
#endif

/// One trust policy and context cache for IMAP and SMTP. Production uses the
/// platform's system verifier with full hostname verification and TLS 1.2+.
/// Explicit QA anchors use BoringSSL on Apple platforms because SecTrust rejects
/// the project's self-signed leaf fixture. macOS includes exported system roots;
/// iOS QA uses the explicit set because system roots cannot be exported there.
/// Linux supplements its normal system roots. No branch disables verification.
package enum MailTLS {
    private static let storage = ContextStorage()

    /// Context construction may read system anchors; call before entering a NIO
    /// event loop. Concurrent misses share the same construction and trust set.
    package static func clientContext(additionalPEM: [Data]) throws -> NIOSSLContext {
        try storage.context(additionalPEM: additionalPEM)
    }

    package static func invalidateContextCache() { storage.invalidate() }
}

private enum TrustError: Error, LocalizedError {
    case invalidAdditionalRoots, unavailableSystemRoots

    var errorDescription: String? {
        switch self {
        case .invalidAdditionalRoots: "Configured additional TLS trust roots are invalid."
        case .unavailableSystemRoots: "System TLS trust roots are unavailable."
        }
    }
}

private final class ContextStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [[Data]: NIOSSLContext] = [:]
    #if os(macOS)
    private var systemAnchors: [NIOSSLCertificate]?
    #endif

    func context(additionalPEM: [Data]) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        if let cached = contexts[additionalPEM] { return cached }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .fullVerification
        configuration.minimumTLSVersion = .tlsv12
        if !additionalPEM.isEmpty {
            var extras: [NIOSSLCertificate] = []
            for pem in additionalPEM {
                let certificates: [NIOSSLCertificate]
                do { certificates = try NIOSSLCertificate.fromPEMBytes(Array(pem)) }
                catch { throw TrustError.invalidAdditionalRoots }
                guard !certificates.isEmpty else { throw TrustError.invalidAdditionalRoots }
                extras.append(contentsOf: certificates)
            }
            #if os(macOS)
            let anchors: [NIOSSLCertificate]
            if let cached = systemAnchors {
                anchors = cached
            } else {
                var exported: CFArray?
                guard SecTrustCopyAnchorCertificates(&exported) == errSecSuccess,
                      let certificates = exported as? [SecCertificate], !certificates.isEmpty else {
                    throw TrustError.unavailableSystemRoots
                }
                anchors = try certificates.map {
                    try NIOSSLCertificate(bytes: Array(SecCertificateCopyData($0) as Data), format: .der)
                }
                systemAnchors = anchors
            }
            extras.append(contentsOf: anchors)
            configuration.trustRoots = .certificates(extras)
            #elseif canImport(Darwin)
            configuration.trustRoots = .certificates(extras)
            #else
            configuration.additionalTrustRoots = [.certificates(extras)]
            #endif
        }
        let context = try NIOSSLContext(configuration: configuration)
        contexts[additionalPEM] = context
        return context
    }

    func invalidate() {
        lock.lock()
        contexts.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
