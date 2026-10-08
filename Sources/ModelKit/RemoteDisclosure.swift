import Foundation

/// Where a language-model source runs, which decides what it may be sent (ADR-0053, plan §3).
public enum ProviderTier: String, Sendable, Equatable, CaseIterable {
    /// On this Mac: the bundled model, or an endpoint whose host is loopback. May see the reader's sentence and the
    /// dictionary's sense text, as the local model always could.
    case onThisMac
    /// Anywhere else — both CLIs, and every endpoint that is not loopback beyond doubt. Sees the reader's own
    /// sentence only, unless `RemoteDisclosure.dictionaryTextMayLeave` says otherwise.
    case remote
}

/// **What may leave the Mac, decided in one place** — consulted by whatever builds a request for a provider, and by
/// nothing that could decide it differently.
///
/// The dictionaries are licensed to the reader, not to this app (ADR-0013): a publisher's definition may go to a
/// model that runs on this Mac and not to a remote service. The reader's own sentence may go anywhere they send it.
/// So the tier is a licence boundary, and the endpoint's tier is read **failing closed**: a loopback server misread
/// as remote costs an answer's quality, and a remote one misread as loopback sends a publisher's text off the Mac.
public enum RemoteDisclosure {
    /// **Whether the remote tier may be sent the dictionary's text. `false`, and the owner's to flip** (ADR-0053):
    /// they have not said the dictionary's text may leave the Mac. Flipping it is the whole change — the remote tier is
    /// then asked to pick a sense and told the sense a translation is for — and the one decision that turns the
    /// measured quality of the hosted models into the product's.
    public static let dictionaryTextMayLeave = false

    /// Whether a source of `tier` may be sent a publisher's text: on this Mac always, remote only once the owner says.
    public static func mayCarryDictionaryText(_ tier: ProviderTier) -> Bool {
        mayCarryDictionaryText(tier, dictionaryTextMayLeave: dictionaryTextMayLeave)
    }

    /// The rule with the constant as an argument, so both arms of the flip are tested before anyone flips it.
    static func mayCarryDictionaryText(_ tier: ProviderTier, dictionaryTextMayLeave: Bool) -> Bool {
        tier == .onThisMac || dictionaryTextMayLeave
    }

    /// The tier of the source `choice`, where its endpoint — read only for `.openAICompatible` — is `endpoint`.
    /// **Both CLIs are remote whatever is installed where**: a CLI is a client of its vendor's service. Nil for
    /// `.none`, which is asked nothing.
    public static func tier(of choice: ProviderChoice, endpoint: String) -> ProviderTier? {
        switch choice {
        case .none: nil
        case .claudeCLI, .codexCLI: .remote
        case .openAICompatible: tier(ofEndpoint: endpoint)
        case .localModel: .onThisMac
        }
    }

    /// **The tier of an endpoint, from its URL alone: on this Mac only where the host is loopback beyond doubt.**
    ///
    /// Loopback is `localhost`, a name under `.localhost`, an IPv4 address in 127.0.0.0/8 written as four plain
    /// decimal numbers, and `::1`. Everything else is remote — a private LAN address or a `.local` name is another
    /// machine — and so is everything this cannot read without interpreting: a scheme other than http(s), any
    /// userinfo (`http://localhost@evil.com` connects to `evil.com`), a percent-encoded or non-ASCII host (a URL parser
    /// decodes and maps those, and the connection may not go where the text appears to say), an address written the
    /// way only `inet_aton` reads it (`0127.0.0.1` is 87.0.0.1 there, `2130706433` is 127.0.0.1), a mapped or zoned
    /// IPv6 address, a trailing dot, an impossible port.
    ///
    /// `*.localhost` is loopback because the system resolver answers it so without asking DNS — measured on macOS 27,
    /// `dscacheutil -q host -a name xiaolaidict-probe.localhost` answered `::1` and `127.0.0.1` (2026-10-09) — as
    /// RFC 6761 §6.3 asks of a resolver.
    public static func tier(ofEndpoint endpoint: String) -> ProviderTier {
        isLoopback(endpoint) ? .onThisMac : .remote
    }

    private static func isLoopback(_ endpoint: String) -> Bool {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(\.isASCII),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.encodedHost?.lowercased(), !host.isEmpty, !host.contains("%")
        else { return false }
        if let port = components.port, !(1...65_535).contains(port) { return false }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return false }
            return isIPv6Loopback(host.dropFirst().dropLast())
        }
        return isLoopbackName(host) || isIPv4Loopback(host)
    }

    /// `localhost`, or a name ending in `.localhost` whose every label is a plain hostname label.
    private static func isLoopbackName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.last == "localhost" else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Four decimal numbers 0–255, none with a leading zero, the first 127. Nothing `inet_aton` would read some
    /// other way: no octal, no hex, no short form, no single integer.
    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0", let value = Int(part), value <= 255
            else { return false }
            octets.append(value)
        }
        return octets.first == 127
    }

    /// `::1` in any spelling of its eight groups — `::1`, `0:0:0:0:0:0:0:1`, `0000::0001` — and nothing else: no
    /// zone, no embedded IPv4 (`::ffff:127.0.0.1` is a mapping, decided by the stack, not by this text).
    private static func isIPv6Loopback(_ address: Substring) -> Bool {
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
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
        guard let head = groups(halves[0]) else { return false }
        var all = head
        if halves.count == 2 {
            guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return false }
            all += Array(repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        return all == [0, 0, 0, 0, 0, 0, 0, 1]
    }
}
