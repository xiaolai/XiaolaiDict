import Foundation
@testable import LLMProviders
import Testing

/// **An endpoint's key is filed under its origin, and read for that origin alone** (ADR-0053, plan §10 P4): one
/// origin is one account, whatever path or spelling names it, and every other origin is another account — another
/// host, another port, another scheme, and every address that only looks like the first.
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

    /// **Every other origin is another account** — including every address written to look like the reader's:
    /// a longer host, userinfo that names it (`http://a@b` connects to `b`), and the reader's host in a query.
    @Test(arguments: [
        "http://api.openai.com/v1", "https://api.openai.com:8443/v1", "https://api.openai.com.evil.example/v1",
        "https://api.openai.com@evil.example/v1", "https://evil.example/v1?next=https://api.openai.com/v1",
        "https://openai.com/v1", "https://api.openai.com./v1",
    ])
    func everyOtherOriginIsAnotherAccount(text: String) throws {
        let account = try #require(Self.account(text), "\(text) names no origin")
        #expect(account != Self.account(Self.openAI), "\(text) shares the key filed for \(Self.openAI)")
    }

    /// Two servers on one loopback address are two origins: a port is part of the origin, and of the account.
    @Test func aPortIsPartOfTheOrigin() {
        #expect(Self.account("http://127.0.0.1:11434/v1") == "openAICompatible http://127.0.0.1:11434")
        #expect(Self.account("http://127.0.0.1:11434/v1") != Self.account("http://127.0.0.1:1234/v1"))
        #expect(Self.account("http://localhost:11434/v1") != Self.account("http://127.0.0.1:11434/v1"),
                "two names are two origins, as a browser counts them")
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
