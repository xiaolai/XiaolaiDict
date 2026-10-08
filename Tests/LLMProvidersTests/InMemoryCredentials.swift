import Foundation
import LLMProviders
import Synchronization

/// A credential store that lives in this process, for every test but the one that asks the real Keychain.
///
/// It counts its reads, so a test can see a provider read the key **per call** rather than once and keep it, and it
/// can be told to fail, so a test can see what a provider does when the Keychain will not answer.
final class InMemoryCredentials: CredentialStore {
    private struct State {
        var secrets: [String: String] = [:]
        var reads = 0
        var failure: CredentialStoreFailure?
    }

    private let state: Mutex<State>

    init(_ secrets: [String: String] = [:]) {
        state = Mutex(State(secrets: secrets))
    }

    /// One secret, filed for `endpoint`'s origin — the account a provider for that endpoint reads, and no other.
    convenience init(key: String, for endpoint: URL) {
        self.init([Self.account(for: endpoint): key])
    }

    /// The account a provider for `endpoint` reads its key from. A test that cannot name one has a wrong fixture.
    static func account(for endpoint: URL) -> String {
        EndpointAddress(url: endpoint).map(\.keyAccount) ?? "an endpoint with no origin: \(endpoint)"
    }

    var reads: Int { state.withLock { $0.reads } }
    /// The accounts that hold a secret now.
    var accounts: Set<String> { state.withLock { Set($0.secrets.keys) } }

    func failEveryCall(with failure: CredentialStoreFailure?) {
        state.withLock { $0.failure = failure }
    }

    func read(account: String) throws(CredentialStoreFailure) -> String? {
        let (secret, failure): (String?, CredentialStoreFailure?) = state.withLock {
            $0.reads += 1
            return ($0.secrets[account], $0.failure)
        }
        if let failure { throw failure }
        return secret
    }

    /// Not a read: the secret is not handed out, which is what `contains` is for.
    func contains(account: String) throws(CredentialStoreFailure) -> Bool {
        let (held, failure) = state.withLock { ($0.secrets[account] != nil, $0.failure) }
        if let failure { throw failure }
        return held
    }

    func write(_ secret: String, account: String) throws(CredentialStoreFailure) {
        if let failure = state.withLock({ $0.failure }) { throw failure }
        state.withLock { $0.secrets[account] = secret }
    }

    func delete(account: String) throws(CredentialStoreFailure) {
        if let failure = state.withLock({ $0.failure }) { throw failure }
        _ = state.withLock { $0.secrets.removeValue(forKey: account) }
    }
}
