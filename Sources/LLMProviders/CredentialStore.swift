import Foundation
import Security
import XiaolaiDictBase

/// Why a secret could not be read, written or removed. A status and a kind — **never the secret**.
public enum CredentialStoreFailure: Error, Equatable, Sendable {
    /// The Keychain answered with this `OSStatus`: locked, no user interaction allowed, no default keychain, and so on.
    case keychain(status: Int32)
    /// The stored item is not UTF-8 text, so it is not a key this app wrote.
    case notText
    /// An empty or blank secret: "no key" is a delete, never an item holding nothing.
    case emptySecret
}

/// **Where the reader's API keys are kept, one account per provider** — a protocol so every test but one uses a store
/// in memory, and the one that asks the real Keychain does so under a service name of its own.
///
/// Reading answers nil where there is no key, which for a local server is the ordinary case, not a failure.
public protocol CredentialStore: Sendable {
    func read(account: String) throws(CredentialStoreFailure) -> String?
    func write(_ secret: String, account: String) throws(CredentialStoreFailure)
    /// Removes the account's key. Removing one that is not there is not a failure, so this is safe to repeat.
    func delete(account: String) throws(CredentialStoreFailure)
}

/// **The app's own Keychain items**: generic passwords under `com.xiaolaidict.llm`, one account per provider.
///
/// - **Written and read by the app only** (plan §2): an item the app creates trusts the app's signing identity, and
///   a different one — either XPC service — would be prompted for it. That is one reason the providers run in the
///   app's process.
/// - **Never synchronisable**: a reader's key does not travel to their other devices through iCloud Keychain because
///   this app filed it.
/// - **The file-based login keychain, not the data-protection one**: that needs a keychain access group, which a
///   Developer ID app without a provisioning profile cannot claim, so it is not assumed.
public struct KeychainCredentialStore: CredentialStore {
    /// Derived from the app's identifier, so renaming it cannot leave the keys behind under the old one.
    public static let service = "\(XiaolaiDictIdentity.app).llm"

    public let service: String

    /// `service` is for the one test that asks the real Keychain, under a name no reader's key is filed under.
    public init(service: String = KeychainCredentialStore.service) {
        self.service = service
    }

    public func read(account: String) throws(CredentialStoreFailure) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychain(status: status) }
        guard let data = found as? Data, let secret = String(data: data, encoding: .utf8) else { throw .notText }
        return secret
    }

    public func write(_ secret: String, account: String) throws(CredentialStoreFailure) {
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptySecret }
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(item(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw .keychain(status: updated) }
        var added = item(account)
        added[kSecValueData as String] = data
        let status = SecItemAdd(added as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status: status) }
    }

    public func delete(account: String) throws(CredentialStoreFailure) {
        let status = SecItemDelete(item(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status: status) }
    }

    /// The attributes that name one account's item, and say it never synchronises.
    private func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
