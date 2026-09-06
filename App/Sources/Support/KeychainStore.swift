import Foundation
import Security
import MailternalInterfaces

/// Generic-password Keychain for IMAP credentials.
///
/// Items are `kSecClassGenericPassword` with service `org.kayg.mailternal`
/// and `kSecAttrAccount` = `AccountID.rawValue`.
///
/// Production items are synchronizable iCloud Keychain records in the shared
/// access group configured by the app's generated Info.plist. The access group
/// must stay in lockstep with the macOS and iOS entitlements; a signed build
/// needs the corresponding Team ID provisioning entitlement. `AfterFirstUnlock`
/// is used instead of a `ThisDeviceOnly` accessibility class because
/// synchronizable records cannot be device-only.
///
/// Items written by older builds were local records without synchronizable or
/// access-group attributes. Reads check the shared record first, then import a
/// legacy local record into the shared record before removing the old one. A
/// failed migration is surfaced, while the legacy item remains intact so a
/// later retry cannot lose the credential.
///
/// `storage: .memory` is for unsandboxed tests and QA. It never calls Security,
/// so fixture credentials cannot enter the user's real synchronizable namespace.
/// The app always uses `.keychain`.
struct KeychainStore: Sendable {
    static let defaultService = "org.kayg.mailternal"

    /// Resolved value of `$(AppIdentifierPrefix)org.kayg.mailternal` from the
    /// generated Info.plist. Do not derive this from a bundle ID: the
    /// application-identifier prefix is signing-team specific.
    static let sharedAccessGroup: String = {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "MailternalKeychainAccessGroup"
        ) as? String, !value.isEmpty else {
            // Unit-test bundles and unsigned QA do not use `.keychain`; keep
            // their configuration deterministic without inventing a prefix.
            return defaultService
        }
        return value
    }()

    enum Storage: Sendable {
        case keychain
        case memory
    }

    var service: String
    var storage: Storage

    init(service: String = KeychainStore.defaultService, storage: Storage = .keychain) {
        self.service = service
        self.storage = storage
    }

    func savePassword(_ password: String, for account: AccountID) throws {
        switch storage {
        case .memory:
            MemorySecrets.shared.set(password, service: service, account: account)
        case .keychain:
            try saveToKeychain(password, account: account)
        }
    }

    func loadPassword(for account: AccountID) throws -> String {
        switch storage {
        case .memory:
            guard let password = MemorySecrets.shared.get(service: service, account: account) else {
                throw KeychainStoreError.itemNotFound
            }
            return password
        case .keychain:
            return try loadFromKeychain(account: account)
        }
    }

    /// Idempotent: missing items are not an error.
    func deletePassword(for account: AccountID) throws {
        switch storage {
        case .memory:
            MemorySecrets.shared.remove(service: service, account: account)
        case .keychain:
            try deleteFromKeychain(account: account)
        }
    }

    private func saveToKeychain(_ password: String, account: AccountID) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainStoreError.unexpectedItemData
        }

        let query = sharedQuery(account: account)
        let attributes = [kSecValueData as String: data] as CFDictionary
        let updated = SecItemUpdate(query as CFDictionary, attributes)
        if updated == errSecSuccess {
            return
        }
        if updated != errSecItemNotFound {
            throw KeychainStoreError.osStatus(updated)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess {
            return
        }
        // A synchronizable record may arrive between the update and add.
        // Re-run the update so concurrent device/account setup is harmless.
        if added == errSecDuplicateItem {
            let retried = SecItemUpdate(query as CFDictionary, attributes)
            guard retried == errSecSuccess else {
                throw KeychainStoreError.osStatus(retried)
            }
            return
        }
        throw KeychainStoreError.osStatus(added)
    }

    private func loadFromKeychain(account: AccountID) throws -> String {
        do {
            return try password(from: sharedQuery(account: account))
        } catch KeychainStoreError.itemNotFound {
            let password = try password(from: legacyQuery(account: account))
            // Save first and only then remove the local record. If either
            // operation fails the caller sees the error and the old record is
            // still available for a future migration attempt.
            try saveToKeychain(password, account: account)
            let removed = SecItemDelete(legacyQuery(account: account) as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else {
                throw KeychainStoreError.osStatus(removed)
            }
            return password
        }
    }

    private func password(from query: [String: Any]) throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw KeychainStoreError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.unexpectedItemData
        }
        return password
    }

    private func deleteFromKeychain(account: AccountID) throws {
        // Remove both generations. This handles an interrupted migration and
        // keeps deletion semantics independent of which record was read.
        var failure: OSStatus?
        for query in [sharedQuery(account: account), legacyQuery(account: account)] {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound && failure == nil {
                failure = status
            }
        }
        if let failure {
            throw KeychainStoreError.osStatus(failure)
        }
    }

    private func sharedQuery(account: AccountID) -> [String: Any] {
        var query = scopedQuery(account: account)
        query[kSecAttrAccessGroup as String] = Self.sharedAccessGroup
        query[kSecAttrSynchronizable as String] = true
        return query
    }

    private func legacyQuery(account: AccountID) -> [String: Any] {
        var query = scopedQuery(account: account)
        // Explicitly exclude the new iCloud Keychain generation. Omitting
        // this key would allow a shared item to satisfy the legacy lookup.
        query[kSecAttrSynchronizable as String] = false
        return query
    }

    private func scopedQuery(account: AccountID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        #if os(iOS)
        // iOS app keychain items use the Data Protection keychain. Unlike the
        // macOS app, there is no login-keychain fallback in an iOS sandbox.
        query[kSecUseDataProtectionKeychain as String] = true
        #else
        // Preserve the macOS behavior for unsandboxed QA/tests while selecting
        // the Data Protection keychain for the sandboxed production app.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }
}

/// Process-local password map used by `KeychainStore.Storage.memory`.
private final class MemorySecrets: @unchecked Sendable {
    static let shared = MemorySecrets()
    private let lock = NSLock()
    private var items: [String: String] = [:]

    func set(_ password: String, service: String, account: AccountID) {
        lock.lock()
        items[key(service, account)] = password
        lock.unlock()
    }

    func get(service: String, account: AccountID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service, account)]
    }

    func remove(service: String, account: AccountID) {
        lock.lock()
        items.removeValue(forKey: key(service, account))
        lock.unlock()
    }

    private func key(_ service: String, _ account: AccountID) -> String {
        "\(service)\u{1e}\(account.rawValue)"
    }
}

/// Documented Keychain failures. Messages are safe to show in setup UI.
enum KeychainStoreError: Error, LocalizedError, Sendable, Equatable {
    /// No generic-password item exists for this account.
    case itemNotFound
    /// The item existed but was not a UTF-8 password string.
    case unexpectedItemData
    /// `SecItem*` returned a non-success status.
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "The account password is not in the Keychain."
        case .unexpectedItemData:
            return "The Keychain item was not a password string."
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String?, !message.isEmpty {
                return message
            }
            return "Keychain error (\(status))."
        }
    }
}
