import Foundation
import ModelKit

/// **An OpenAI-compatible endpoint's address, read once for everything that depends on it** (ADR-0053): whether the app
/// may send to it at all, how what it sends travels, where its requests go, and which Keychain account its key is filed
/// under — one parse for all four, so they cannot differ. The pane refuses to keep an address this refuses, the factory
/// refuses to make a provider for one, and a provider can only be made from one of these.
///
/// **What may be sent to, one rule** (`Refusal`): an http(s) URL with a host; **no name or password in it** — it would
/// sit in the defaults in plain text, and `https://a@b` connects to `b`, whatever it seems to name; and **plain HTTP
/// only where no network beyond the reader's own is crossed** — to this Mac, loopback beyond doubt as `RemoteDisclosure`
/// reads it, or to the local network by its literal address or `.local` name. The second is allowed **and flagged**
/// (`Transport.plainOnLocalNetwork`, the owner's decision of 2026-10-09), so the pane says that anyone on that network
/// can read what is sent and asks before a key is filed for it. Plain HTTP to any other host would carry the key and the
/// reader's sentence unencrypted across networks nobody here knows, so this app refuses it — whatever App Transport
/// Security would do, since `NSAllowsLocalNetworking`, which loopback needs, loosens it for local names and addresses.
///
/// **Where an address is is no part of what it may be sent.** A local-network server is another machine, so it is
/// remote to `RemoteDisclosure` and sent the reader's sentence only; the transport says how that sentence travels.
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
        /// Plain `http://` to a host that is neither this Mac nor, by its literal address or name, the local network.
        case unencrypted
    }

    /// **How what is sent to an address travels** — and so whether anyone on a network between can read it.
    public enum Transport: Sendable, Equatable {
        /// `https://`: encrypted, wherever the server is.
        case encrypted
        /// `http://` to this Mac's loopback: never on a network.
        case plainOnThisMac
        /// `http://` to the local network — a private, link-local, shared (100.64/10) or unique-local address, or a
        /// `.local` name: **anyone on that network can read the reader's sentence, and the key where one is saved.**
        /// Allowed, and said wherever the address is set (the owner, 2026-10-09).
        case plainOnLocalNetwork
    }

    /// The base URL requests are joined to.
    public let url: URL
    /// How what is sent to it travels.
    public let transport: Transport
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

    private init(url: URL, transport: Transport, origin: SameOriginRedirects.Origin) {
        self.url = url
        self.transport = transport
        self.origin = origin
    }

    /// The rule, over a URL and the text it was read from — the text being what `RemoteDisclosure` and `EndpointHost`
    /// judge, failing closed.
    private static func parse(url: URL, text: String) -> Result<EndpointAddress, Refusal> {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let origin = SameOriginRedirects.Origin(url)
        else { return .failure(.notAnAddress) }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard components?.user == nil, components?.password == nil else { return .failure(.carriesCredentials) }
        guard let transport = transport(scheme: scheme, text: text) else { return .failure(.unencrypted) }
        return .success(EndpointAddress(url: url, transport: transport, origin: origin))
    }

    /// How what is sent to `text` travels, or nil where plain HTTP would cross a network this cannot vouch for. A host
    /// `EndpointHost` cannot read without interpreting is neither this Mac nor the local network.
    private static func transport(scheme: String, text: String) -> Transport? {
        if scheme == "https" { return .encrypted }
        if RemoteDisclosure.tier(ofEndpoint: text) == .onThisMac { return .plainOnThisMac }
        if let host = EndpointHost(endpoint: text), isOnLocalNetwork(host) { return .plainOnLocalNetwork }
        return nil
    }

    /// **The local network, by the literal address or name alone** — nothing is resolved, since a name that DNS answers
    /// could lead anywhere. IPv4: 10/8, 172.16/12 and 192.168/16 (RFC 1918), 169.254/16 (link-local, RFC 3927) and
    /// 100.64/10 (shared address space, RFC 6598 — carrier-grade NAT and overlay networks). IPv6: fc00::/7 (unique local,
    /// RFC 4193) and fe80::/10 (link-local). A name under `.local` (multicast DNS, RFC 6762), which is answered on the
    /// link alone; `local` by itself names no machine.
    private static func isOnLocalNetwork(_ host: EndpointHost) -> Bool {
        switch host {
        case .ipv4(let first, let second, _, _):
            first == 10 || (first == 172 && (16...31).contains(second)) || (first == 192 && second == 168)
                || (first == 169 && second == 254) || (first == 100 && (64...127).contains(second))
        case .ipv6(let groups):
            groups.first.map { ($0 & 0xFE00) == 0xFC00 || ($0 & 0xFFC0) == 0xFE80 } ?? false
        case .name(let labels):
            labels.count > 1 && labels.last == "local"
        }
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
