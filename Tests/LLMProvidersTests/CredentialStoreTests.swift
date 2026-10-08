import Foundation
import LLMProviders
import Security
import Testing

/// **The API key is in the Keychain, the app's own item, and nowhere else** (ADR-0053, plan §4).
///
/// Exactly one test here touches the real Keychain, under a service name of its own that it removes; the rest of
/// this target uses `InMemoryCredentials`. The one that does is skipped, saying why, where the login keychain cannot
/// be written — an SSH session on a Mac nobody has logged in to, say — rather than failing for a reason that is the
/// machine's and not the code's.
struct CredentialStoreTests {
    /// The service every key is filed under, derived from the app's identifier so a rename cannot leave it behind.
    @Test func theServiceIsTheApps() {
        #expect(KeychainCredentialStore.service == "com.xiaolaidict.llm")
        #expect(KeychainCredentialStore().service == KeychainCredentialStore.service)
    }

    /// **An empty or blank key is refused before the Keychain is asked** — "no key" is a delete, never an item
    /// holding nothing, which would read back as a key that is not one. Under a service no item can be filed in,
    /// so this cannot reach a real item whatever it does.
    @Test(arguments: ["", " ", "\n\t"])
    func aBlankKeyIsRefusedBeforeTheKeychainIsAsked(secret: String) {
        let store = KeychainCredentialStore(service: "com.xiaolaidict.llm.test.never-written")
        #expect(throws: CredentialStoreFailure.emptySecret) { try store.write(secret, account: "openAICompatible") }
    }

    /// **The real Keychain, once**: write, read back, overwrite, delete, read nothing, delete again — and the item
    /// is not synchronisable, so iCloud Keychain never carries a reader's key to another device.
    @Test(.enabled(if: KeychainProbe.writable, """
        the login keychain cannot be written in this session (locked, absent, or no user interaction), \
        so the one real Keychain round trip cannot run here
        """))
    func aKeyRoundTripsThroughTheRealKeychain() throws {
        let service = "com.xiaolaidict.llm.test.\(getpid()).\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let account = "openAICompatible"
        defer { try? store.delete(account: account) }

        #expect(try store.read(account: account) == nil, "a fresh service already holds a key")
        #expect(try store.contains(account: account) == false, "a fresh service says it holds a key")
        try store.write("sk-first", account: account)
        #expect(try store.read(account: account) == "sk-first")
        #expect(try store.contains(account: account), "a written key is not seen without reading it")
        #expect(try store.contains(account: "someOtherProvider") == false)
        try store.write("sk-second", account: account)
        #expect(try store.read(account: account) == "sk-second", "an overwrite did not replace the key")
        // Another account under the same service is another key.
        #expect(try store.read(account: "someOtherProvider") == nil)

        #expect(try KeychainProbe.isSynchronizable(service: service, account: account) == false)

        try store.delete(account: account)
        #expect(try store.read(account: account) == nil, "a deleted key is still read")
        #expect(try store.contains(account: account) == false, "a deleted key is still said to be there")
        // Deleting what is not there is not a failure: removing a key is safe to repeat.
        try store.delete(account: account)
    }
}

/// Whether this session can write the login keychain, asked by writing and removing an item of its own — and the
/// one attribute the round trip checks that `KeychainCredentialStore` does not report.
enum KeychainProbe {
    static let writable: Bool = {
        let store = KeychainCredentialStore(service: "com.xiaolaidict.llm.test.probe.\(getpid()).\(UUID().uuidString)")
        do {
            try store.write("probe", account: "probe")
            try store.delete(account: "probe")
            return true
        } catch {
            return false
        }
    }()

    /// The stored item's `kSecAttrSynchronizable`, read with a query that matches either value.
    static func isSynchronizable(service: String, account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        try #require(status == errSecSuccess, "SecItemCopyMatching answered \(status)")
        let attributes = try #require(found as? [String: Any])
        // An item filed without the attribute is not synchronisable; one filed with it says so as a number.
        return (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
    }
}
