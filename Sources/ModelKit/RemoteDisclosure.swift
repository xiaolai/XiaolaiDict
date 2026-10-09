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

    /// The rule with the constant as an argument, so both arms of the flip are tested before anyone flips it. Public
    /// for the providers' client, whose own tests pass both arms through it; the app reads the constant above.
    public static func mayCarryDictionaryText(_ tier: ProviderTier, dictionaryTextMayLeave: Bool) -> Bool {
        tier == .onThisMac || dictionaryTextMayLeave
    }

    /// **Whether `outgoing` carries any of the publisher's text `request` holds** — the check made at the send, over
    /// the bytes about to go, not over the prompt someone meant to build (plan §3).
    ///
    /// The dictionary's texts are a sense list's senses, the sense a translation is told and the sense an explanation
    /// is given. Each is looked for **in every form a prompt can carry it**: its first `probeLength` characters,
    /// flattened onto one line as `ModelPrompt.flattened` does and as they are, which is a prefix of every cut a prompt
    /// makes — so a builder that cuts at 240 or 400, or not at all, is caught alike.
    ///
    /// **The reader's own words are theirs**: a form their sentence or the word they looked up already holds — a
    /// one-word sense that is the word itself, a gloss quoted in the sentence they are reading — is not looked for,
    /// because sending it sends nothing of the publisher's. A text shorter than `minimumProbe` characters is not looked
    /// for either: it cannot be told from an ordinary word, and it holds none of a publisher's expression.
    public static func leaks(_ outgoing: String, of request: ModelRequest) -> Bool {
        let (texts, own): ([String], [String]) = switch request {
        case .pickSense(let question): (question.senses, [question.sentence])
        case .translate(let question): (question.met.map { [$0.sense] } ?? [], [question.sentence, question.met?.term ?? ""])
        case .explain(let question): (question.senseText.map { [$0] } ?? [], [question.sentence, question.term])
        case .prewarm, .status, .unload: ([], [])
        }
        let readers = readersWords(own)
        // **A probe the reader's own words hold is theirs too**, and sending it sends nothing of the publisher's. It is
        // dropped rather than the reader's words cut out of `outgoing`: cutting a headword out would split a sense that
        // uses it, and hide exactly the text this looks for.
        let probes = texts.flatMap(probes(of:)).filter { probe in !readers.contains { $0.contains(probe) } }
        return probes.contains { outgoing.contains($0) }
    }

    /// The forms of `text` that are looked for: its first `probeLength` characters flattened, as a prompt carries
    /// them, and as written, as a builder that forgot to flatten would carry them — **and every further run of
    /// `probeLength` characters of each, end to end**, so a sense whose opening the reader's own words hold is still
    /// looked for in the rest of it. None for a text too short to tell.
    private static func probes(of text: String) -> [String] {
        let flattened = ModelPrompt.flattened(text, limit: probeLength).trimmingCharacters(in: .whitespaces)
        guard flattened.count >= minimumProbe else { return [] }
        let written = String(text.prefix(probeLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = written == flattened || written.isEmpty ? [flattened] : [flattened, written]
        let windows = runs(of: ModelPrompt.flattened(text, limit: text.count)) + runs(of: text)
        var seen = Set(opening)
        return opening + windows.filter { seen.insert($0).inserted }
    }

    /// `text` cut into runs of `probeLength` characters, end to end, each trimmed, and none under `minimumProbe`. A
    /// prompt cuts a sense at 240 or 400 characters, so a run past the cut is simply not found — and every run before it
    /// is in the prompt as written here.
    private static func runs(of text: String) -> [String] {
        var runs: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: probeLength, limitedBy: text.endIndex) ?? text.endIndex
            let run = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if run.count >= minimumProbe { runs.append(run) }
            start = end
        }
        return runs
    }

    /// The reader's own words — their sentence and the word they looked up — as written and flattened onto one line,
    /// the two ways a prompt carries them.
    private static func readersWords(_ words: [String]) -> [String] {
        words.flatMap { [$0, ModelPrompt.flattened($0, limit: $0.count)] }.filter { !$0.isEmpty }
    }

    /// How much of a publisher's text is looked for: long enough that it is the publisher's and nobody else's, short
    /// enough to be a prefix of every cut a prompt makes (`ModelPrompt.senseCharacterLimit` is the shortest, 240).
    static let probeLength = 32
    /// Below this a text is not looked for — see `leaks(_:of:)`.
    static let minimumProbe = 8

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
    /// Loopback is `localhost`, a name under `.localhost`, an IPv4 address in 127.0.0.0/8 and `::1`, each as
    /// `EndpointHost` reads it. Everything else is remote — a private LAN address or a `.local` name is another
    /// machine, which plain HTTP may reach (`EndpointAddress`) but which is sent the reader's sentence only — and so is
    /// everything `EndpointHost` cannot read without interpreting: a userinfo, a percent-encoded or non-ASCII host, an
    /// address written the way only `inet_aton` reads it, a mapped or zoned IPv6 address, a trailing dot, an impossible
    /// port.
    ///
    /// `*.localhost` is loopback because the system resolver answers it so without asking DNS — measured on macOS 27,
    /// `dscacheutil -q host -a name xiaolaidict-probe.localhost` answered `::1` and `127.0.0.1` (2026-10-09) — as
    /// RFC 6761 §6.3 asks of a resolver.
    public static func tier(ofEndpoint endpoint: String) -> ProviderTier {
        EndpointHost(endpoint: endpoint).map(isLoopback) == true ? .onThisMac : .remote
    }

    /// 127.0.0.0/8, `::1` in any spelling of its eight groups, and `localhost` or any name under it.
    private static func isLoopback(_ host: EndpointHost) -> Bool {
        switch host {
        case .ipv4(let first, _, _, _): first == 127
        case .ipv6(let groups): groups == [0, 0, 0, 0, 0, 0, 0, 1]
        case .name(let labels): labels.last == "localhost"
        }
    }
}
