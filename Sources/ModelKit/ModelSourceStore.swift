import Foundation

/// Where the reader wants model weights fetched from.
///
/// **Three values, not two.** A plain host picker asks a question most readers cannot answer —
/// whether Hugging Face is reachable from where they are — and gets the wrong answer the moment
/// a VPN goes up or down. `fastest` lets the program find out, and the other two are there for
/// a reader who has a reason: a metered link, a proxy, a mirror they trust.
public enum ModelSource: String, Sendable, Equatable, CaseIterable {
    /// Ask both and prefer whichever is actually delivering. **The default.** From mainland
    /// China the probe finds Hugging Face unreachable and answers ModelScope, so this costs a
    /// 1.5-second measurement there rather than a wrong host.
    case fastest
    /// ModelScope alone. **Never departed from**: a reader who names it is not sent to a host
    /// that is unreachable from where they are.
    case modelScope
    /// Hugging Face first, falling back to ModelScope — which has every file, including the one
    /// Hugging Face does not.
    case huggingFace

    /// The hosts to try, in order, before any measurement. Nil where the answer is a probe's.
    public var fixedOrder: [ModelHost]? {
        switch self {
        case .fastest: nil
        case .modelScope: [.modelScope]
        case .huggingFace: [.huggingFace, .modelScope]
        }
    }
}

/// Reads and writes the reader's choice. **Unreadable is `fastest`**, the default, because a
/// half-written or foreign value must not leave the download with nowhere to go.
public struct ModelSourceStore {
    public static let defaultsKey = "ModelDownloadSource"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> ModelSource {
        guard let raw = defaults.object(forKey: Self.defaultsKey) as? String,
              let source = ModelSource(rawValue: raw)
        else { return .fastest }
        return source
    }

    public func save(_ source: ModelSource) {
        defaults.set(source.rawValue, forKey: Self.defaultsKey)
    }
}
