import Foundation
@testable import ModelKit
import Testing

/// **An endpoint's host is read from its text only where nothing could read it another way** (ADR-0053) — the one
/// reading that both `RemoteDisclosure` (is it this Mac?) and `EndpointAddress` (is it on the local network?) judge, so
/// the two can never read one host two ways. Each refusal is a spelling some other reader — `inet_aton`, IDNA, the URL
/// loader — would take somewhere the text does not plainly say; each has its plain spelling beside it, read.
struct EndpointHostTests {
    /// **A plain host is read as it is written**: four decimal numbers, eight IPv6 groups in any of their spellings, or
    /// hostname labels, lowercased — whatever the scheme's case, the port or the path.
    @Test func aPlainHostIsReadAsItIsWritten() {
        let cases: [(String, EndpointHost)] = [
            ("http://192.168.1.5:11434/v1", .ipv4(192, 168, 1, 5)), ("HTTPS://10.0.0.255/v1", .ipv4(10, 0, 0, 255)),
            ("http://0.0.0.0", .ipv4(0, 0, 0, 0)), ("http://[fe80::1]/v1", .ipv6([0xFE80, 0, 0, 0, 0, 0, 0, 1])),
            ("http://[FD12:3456::]:8080/v1", .ipv6([0xFD12, 0x3456, 0, 0, 0, 0, 0, 0])),
            ("http://[1:2:3:4:5:6:7:8]/v1", .ipv6([1, 2, 3, 4, 5, 6, 7, 8])),
            // A mapping written in hex is an IPv6 address like any other; nothing judges it this Mac or the network.
            ("http://[::ffff:c0a8:105]/v1", .ipv6([0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x105])),
            ("http://Another-Mac.LOCAL:1234/v1", .name(["another-mac", "local"])),
            ("https://api.openai.com/v1", .name(["api", "openai", "com"])), ("http://localhost", .name(["localhost"])),
            ("http://192.168.1.5.nip.io/v1", .name(["192", "168", "1", "5", "nip", "io"])),
        ]
        for (endpoint, host) in cases {
            #expect(EndpointHost(endpoint: endpoint) == host, "\(endpoint)")
        }
    }

    /// **What cannot be read without interpreting is not read at all.** Address forms only `inet_aton` reads as an
    /// address (`0300.0250.1.5` and `3232235781` are 192.168.1.5 there, `10.1` is 10.0.0.1) — so no name ends in a number
    /// —, a dotted mapping or a zone in IPv6, percent-encoding, a non-ASCII spelling (IDNA maps full-width letters to
    /// ASCII), a trailing dot, a label that is not a hostname's, an impossible port, a userinfo, a scheme that is not
    /// http(s), and what is not a URL with a host.
    @Test(arguments: [
        "http://0192.168.1.5/v1", "http://192.168.01.5/v1", "http://0300.0250.1.5/v1", "http://192.168.261/v1",
        "http://10.1/v1", "http://3232235781/v1", "http://0xc0.0xa8.1.5/v1", "http://0xc0a80105/v1",
        "http://192.168.1.256/v1", "http://192.168.1.5.6/v1",
        "http://[::ffff:192.168.1.5]/v1", "http://[fe80::1%25en0]/v1", "http://[1:2:3:4:5:6:7]/v1",
        "http://[1:2:3:4:5:6:7:8:9]/v1", "http://[1::2::3]/v1", "http://[12345::1]/v1", "http://[fe80::1/v1",
        "http://192.168.1.%35/v1", "http://another-mac.loca%6c/v1", "http://ａｎｏｔｈｅｒ-mac.local/v1",
        "http://192.168.1.5./v1", "http://another-mac.local./v1", "http://another_mac.local/v1",
        "http://-mac.local/v1", "http://mac-.local/v1", "http://a..local/v1",
        "http://192.168.1.5:99999/v1", "http://reader@192.168.1.5/v1", "http://:pass@another-mac.local/v1",
        "ftp://192.168.1.5/v1", "ws://another-mac.local/v1", "192.168.1.5", "http://", "", "not a url at all",
    ])
    func whatCannotBeReadWithoutInterpretingIsNotRead(endpoint: String) {
        let read = EndpointHost(endpoint: endpoint)
        #expect(read == nil, "\(endpoint) was read as \(String(describing: read))")
    }
}
