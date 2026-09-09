import Foundation
import MailternalInterfaces

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Shared size and shape checks for every pairing bundle ingress.
///
/// Keeping these limits beside the model ensures the LAN and offline paths
/// reject the same payloads before callers can persist anything.
enum PairingBundleValidation {
    static let maximumEncodedBytes = 256 * 1_024
    static let maximumAccounts = 128
    static let maximumSettings = 2_048

    static func isAcceptable(_ bundle: PairingBundle) -> Bool {
        guard bundle.accounts.count <= maximumAccounts,
              bundle.settings.count <= maximumSettings else { return false }
        var ids = Set<AccountID>()
        for account in bundle.accounts {
            guard ids.insert(account.id).inserted,
                  (account.smtpCredential?.utf8.count ?? 0) <= maximumEncodedBytes else {
                return false
            }
        }
        return true
    }
}

/// Errors raised while reading or writing an offline pairing file.
///
/// These cases deliberately contain no bundle contents or credentials, so the
/// localized descriptions are safe to show in the pairing surface.
public enum PairingFileTransferError: Error, LocalizedError, Equatable, Sendable {
    case cryptographyUnavailable
    case invalidPassphrase
    case fileTooLarge
    case invalidFile
    case unsupportedVersion
    case authenticationFailed
    case malformedBundle
    case unsupportedBundleSchema

    public var errorDescription: String? {
        switch self {
        case .cryptographyUnavailable:
            return "Encrypted file transfer is unavailable on this platform."
        case .invalidPassphrase:
            return "Use the generated 43-character passphrase."
        case .fileTooLarge:
            return "The pairing file is too large."
        case .invalidFile:
            return "The selected file is not a Mailternal pairing file."
        case .unsupportedVersion:
            return "The pairing file uses an unsupported version."
        case .authenticationFailed:
            return "The passphrase is incorrect or the pairing file was changed."
        case .malformedBundle:
            return "The decrypted account bundle is malformed."
        case .unsupportedBundleSchema:
            return "The decrypted account bundle uses an unsupported schema."
        }
    }
}

/// Password-protected, authenticated file transport for pairing bundles.
///
/// The envelope is a bounded binary format. Its header is authenticated as
/// associated data, while the JSON bundle remains encrypted by AES-GCM. The
/// passphrase accepted by this API is intentionally restricted to the
/// 256-bit value emitted by `makePassphrase`; human-chosen low-entropy passwords
/// are not supported.
public enum PairingFileTransfer {
    public static let fileExtension = "mailternal-pairing"
    public static let generatedPassphraseLength = 43
    public static let maximumBundleBytes = PairingBundleValidation.maximumEncodedBytes
    public static let maximumFileBytes = 8 + 1 + 16 + 12 + maximumBundleBytes + 16

    private static let generatedPassphraseBytes = 32
    private static let magic = Data([0x4d, 0x54, 0x4e, 0x50, 0x41, 0x49, 0x52, 0x31]) // MTNPAIR1
    private static let version: UInt8 = 1
    private static let saltBytes = 16
    private static let nonceBytes = 12
    private static let authenticationTagBytes = 16
    private static let keyInfo = Data("mailternal.pairing.file.v1".utf8)

    /// Creates a high-entropy ASCII passphrase suitable for manual transfer.
    public static func makePassphrase() throws -> String {
        #if canImport(CryptoKit)
        let key = SymmetricKey(size: .bits256)
        let bytes = Data(key.withUnsafeBytes { Data($0) })
        return bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #else
        throw PairingFileTransferError.cryptographyUnavailable
        #endif
    }

