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

    /// One secret, under the account an OpenAI-compatible provider reads.
    convenience init(key: String) {
        self.init([OpenAICompatibleProvider.credentialAccount: key])
    }

    var reads: Int { state.withLock { $0.reads } }

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

    func write(_ secret: String, account: String) throws(CredentialStoreFailure) {
        if let failure = state.withLock({ $0.failure }) { throw failure }
        state.withLock { $0.secrets[account] = secret }
    }

    func delete(account: String) throws(CredentialStoreFailure) {
        if let failure = state.withLock({ $0.failure }) { throw failure }
        _ = state.withLock { $0.secrets.removeValue(forKey: account) }
    }
}
