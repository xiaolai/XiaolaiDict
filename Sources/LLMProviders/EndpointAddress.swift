import Foundation
import ModelKit

/// **An OpenAI-compatible endpoint's address, read once for everything that depends on it** (ADR-0053): whether the app
/// may send to it at all, where its requests go, and which Keychain account its key is filed under — one parse for all
/// three, so they cannot differ. The pane refuses to keep an address this refuses, the factory refuses to make a
/// provider for one, and a provider can only be made from one of these.
///
/// **What may be sent to, one rule** (`Refusal`): an http(s) URL with a host; **no name or password in it** — it would
/// sit in the defaults in plain text, and `https://a@b` connects to `b`, whatever it seems to name; and **plain HTTP only
/// to this Mac**, loopback beyond doubt as `RemoteDisclosure` reads it. Anywhere else the key and the reader's sentence
/// would cross the network unencrypted — and `NSAllowsLocalNetworking`, which loopback needs, lets the system send
/// plain HTTP to a LAN address or a `.local` name without a word, so this app refuses to.
///
/// **The key belongs to the endpoint's origin** — scheme, host and port — and is read for that origin alone. The
/// endpoint's URL is a plain defaults value, and anything that can write the app's defaults can change it; a key filed
/// under the provider alone went wherever that value pointed next. Filed under the origin, a URL rewritten to another
/// host names another account, which holds no key until the reader enters one there — so a key is only ever sent to the
/// origin it was saved for. A path is not part of it: one origin is one server's authority, and a key the reader gave
/// `https://api.openai.com/v1` is theirs to use at `https://api.openai.com/v2`.
public struct EndpointAddress: Sendable, Equatable {
    /// Why an address is not one the app sends to — a kind, worded by the view layer.
    public enum Refusal: Error, Sendable, Equatable {
        /// Not an http(s) URL with a host.
        case notAnAddress
        /// It names a user or a password.
        case carriesCredentials
        /// Plain `http://` to a host that is not this Mac.
        case unencrypted
    }

    /// The base URL requests are joined to.
    public let url: URL
    private let origin: SameOriginRedirects.Origin

    /// The address the reader wrote, or why the app will not send to it.
    public static func parse(_ text: String) -> Result<EndpointAddress, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed) else { return .failure(.notAnAddress) }
        return parse(url: url, text: trimmed)
    }

    /// `url`'s address, or why the app will not send to it.
    public static func parse(url: URL) -> Result<EndpointAddress, Refusal> {
        parse(url: url, text: url.absoluteString)
    }

    /// The address the reader wrote, or nil where the app will not send to it.
    public init?(_ text: String) {
        guard case .success(let address) = Self.parse(text) else { return nil }
        self = address
    }

    /// `url`'s address, or nil where the app will not send to it.
    public init?(url: URL) {
        guard case .success(let address) = Self.parse(url: url) else { return nil }
        self = address
    }

    private init(url: URL, origin: SameOriginRedirects.Origin) {
        self.url = url
        self.origin = origin
    }

    /// The rule, over a URL and the text it was read from — the text being what `RemoteDisclosure` judges, failing closed.
    private static func parse(url: URL, text: String) -> Result<EndpointAddress, Refusal> {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let origin = SameOriginRedirects.Origin(url)
        else { return .failure(.notAnAddress) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard components?.user == nil, components?.password == nil else { return .failure(.carriesCredentials) }
        guard scheme == "https" || RemoteDisclosure.tier(ofEndpoint: text) == .onThisMac else {
            return .failure(.unencrypted)
        }
        return .success(EndpointAddress(url: url, origin: origin))
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
