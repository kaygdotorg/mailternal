import Foundation
import Security
import MailternalInterfaces

/// Generic-password Keychain for the single 0.0.1 IMAP secret.
///
/// Items are `kSecClassGenericPassword` with service `org.kayg.mailternal`
/// and `kSecAttrAccount` = `AccountID.rawValue`. Inside the sandbox the
/// Data Protection keychain is used (`kSecUseDataProtectionKeychain`) so the
/// app never touches the login keychain file.
///
/// `storage: .memory` is for unsandboxed tests (`swift test` over SSH cannot
/// prompt to unlock the login keychain). The app always uses `.keychain`.
struct KeychainStore: Sendable {
    static let defaultService = "org.kayg.mailternal"

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
        let base = baseQuery(account: account)
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        if updated != errSecItemNotFound {
            throw KeychainStoreError.osStatus(updated)
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw KeychainStoreError.osStatus(added)
        }
    }

    private func loadFromKeychain(account: AccountID) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainStoreError.osStatus(status)
    }

    private func baseQuery(account: AccountID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            query[kSecUseDataProtectionKeychain as String] = true
        }
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
