import Foundation

/// The hover policy, kept across launches.
///
/// `HoverPolicy` was `Codable` and taken as `() -> HoverPolicy` from the day it was written — the
/// shape of a value that changes — while the only value that existed was the hardcoded `.shipped`.
/// The reader could not pick a modifier, exclude an app or a site, or change how long the pointer
/// must rest. This is what the closure was always for.
///
/// Stored as one encoded value rather than a key per field: the policy is decided as a whole by
/// `decide`, and a half-applied policy — a new modifier with the old exclusions — is a state no
/// reader asked for and no test would think to write.
public struct HoverPolicyStore {
    public static let defaultsKey = "HoverPolicy"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unreadable is `.shipped`, never a failure and never an empty policy. A preferences file
    /// written by a later version, or half-written by a crash, must not leave the reader with no
    /// modifier gate and no exclusions — the one state this type exists to prevent. `object` and
    /// an `as?` cast rather than `data(forKey:)`, so a value of some entirely different type
    /// reaching this key is the same ordinary fallback rather than a surprise.
    public func load() -> HoverPolicy {
        guard let data = defaults.object(forKey: Self.defaultsKey) as? Data,
              var stored = try? JSONDecoder().decode(HoverPolicy.self, from: data)
        else { return .shipped }
        // **The password-manager exclusion is a rule, not a preference.** The ledger stores the
        // sentence a word was read in, so a lookup in a password manager writes a secret to disk;
        // there the whole surface is secrets. A stored policy that has lost them — an older
        // version, an edited plist, a partial write — is corrected on the way in rather than
        // trusted. What the reader added is kept alongside, because that part *is* a preference.
        stored.excludedApps.formUnion(HoverPolicy.defaultExcludedApps)
        return stored
    }

    public func save(_ policy: HoverPolicy) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
