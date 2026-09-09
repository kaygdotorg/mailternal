import Foundation
import MailternalInterfaces
import MailternalWorkspace

/// An account configuration and its Keychain credentials for a one-time pairing
/// handoff. Secrets exist only in the encrypted bundle and are never persisted
/// in command metadata or account configuration.
public struct PairingAccount: Codable, Sendable, Identifiable {
    public let config: AccountConfig
    public let credential: String
    public let smtpCredential: String?

    public var id: AccountID { config.id }

    public init(
        config: AccountConfig,
        credential: String,
        smtpCredential: String? = nil
    ) {
        self.config = config
        self.credential = credential
        self.smtpCredential = smtpCredential
    }
}

/// The complete user-confirmed payload transferred over an authenticated pairing
/// channel. The wire schema is versioned so a future client can reject it rather
/// than interpreting an incompatible payload.
public struct PairingBundle: Codable, Sendable {
    public static let schemaIdentifier = "mailternal.pairing.v1"

    public let schema: String
    public let accounts: [PairingAccount]
    public let settings: [String: WorkspaceSyncValue]

    public init(
        accounts: [PairingAccount],
        settings: [String: WorkspaceSyncValue] = [:]
    ) {
        self.schema = Self.schemaIdentifier
        self.accounts = accounts
        self.settings = settings
    }
}

/// The opaque QR payload. It contains only the one-time channel key and LAN
/// rendezvous metadata; account configuration and credentials are sent later as
/// encrypted frames.
public struct PairingInvitation: Codable, Sendable {
    public let expiresAt: Date
    public let qrString: String

    public init(expiresAt: Date, qrString: String) {
        self.expiresAt = expiresAt
        self.qrString = qrString
    }
}

/// Errors surfaced by the pairing transport. None of the cases include account
/// contents or credentials, so they are safe to present in a UI.
public enum PairingError: Error, LocalizedError, Equatable, Sendable {
    case invalidInvitation
    case invitationExpired
    case invitationTooLong
    case cancelled
    case invalidState
    case transport(String)
    case authenticationFailed
    case protocolViolation(String)
    case replayDetected
    case frameTooLarge
    case malformedBundle
    case unsupportedBundleSchema
    case simultaneousTransfer
    case peerDisconnected
    case importAcknowledgmentMissing

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation:
            return "The pairing code is invalid."
        case .invitationExpired:
            return "The pairing code has expired."
        case .invitationTooLong:
            return "The pairing code is too large."
        case .cancelled:
            return "Pairing was cancelled."
        case .invalidState:
            return "Pairing is not ready for that action."
        case .transport(let message):
            return message
        case .authenticationFailed:
            return "The other device could not be authenticated."
        case .protocolViolation(let message):
            return message
        case .replayDetected:
            return "A replayed or out-of-order pairing frame was rejected."
        case .frameTooLarge:
            return "The pairing frame exceeds the allowed size."
        case .malformedBundle:
            return "The received account bundle is malformed."
        case .unsupportedBundleSchema:
            return "The received account bundle uses an unsupported schema."
        case .simultaneousTransfer:
            return "Both devices tried to transfer at once. Start a fresh pairing and choose one transfer."
        case .peerDisconnected:
            return "The paired device disconnected before the transfer completed."
        case .importAcknowledgmentMissing:
            return "The receiving device did not acknowledge the imported bundle."
        }
    }
}
