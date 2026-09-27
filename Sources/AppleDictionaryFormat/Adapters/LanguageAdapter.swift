/// One language's Apple dictionaries, declared rather than parsed.
///
/// **Why a language is a list and not a dictionary.** Apple gives a reader a *set* per region — a
/// bilingual, sometimes a monolingual, sometimes a thesaurus or an idiom dictionary — and which of
/// them exist depends on the Mac's languages. So an adapter names every dictionary it knows for a
/// language and the caller uses whichever are installed. Nothing here assumes any of them is present.
///
/// **Publisher matters and is recorded, because "Oxford" is often not the author.** Apple licenses its
/// whole third-party dictionary programme through Oxford University Press, so almost every bundle
/// carries an `.oup`-flavoured identifier and a copyright mentioning Oxford. Only two of the five
/// languages below actually have an Oxford-authored bilingual.
public struct DictionaryDescriptor: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case bilingual, monolingual, thesaurus, idioms
    }

    public let identifier: String
    public let title: String
    public let kind: Kind
    /// Who wrote it, as its own copyright states — not who Apple licensed it through.
    public let author: String
    /// The attribute its senses carry, measured. Nil means the publisher supplies none and
    /// `SenseKey`'s content form is required.
    public let senseIDAttribute: String?

    /// **An adapter declares the id attribute, never the depth.**
    ///
    /// The two facts are measured by different things and only one of them is an adapter's to know.
    /// Which attribute carries the publisher id is a property of that dictionary's markup, which the
    /// adapter measures and pins. The depth that retains a dictionary's definitions is measured over the
    /// whole catalogue by `DepthRetentionTests` and lives in `DictionaryProfile.overrides`.
    ///
    /// This hardcoded `senseDepth: 1`, and `LanguageAdapters.profile(for:)` consults adapters *before*
    /// the override table — so any adapter claiming one of the five deeper dictionaries would silently
    /// reset it to 1 and lose up to 77% of its definitions. Latent rather than live, because no adapter
    /// claims one of the five today; `anAdapterCannotOverrideAMeasuredDepth` is what keeps it that way.
    public var profile: DictionaryProfile {
        DictionaryProfile(identifier: identifier,
                          senseDepth: DictionaryProfile.profile(for: identifier).senseDepth,
                          senseIDAttributes: senseIDAttribute.map { [$0] } ?? [])
    }

    public init(identifier: String, title: String, kind: Kind, author: String, senseIDAttribute: String?) {
        self.identifier = identifier
        self.title = title
        self.kind = kind
        self.author = author
        self.senseIDAttribute = senseIDAttribute
    }
}

/// A language's dictionaries. Each conformer is one file, so a language can be added or corrected
/// without touching another.
public protocol LanguageAdapter: Sendable {
    /// BCP-47-ish tag, as Apple's identifiers spell it.
    static var language: String { get }
    static var dictionaries: [DictionaryDescriptor] { get }
}

public extension LanguageAdapter {
    /// The ones actually installed on this Mac, paired with their bundles.
    static func installed(from found: [DictionaryBundle] = DictionaryLocator.installed())
        -> [(DictionaryDescriptor, DictionaryBundle)] {
        let byIdentifier = Dictionary(found.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        return dictionaries.compactMap { descriptor in
            byIdentifier[descriptor.identifier].map { (descriptor, $0) }
        }
    }
}

/// Every language this module knows, for a caller that wants to rebuild whatever is present.
public enum LanguageAdapters {
    public static let all: [any LanguageAdapter.Type] = [
        SimplifiedChinese.self, TraditionalChinese.self, Cantonese.self, Korean.self, Japanese.self,
    ]

    /// The profile for a bundle: a declared one when a language adapter names it, otherwise the
    /// default. Keyed by `CFBundleIdentifier`, never by name.
    public static func profile(for identifier: String) -> DictionaryProfile {
        for adapter in all {
            if let d = adapter.dictionaries.first(where: { $0.identifier == identifier }) {
                return d.profile
            }
        }
        return .profile(for: identifier)
    }
}
