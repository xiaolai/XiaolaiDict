import Foundation
@testable import LLMProviders
import ModelKit
import Testing

/// **An endpoint's key is filed under its origin, and read for that origin alone** (ADR-0053, plan §10 P4): one
/// origin is one account, whatever path or spelling names it, and every other origin is another account — another
/// host, another port, another scheme, and every address that only looks like the first.
///
/// **And what may be sent to at all**: https anywhere; plain http to this Mac, and — flagged, so the pane can say so —
/// to the local network by its literal address or `.local` name (the owner, 2026-10-09); never plain http to a public
/// host, and never an address carrying a name or a password.
struct EndpointAddressTests {
    static let openAI = "https://api.openai.com/v1"

    static func account(_ text: String) -> String? { EndpointAddress(text)?.keyAccount }

    /// **One origin, one account**: the path, the case of the scheme and host, the scheme's own port written out and
    /// the spaces around a pasted address change nothing — a key the reader gave `/v1` is theirs at `/v2`.
    @Test(arguments: ["https://api.openai.com/v1", "HTTPS://API.OpenAI.com/v1", "https://api.openai.com:443/v1",
                      "https://api.openai.com/v2/", "  https://api.openai.com/v1  ", "https://api.openai.com"])
    func oneOriginIsOneAccount(text: String) throws {
        let account = try #require(Self.account(text), "\(text) names no origin")
        #expect(account == Self.account(Self.openAI))
        #expect(account == "openAICompatible https://api.openai.com:443")
    }

    /// **Every other origin is another account** — including every address written to look like the reader's: a
    /// longer host, a trailing dot, and the reader's host in a query. (Userinfo naming it — `https://a@b` connects to
    /// `b` — and plain HTTP to it are not addresses at all: `anAddressCarryingANameOrAPasswordIsNotOne`.)
    @Test(arguments: [
        "https://api.openai.com:8443/v1", "https://api.openai.com.evil.example/v1",
        "https://evil.example/v1?next=https://api.openai.com/v1", "https://openai.com/v1", "https://api.openai.com./v1",
    ])
    func everyOtherOriginIsAnotherAccount(text: String) throws {
        let account = try #require(Self.account(text), "\(text) names no origin")
        #expect(account != Self.account(Self.openAI), "\(text) shares the key filed for \(Self.openAI)")
    }

    /// **Plain HTTP to a public host is refused** — the key and the reader's sentence would cross networks nobody here
    /// knows, unencrypted. Public by its literal address or name: a hosted API, a public address, every address one step
    /// outside each local-network block, and every name not under `.local` — which only DNS could place, and nothing
    /// here asks it.
    @Test(arguments: [
        "http://api.openai.com/v1", "HTTP://api.example.com/v1", "http://8.8.8.8/v1", "http://[2001:db8::1]/v1",
        // One step outside 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, fc00::/7 and fe80::/10.
        "http://9.255.255.255/v1", "http://11.0.0.0/v1", "http://172.15.255.255/v1", "http://172.32.0.0/v1",
        "http://192.167.255.255/v1", "http://192.169.0.0/v1", "http://169.253.255.255/v1", "http://169.255.0.0/v1",
        "http://100.63.255.255/v1", "http://100.128.0.0/v1", "http://[fbff:ffff::1]/v1", "http://[fe00::1]/v1",
        "http://[fe7f:ffff::1]/v1", "http://[fec0::1]/v1",
        // Not a name under `.local`: the bare word, a name with it inside, names only DNS places, an unqualified name.
        "http://local/v1", "http://another-mac.local.example.com/v1", "http://localish/v1", "http://another-mac.lan/v1",
        "http://192.168.1.5.nip.io/v1", "http://nas/v1",
    ])
    func plainHTTPToAPublicHostIsRefused(text: String) {
        #expect(EndpointAddress.parse(text) == .failure(.unencrypted), "\(text) would be sent unencrypted")
    }

    /// **Plain HTTP to the local network is allowed, and flagged** (the owner, 2026-10-09): a server on the reader's own
    /// network — Ollama on another Mac, LM Studio on a NAS, a machine on their overlay — by its literal private,
    /// link-local, shared (100.64/10) or unique-local address, or its `.local` name; each block's first and last address
    /// included. Decided by the text alone: no name is resolved.
    @Test(arguments: [
        "http://10.0.0.0/v1", "http://10.255.255.255/v1", "http://172.16.0.0/v1", "http://172.31.255.255/v1",
        "http://192.168.0.0/v1", "http://192.168.255.255:11434/v1", "http://169.254.0.0/v1", "http://169.254.255.255/v1",
        "http://100.64.0.0/v1", "http://100.127.255.255/v1", "http://[fc00::]/v1",
        "http://[fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]/v1", "http://[fe80::1]:8080/v1", "http://[febf:ffff::1]/v1",
        "http://another-mac.local:1234/v1", "http://Another-Mac.LOCAL/v1", "http://lab.studio.local/v1",
    ])
    func plainHTTPOnTheLocalNetworkIsAllowedAndFlagged(text: String) throws {
        let address = try #require(EndpointAddress(text), "\(text) was refused")
        #expect(address.transport == .plainOnLocalNetwork)
    }

