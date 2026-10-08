import Foundation
import ModelKit

/// **An OpenAI-compatible endpoint's address, read once for everything that depends on it** (ADR-0053): where its
/// requests go, and which Keychain account its key is filed under — one parse for both, so they cannot differ.
///
/// **The key belongs to the endpoint's origin** — scheme, host and port — and is read for that origin alone. The
/// endpoint's URL is a plain defaults value, and anything that can write the app's defaults can change it; a key filed
/// under the provider alone went wherever that value pointed next. Filed under the origin, a URL rewritten to another
/// host names another account, which holds no key until the reader enters one there — so a key is only ever sent to the
/// origin it was saved for. A path is not part of it: one origin is one server's authority, and a key the reader gave
/// `https://api.openai.com/v1` is theirs to use at `https://api.openai.com/v2`.
///
/// Read failing closed, as `RemoteDisclosure` reads the tier: an address this cannot name an origin for — not http(s),
/// no host — has no account, so no key is read for it.
public struct EndpointAddress: Sendable, Equatable {
    /// The base URL requests are joined to.
    public let url: URL
    private let origin: SameOriginRedirects.Origin

    /// The address the reader wrote, or nil where it is not an http(s) URL with a host.
    public init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        self.init(url: url)
    }

    /// `url`'s address, or nil where it is not an http(s) URL with a host.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let origin = SameOriginRedirects.Origin(url)
        else { return nil }
        self.url = url
        self.origin = origin
    }

    /// **The Keychain account this endpoint's key is filed under**: the provider's name, then the origin —
    /// `openAICompatible https://api.openai.com:443`. The port is always written, so an address that leaves it out and
    /// one that writes the scheme's own are one origin, as they are on the wire.
    public var keyAccount: String {
        "\(ProviderChoice.openAICompatible.rawValue) \(origin.scheme)://\(host):\(origin.port)"
    }

    /// The host as a reader recognises it, with its port only where it is not the scheme's own — `api.openai.com`,
    /// `127.0.0.1:11434`. A name, not prose: the view layer puts it in a sentence of its own.
    public var displayHost: String {
        origin.port == SameOriginRedirects.Origin.standardPort(of: origin.scheme) ? host : "\(host):\(origin.port)"
    }

    /// The origin's host, an IPv6 address in its brackets so a port after it cannot be read as one of its groups.
    private var host: String {
        origin.host.contains(":") ? "[\(origin.host)]" : origin.host
    }
}
