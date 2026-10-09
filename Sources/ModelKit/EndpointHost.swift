import Foundation

/// **An endpoint's host, read from the text of its URL alone — and only where nothing could read it another way**
/// (ADR-0053). Two questions are asked of an endpoint's host without asking the network: whether it is this Mac
/// (`RemoteDisclosure`, which decides what may be sent there) and whether it is on the local network
/// (`EndpointAddress`, which decides whether plain HTTP may carry anything there). Both read the host here, so the two
/// can never read one host two ways; each judges the reading by its own rule.
///
/// **Nil is "nothing may be concluded"**, and both judges read it failing closed: neither this Mac nor the local
/// network. It is what everything is that cannot be read without interpreting — a scheme other than http(s); any
/// userinfo (`http://localhost@evil.com` connects to `evil.com`); a percent-encoded or non-ASCII host (a URL parser
/// decodes and maps those — IDNA turns full-width letters into ASCII — and the connection may not go where the text
/// appears to say); an impossible port; an IPv6 address with a zone, or with an IPv4 address written into it
/// (`::ffff:127.0.0.1` is a mapping, decided by the stack); and a name ending in a number, which is how every address
/// `inet_aton` reads and a strict reader does not is written — `0127.0.0.1` is 87.0.0.1 there, `2130706433` and
/// `127.1` are 127.0.0.1, `0xc0a80105` is 192.168.1.5 — and how no top-level domain is.
public enum EndpointHost: Sendable, Equatable {
    /// An IPv4 address written as four decimal numbers 0–255, none with a leading zero.
    case ipv4(UInt8, UInt8, UInt8, UInt8)
    /// An IPv6 address in its brackets, as its eight groups: `::` expanded, any spelling of each group.
    case ipv6([UInt16])
    /// A name: lowercased labels of ASCII letters, digits and hyphens, none empty, none starting or ending with a
    /// hyphen, the last starting with a letter. Nothing is resolved — a name says where it leads only by what its own
    /// labels say, and only a judge that names the last label it accepts concludes anything from it.
    case name([String])

    /// `endpoint`'s host, or nil where it cannot be read without interpreting.
    public init?(endpoint: String) {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(\.isASCII),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.encodedHost?.lowercased(), !host.isEmpty, !host.contains("%")
        else { return nil }
        if let port = components.port, !(1...65_535).contains(port) { return nil }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), let groups = Self.ipv6Groups(host.dropFirst().dropLast()) else { return nil }
            self = .ipv6(groups)
        } else if let octets = Self.ipv4Octets(host) {
            self = .ipv4(octets[0], octets[1], octets[2], octets[3])
        } else if let labels = Self.nameLabels(host) {
            self = .name(labels)
        } else {
            return nil
        }
    }

    /// Four decimal numbers 0–255, none with a leading zero: nothing `inet_aton` would read some other way — no octal,
    /// no hex, no short form, no single integer.
    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0", let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Eight groups of one to four hex digits, at most one `::` standing for the zero groups it leaves out — `::1`,
    /// `0:0:0:0:0:0:0:1` and `0000::0001` alike. No zone, no embedded IPv4.
    private static func ipv6Groups(_ address: Substring) -> [UInt16]? {
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ text: String) -> [UInt16]? {
            if text.isEmpty { return [] }
            var values: [UInt16] = []
            for group in text.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit),
                      let value = UInt16(group, radix: 16) else { return nil }
                values.append(value)
            }
            return values
        }
        guard let head = groups(halves[0]) else { return nil }
        guard halves.count == 2 else { return head.count == 8 ? head : nil }
        guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    /// Every label a hostname's, and the last starting with a letter — so no spelling of an address is a name.
    private static func nameLabels(_ host: String) -> [String]? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.last?.first?.isLetter == true, labels.allSatisfy(isHostnameLabel) else { return nil }
        return labels
    }

    private static func isHostnameLabel(_ label: String) -> Bool {
        !label.isEmpty && label.first != "-" && label.last != "-"
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