    /// Encrypts a validated pairing bundle into a self-contained file payload.
    public static func encrypt(_ bundle: PairingBundle, passphrase: String) throws -> Data {
        #if canImport(CryptoKit)
        try validatePassphrase(passphrase)
        guard bundle.schema == PairingBundle.schemaIdentifier,
              PairingBundleValidation.isAcceptable(bundle) else {
            throw PairingFileTransferError.malformedBundle
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded: Data
        do {
            encoded = try encoder.encode(bundle)
        } catch {
            throw PairingFileTransferError.malformedBundle
        }
        guard encoded.count <= maximumBundleBytes else {
            throw PairingFileTransferError.fileTooLarge
        }

        let salt = randomBytes(count: saltBytes)
        let nonceData = randomBytes(count: nonceBytes)
        let header = makeHeader(salt: salt, nonce: nonceData)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let nonce: CryptoKit.AES.GCM.Nonce
        do {
            nonce = try CryptoKit.AES.GCM.Nonce(data: nonceData)
        } catch {
            throw PairingFileTransferError.cryptographyUnavailable
        }
        let sealed: CryptoKit.AES.GCM.SealedBox
        do {
            sealed = try CryptoKit.AES.GCM.seal(
                encoded,
                using: key,
                nonce: nonce,
                authenticating: header
            )
        } catch {
            throw PairingFileTransferError.cryptographyUnavailable
        }
        var result = Data(capacity: header.count + encoded.count + authenticationTagBytes)
        result.append(header)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        guard result.count <= maximumFileBytes else {
            throw PairingFileTransferError.fileTooLarge
        }
        return result
        #else
        throw PairingFileTransferError.cryptographyUnavailable
        #endif
    }

    /// Decrypts, authenticates, bounds-checks, and validates an offline file.
    /// No caller-visible state is changed by this pure operation on failure.
    public static func decrypt(_ data: Data, passphrase: String) throws -> PairingBundle {
        #if canImport(CryptoKit)
        try validatePassphrase(passphrase)
        guard data.count <= maximumFileBytes else {
            throw PairingFileTransferError.fileTooLarge
        }
        let headerLength = magic.count + 1 + saltBytes + nonceBytes
        guard data.count >= headerLength + authenticationTagBytes else {
            throw PairingFileTransferError.invalidFile
        }
        let header = data.prefix(headerLength)
        guard header.prefix(magic.count) == magic else {
            throw PairingFileTransferError.invalidFile
        }
        guard header[magic.count] == version else {
            throw PairingFileTransferError.unsupportedVersion
        }
        let saltStart = magic.count + 1
        let salt = Data(header[saltStart..<(saltStart + saltBytes)])
        let nonceStart = saltStart + saltBytes
        let nonceData = Data(header[nonceStart..<(nonceStart + nonceBytes)])
        let encrypted = data.dropFirst(headerLength)
        guard encrypted.count >= authenticationTagBytes,
              encrypted.count - authenticationTagBytes <= maximumBundleBytes else {
            throw PairingFileTransferError.fileTooLarge
        }
        let ciphertext = encrypted.dropLast(authenticationTagBytes)
        let tag = encrypted.suffix(authenticationTagBytes)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let nonce: CryptoKit.AES.GCM.Nonce
        do {
            nonce = try CryptoKit.AES.GCM.Nonce(data: nonceData)
        } catch {
            throw PairingFileTransferError.invalidFile
        }
        let sealed: CryptoKit.AES.GCM.SealedBox
        do {
            sealed = try CryptoKit.AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
        } catch {
            throw PairingFileTransferError.invalidFile
        }
        let plaintext: Data
        do {
            plaintext = try CryptoKit.AES.GCM.open(
                sealed,
                using: key,
                authenticating: header
            )
        } catch {
            throw PairingFileTransferError.authenticationFailed
        }
        guard plaintext.count <= maximumBundleBytes else {
            throw PairingFileTransferError.fileTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let bundle: PairingBundle
        do {
            bundle = try decoder.decode(PairingBundle.self, from: plaintext)
        } catch {
            throw PairingFileTransferError.malformedBundle
        }
        guard bundle.schema == PairingBundle.schemaIdentifier else {
            throw PairingFileTransferError.unsupportedBundleSchema
        }
        guard PairingBundleValidation.isAcceptable(bundle) else {
            throw PairingFileTransferError.malformedBundle
        }
        return bundle
        #else
        throw PairingFileTransferError.cryptographyUnavailable
        #endif
    }

    #if canImport(CryptoKit)
    private static func validatePassphrase(_ passphrase: String) throws {
        let bytes = passphrase.utf8.count
        guard bytes == generatedPassphraseLength,
              passphrase.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57)
                      || ($0.value >= 65 && $0.value <= 90)
                      || ($0.value >= 97 && $0.value <= 122)
                      || $0.value == 45
                      || $0.value == 95
              }) else {
            throw PairingFileTransferError.invalidPassphrase
        }
        let padding = String(repeating: "=", count: (4 - bytes % 4) % 4)
        guard let decoded = Data(
            base64Encoded: passphrase.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + padding
        ), decoded.count == generatedPassphraseBytes else {
            throw PairingFileTransferError.invalidPassphrase
        }
    }

    private static func randomBytes(count: Int) -> Data {
        let key = CryptoKit.SymmetricKey(size: .bits256)
        return Data(key.withUnsafeBytes { Data($0.prefix(count)) })
    }

    private static func deriveKey(passphrase: String, salt: Data) -> CryptoKit.SymmetricKey {
        CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: CryptoKit.SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt,
            info: keyInfo,
            outputByteCount: 32
        )
    }

    private static func makeHeader(salt: Data, nonce: Data) -> Data {
        var header = Data(capacity: magic.count + 1 + salt.count + nonce.count)
        header.append(magic)
        header.append(version)
        header.append(salt)
        header.append(nonce)
        return header
    }
    #endif
}