    /// **A local-network address written any way but plainly is not read as one**, so it needs https like any public
    /// host: forms only `inet_aton` reads, a mapped or zoned IPv6 address, a percent-encoded or non-ASCII host, a trailing
    /// dot, a label no hostname has, an impossible port. Each is where what the text seems to say and where the
    /// connection goes can part. The plain spelling of each is allowed — `plainHTTPOnTheLocalNetworkIsAllowedAndFlagged`.
    @Test(arguments: [
        "http://0192.168.1.5/v1", "http://192.168.01.5/v1", "http://192.168.261/v1", "http://10.1/v1",
        "http://3232235781/v1", "http://0xc0.0xa8.1.5/v1", "http://0xc0a80105/v1", "http://012.0.0.1/v1",
        "http://[::ffff:192.168.1.5]/v1", "http://[::ffff:c0a8:105]/v1", "http://[fe80::1%25en0]/v1",
        "http://192.168.1.%35/v1", "http://another-mac.loca%6c/v1", "http://ａｎｏｔｈｅｒ-mac.local/v1",
        "http://192.168.1.5./v1", "http://another-mac.local./v1", "http://another_mac.local/v1", "http://-mac.local/v1",
        "http://192.168.1.5:99999/v1",
    ])
    func aLocalAddressWrittenAnyWayButPlainlyNeedsHTTPS(text: String) {
        #expect(EndpointAddress(text) == nil, "\(text) would be sent unencrypted")
    }

    /// **Each address says how what is sent to it travels**: https is encrypted wherever the server is — a local-network
    /// host over https is not flagged —, plain http to loopback never crosses a network, and plain http to the local
    /// network does.
    @Test func eachAddressSaysHowWhatIsSentTravels() {
        let cases: [(String, EndpointAddress.Transport)] = [
            ("https://api.openai.com/v1", .encrypted), ("https://192.168.1.5:11434/v1", .encrypted),
            ("https://another-mac.local/v1", .encrypted), ("HTTPS://[fe80::1]/v1", .encrypted),
            ("https://localhost:8443/v1", .encrypted),
            ("http://127.0.0.1:11434/v1", .plainOnThisMac), ("http://localhost/v1", .plainOnThisMac),
            ("http://[::1]:8080/v1", .plainOnThisMac), ("http://ollama.localhost:11434/v1", .plainOnThisMac),
            ("http://192.168.1.5:11434/v1", .plainOnLocalNetwork), ("HTTP://10.0.0.2/v1", .plainOnLocalNetwork),
        ]
        for (text, transport) in cases {
            #expect(EndpointAddress(text)?.transport == transport, "\(text)")
        }
    }

    /// **Allowed is not on this Mac.** A local-network server is another machine, so its tier stays remote: the
    /// reader's sentence only, never the dictionary's text — `RemoteDisclosure`, which the owner's decision left alone.
    @Test(arguments: ["http://192.168.1.5:11434/v1", "http://10.0.0.2/v1", "http://100.64.0.1/v1", "http://[fd00::1]/v1",
                      "http://[fe80::1]/v1", "http://another-mac.local:1234/v1"])
    func aLocalNetworkAddressIsStillRemote(text: String) {
        #expect(EndpointAddress(text)?.transport == .plainOnLocalNetwork, "the premise: \(text) is allowed")
        #expect(RemoteDisclosure.tier(ofEndpoint: text) == .remote)
        #expect(ProviderSource.endpoint(url: text, model: "m").tier == .remote)
    }

    @Test(arguments: ["http://127.0.0.1:11434/v1", "http://localhost:1234/v1", "http://[::1]:8080/v1",
                      "http://ollama.localhost:11434/v1", "https://192.168.1.5:11434/v1", "https://api.example.com/v1"])
    func encryptedOrOnThisMacIsAnAddress(text: String) {
        #expect(EndpointAddress(text) != nil, "\(text)")
    }

