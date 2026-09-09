import Foundation
import MailternalInterfaces

/// A closed set of user intents exposed by the native pairing surface.
///
/// These values are commands, not lifecycle notifications. Payloads are carried
/// only long enough to execute the local action; command journaling records the
/// action name and targets, never QR strings, passphrases, files, or bundles.
public enum PairingUIAction: Codable, Equatable, Hashable, Sendable {
    case showCode
    case join(qrString: String)
    case sendSelectedAccounts(accountIDs: [AccountID], includeSettings: Bool)
    case cancel
    /// Cancels active work and closes the sheet; `cancel` keeps it open.
    case dismiss
    case restart
    case setSelectedAccounts([AccountID])
    case setIncludeSettings(Bool)
    case setReplaceExisting(Bool)
    case setImportSettings(Bool)
    case confirmImport(accountIDs: [AccountID], replaceExisting: Bool, importSettings: Bool)
    case exportOfflineBundle(accountIDs: [AccountID], includeSettings: Bool)
    case chooseOfflineFile
    case importOfflineFile(Data)
    case setOfflinePassphrase(String)
    case decryptOfflineBundle
    case scanCode
    case scanDifferentCode
    case scanImage
    case scanDifferentImage

    /// Stable action identifier used by automation state and metadata logging.
    public var name: String {
        switch self {
        case .showCode: "pairing.show-code"
        case .join: "pairing.join"
        case .sendSelectedAccounts: "pairing.send-accounts"
        case .cancel: "pairing.cancel"
        case .dismiss: "pairing.dismiss"
        case .restart: "pairing.restart"
        case .setSelectedAccounts: "pairing.select-accounts"
        case .setIncludeSettings: "pairing.include-settings"
        case .setReplaceExisting: "pairing.replace-existing"
        case .setImportSettings: "pairing.import-settings"
        case .confirmImport: "pairing.confirm-import"
        case .exportOfflineBundle: "pairing.export-offline"
        case .chooseOfflineFile: "pairing.choose-offline-file"
        case .importOfflineFile: "pairing.import-offline-file"
        case .setOfflinePassphrase: "pairing.offline-passphrase"
        case .decryptOfflineBundle: "pairing.decrypt-offline"
        case .scanCode: "pairing.scan-code"
        case .scanDifferentCode: "pairing.scan-different-code"
        case .scanImage: "pairing.scan-image"
        case .scanDifferentImage: "pairing.scan-different-image"
        }
    }

    /// Account/file transfer commands are restricted to the local GUI path.
    /// This is informational; authorization remains a Command concern.
    public var isCredentialTransfer: Bool {
        switch self {
        case .sendSelectedAccounts, .confirmImport, .exportOfflineBundle,
             .importOfflineFile, .setOfflinePassphrase, .decryptOfflineBundle:
            return true
        default:
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case payload
    }

    private enum PayloadKeys: String, CodingKey {
        case qrString
        case accountIDs
        case includeSettings
        case replaceExisting
        case importSettings
        case data
        case passphrase
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .action)
        var payload = container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        switch self {
        case .showCode, .cancel, .dismiss, .restart, .decryptOfflineBundle, .scanCode,
             .scanDifferentCode, .scanImage, .scanDifferentImage, .chooseOfflineFile:
            break
        case .join(let qrString):
            try payload.encode(qrString, forKey: .qrString)
        case .sendSelectedAccounts(let accountIDs, let includeSettings):
            try payload.encode(accountIDs, forKey: .accountIDs)
            try payload.encode(includeSettings, forKey: .includeSettings)
        case .setSelectedAccounts(let accountIDs):
            try payload.encode(accountIDs, forKey: .accountIDs)
        case .setIncludeSettings(let value):
            try payload.encode(value, forKey: .includeSettings)
        case .setReplaceExisting(let value):
            try payload.encode(value, forKey: .replaceExisting)
        case .setImportSettings(let value):
            try payload.encode(value, forKey: .importSettings)
        case .confirmImport(let accountIDs, let replaceExisting, let importSettings):
            try payload.encode(accountIDs, forKey: .accountIDs)
            try payload.encode(replaceExisting, forKey: .replaceExisting)
            try payload.encode(importSettings, forKey: .importSettings)
        case .exportOfflineBundle(let accountIDs, let includeSettings):
            try payload.encode(accountIDs, forKey: .accountIDs)
            try payload.encode(includeSettings, forKey: .includeSettings)
        case .importOfflineFile(let data):
            try payload.encode(data, forKey: .data)
        case .setOfflinePassphrase(let passphrase):
            try payload.encode(passphrase, forKey: .passphrase)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        switch action {
        case "pairing.show-code":
            self = .showCode
        case "pairing.join":
            self = .join(qrString: try payload.decode(String.self, forKey: .qrString))
        case "pairing.send-accounts":
            self = .sendSelectedAccounts(
                accountIDs: try payload.decode([AccountID].self, forKey: .accountIDs),
                includeSettings: try payload.decode(Bool.self, forKey: .includeSettings)
            )
        case "pairing.cancel":
            self = .cancel
        case "pairing.dismiss":
            self = .dismiss
        case "pairing.restart":
            self = .restart
        case "pairing.select-accounts":
            self = .setSelectedAccounts(try payload.decode([AccountID].self, forKey: .accountIDs))
        case "pairing.include-settings":
            self = .setIncludeSettings(try payload.decode(Bool.self, forKey: .includeSettings))
        case "pairing.replace-existing":
            self = .setReplaceExisting(try payload.decode(Bool.self, forKey: .replaceExisting))
        case "pairing.import-settings":
            self = .setImportSettings(try payload.decode(Bool.self, forKey: .importSettings))
        case "pairing.confirm-import":
            self = .confirmImport(
                accountIDs: try payload.decode([AccountID].self, forKey: .accountIDs),
                replaceExisting: try payload.decode(Bool.self, forKey: .replaceExisting),
                importSettings: try payload.decode(Bool.self, forKey: .importSettings)
            )
        case "pairing.export-offline":
            self = .exportOfflineBundle(
                accountIDs: try payload.decode([AccountID].self, forKey: .accountIDs),
                includeSettings: try payload.decode(Bool.self, forKey: .includeSettings)
            )
        case "pairing.choose-offline-file":
            self = .chooseOfflineFile
        case "pairing.import-offline-file":
            self = .importOfflineFile(try payload.decode(Data.self, forKey: .data))
        case "pairing.offline-passphrase":
            self = .setOfflinePassphrase(try payload.decode(String.self, forKey: .passphrase))
        case "pairing.decrypt-offline":
            self = .decryptOfflineBundle
        case "pairing.scan-code":
            self = .scanCode
        case "pairing.scan-different-code":
            self = .scanDifferentCode
        case "pairing.scan-image":
            self = .scanImage
        case "pairing.scan-different-image":
            self = .scanDifferentImage
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Unknown pairing UI action."
            )
        }
    }
}