    /// **An address carrying a name or a password is not one** — it would keep a credential in the defaults in plain
    /// text, and `https://a@b` connects to `b`, whatever it seems to name.
    @Test(arguments: ["https://reader:hunter2@api.example.com/v1", "https://api.openai.com@evil.example/v1",
                      "http://e2e@localhost:8080/v1", "https://:secret@api.example.com/v1",
                      "https://reader@api.example.com/v1", "http://reader@192.168.1.5:11434/v1",
                      "http://e2e@another-mac.local/v1"])
    func anAddressCarryingANameOrAPasswordIsNotOne(text: String) {
        #expect(EndpointAddress(text) == nil, "\(text) carries a credential")
    }

    /// Two servers on one loopback address are two origins: a port is part of the origin, and of the account.
    @Test func aPortIsPartOfTheOrigin() {
        #expect(Self.account("http://127.0.0.1:11434/v1") == "openAICompatible http://127.0.0.1:11434")
        #expect(Self.account("http://127.0.0.1:11434/v1") != Self.account("http://127.0.0.1:1234/v1"))
        #expect(Self.account("http://localhost:11434/v1") != Self.account("http://127.0.0.1:11434/v1"),
                "two names are two origins, as a browser counts them")
        #expect(Self.account("http://localhost:8443/v1") != Self.account("https://localhost:8443/v1"),
                "two schemes are two origins")
        // So a key saved for a local server over https is never the one sent to it in plain text.
        #expect(Self.account("http://192.168.1.5:11434/v1") == "openAICompatible http://192.168.1.5:11434")
        #expect(Self.account("http://192.168.1.5:11434/v1") != Self.account("https://192.168.1.5:11434/v1"))
    }

    /// **Each refusal is named**, so the pane can say why — and an address the app sends to is no refusal.
    @Test func eachRefusalIsNamed() {
        let cases: [(String, EndpointAddress.Refusal?)] = [
            ("not a url", .notAnAddress), ("ftp://api.openai.com/v1", .notAnAddress), ("https://", .notAnAddress),
            ("https://reader:hunter2@api.example.com/v1", .carriesCredentials),
            ("http://reader@127.0.0.1:11434/v1", .carriesCredentials),
            ("http://reader@192.168.1.5:11434/v1", .carriesCredentials),
            ("http://api.openai.com/v1", .unencrypted), ("http://8.8.8.8/v1", .unencrypted),
            ("http://172.32.0.1/v1", .unencrypted),
            ("https://api.openai.com/v1", nil), ("http://127.0.0.1:11434/v1", nil), ("http://[::1]:8080/v1", nil),
            ("http://192.168.1.5:11434/v1", nil), ("http://another-mac.local/v1", nil),
        ]
        for (text, refusal) in cases {
            switch EndpointAddress.parse(text) {
            case .success: #expect(refusal == nil, "\(text) was taken as an address")
            case .failure(let refused): #expect(refused == refusal, "\(text)")
            }
        }
    }

    /// An IPv6 host is written in its brackets, so the port after it cannot be read as one of its groups.
    @Test func anIPv6HostKeepsItsBrackets() {
        #expect(Self.account("http://[::1]:8080/v1") == "openAICompatible http://[::1]:8080")
        #expect(EndpointAddress("http://[::1]:8080/v1")?.displayHost == "[::1]:8080")
    }

    /// **An address with no origin has no account**, so no key is read for it: not http(s), no host, not a URL.
    @Test(arguments: ["", "   ", "ftp://api.openai.com/v1", "https://", "not a url", "api.openai.com/v1",
                      "file:///etc/hosts"])
    func anAddressWithNoOriginHasNoAccount(text: String) {
        #expect(EndpointAddress(text) == nil, "\(text) was read as an address")
    }

    /// The host as a reader recognises it: the port only where it is not the scheme's own.
    @Test func theHostShownIsTheOneTheReaderWrote() {
        #expect(EndpointAddress("https://api.openai.com/v1")?.displayHost == "api.openai.com")
        #expect(EndpointAddress("https://API.openai.com:443/v1")?.displayHost == "api.openai.com")
        #expect(EndpointAddress("http://127.0.0.1:11434/v1")?.displayHost == "127.0.0.1:11434")
        #expect(EndpointAddress("http://localhost/v1")?.displayHost == "localhost")
    }

    /// **The URL requests go to is the one parsed** — the base joined to by the provider, unchanged — so the address
    /// whose account is read and the address that is asked cannot be two readings of one text.
    @Test func theURLIsTheOneTheAccountWasReadFrom() throws {
        let address = try #require(EndpointAddress("  https://api.openai.com/v1?api-version=1  "))
        #expect(address.url.absoluteString == "https://api.openai.com/v1?api-version=1")
        #expect(EndpointAddress(url: address.url) == address)
    }
}
