import Foundation
@testable import ModelKit
import Testing

/// **What may leave the Mac is one value, and where an endpoint is decides it** (ADR-0053, plan §3).
///
/// The tier is a licence boundary: an endpoint called "on this Mac" may be sent the dictionary's text. So every case
/// that is not loopback beyond doubt is remote — misreading a loopback server as remote costs answer quality, and
/// misreading a remote one as loopback sends a publisher's text off the Mac. Each refusal below has a positive control
/// beside it: the same shape, made loopback, is on this Mac, so the refusal is the host and not the parser failing.
struct RemoteDisclosureTests {
    /// The owner has not said the dictionary's text may leave (ADR-0053). Flipping this is the whole change.
    @Test func theDictionarysTextMayNotLeave() {
        #expect(RemoteDisclosure.dictionaryTextMayLeave == false)
        #expect(RemoteDisclosure.mayCarryDictionaryText(.onThisMac))
        #expect(!RemoteDisclosure.mayCarryDictionaryText(.remote))
    }

    /// **The flip is a constant**: with it set, the remote tier may carry the text too, and nothing else changes.
    @Test func theFlipIsTheOnlyThingBetweenTheRemoteTierAndTheText() {
        #expect(RemoteDisclosure.mayCarryDictionaryText(.remote, dictionaryTextMayLeave: true))
        #expect(!RemoteDisclosure.mayCarryDictionaryText(.remote, dictionaryTextMayLeave: false))
        #expect(RemoteDisclosure.mayCarryDictionaryText(.onThisMac, dictionaryTextMayLeave: false))
    }

    /// Loopback, in every spelling the system resolver answers with loopback and nothing else. `*.localhost` is here
    /// because macOS 27's resolver answers it with `::1` and `127.0.0.1` without asking DNS (measured 2026-10-09,
    /// `dscacheutil -q host -a name xiaolaidict-probe.localhost`), as RFC 6761 §6.3 asks.
    @Test(arguments: [
        "http://localhost:11434/v1", "https://localhost/v1", "http://LOCALHOST:1234", "http://localhost",
        "http://ollama.localhost:11434/v1", "http://a.b.localhost/v1",
        "http://127.0.0.1:8080/v1", "http://127.1.2.3/v1", "http://127.255.255.255", "http://127.0.0.0",
        "http://[::1]:8080/v1", "http://[0:0:0:0:0:0:0:1]/v1", "http://[0000::0001]/v1", "HTTP://127.0.0.1/v1",
    ])
    func loopbackIsOnThisMac(endpoint: String) {
        #expect(RemoteDisclosure.tier(ofEndpoint: endpoint) == .onThisMac, "\(endpoint)")
    }

    /// Every other host — a hosted API, a machine on the reader's own network, a `.local` name — is remote. **Plain HTTP
    /// to the local network being allowed (`EndpointAddress`, the owner's decision of 2026-10-09) changes nothing here**:
    /// every block that decision admits is another machine, and is listed.
    @Test(arguments: [
        "https://api.openai.com/v1", "https://api.deepseek.com/v1",
        "https://generativelanguage.googleapis.com/v1beta/openai",
        "http://192.168.1.20:11434/v1", "http://10.0.0.5/v1", "http://172.16.0.1/v1", "http://169.254.1.1/v1",
        "http://172.31.255.255/v1", "http://100.64.0.1/v1", "http://100.127.255.255/v1", "http://[fd00::1]/v1",
        "http://another-mac.local:1234/v1", "http://lab.studio.local/v1", "http://[fe80::1]/v1", "http://[::2]/v1",
        "http://[::]/v1", "http://0.0.0.0:8080/v1", "http://128.0.0.1/v1", "http://126.0.0.1/v1",
    ])
    func everyOtherHostIsRemote(endpoint: String) {
        #expect(RemoteDisclosure.tier(ofEndpoint: endpoint) == .remote, "\(endpoint)")
    }

    /// **Host tricks are remote.** A name that merely starts with a loopback spelling, userinfo that reads like a
    /// host, a host spelled in a form an address parser and a URL parser read differently — each is a place where
    /// "the URL says localhost" and "the connection goes to localhost" can part. Refused, never interpreted.
    @Test(arguments: [
        // A loopback spelling as the first label of someone else's name.
        "http://localhost.evil.com/v1", "http://127.0.0.1.evil.com/v1", "http://localhost.evil.com.",
        // Userinfo: the host is after the @, and a URL with any userinfo at all is refused.
        "http://localhost@evil.com/v1", "http://localhost:11434@evil.com/v1", "http://user@localhost/v1",
        "http://user:pass@127.0.0.1/v1",
        // Address forms `inet_aton` reads as some address and a strict reader does not: octal (0177 is 127, but
        // 0127 is 87), short forms, hex and a bare integer.
        "http://0127.0.0.1/v1", "http://127.000.000.001/v1", "http://127.1/v1", "http://0x7f.0.0.1/v1",
        "http://2130706433/v1", "http://127.0.0.1.1/v1", "http://127.0.0.256/v1",
        // IPv6 that only maps or embeds a loopback, or carries a zone.
        "http://[::ffff:127.0.0.1]/v1", "http://[::127.0.0.1]/v1", "http://[::1%25lo0]/v1",
        // Percent-encoding, a trailing dot and a non-ASCII spelling (full-width letters map to ASCII under IDNA).
        "http://local%68ost/v1", "http://localhost./v1", "http://ｌｏｃａｌｈｏｓｔ/v1",
    ])
    func hostTricksAreRemote(endpoint: String) {
        #expect(RemoteDisclosure.tier(ofEndpoint: endpoint) == .remote, "\(endpoint)")
    }

    /// Anything that is not an http(s) URL with a host is remote: nothing about it says the text stays here.
    @Test(arguments: [
        "", " ", "localhost:11434/v1", "127.0.0.1", "ftp://127.0.0.1/v1", "file:///tmp/socket", "ws://localhost/v1",
        "http://", "http:///v1", "http://[::1/v1", "not a url at all", "http://localhost:99999/v1",
    ])
    func whatIsNotAnHTTPURLWithAHostIsRemote(endpoint: String) {
        #expect(RemoteDisclosure.tier(ofEndpoint: endpoint) == .remote, "\(endpoint)")
    }

    /// **The positive controls for the refusals above, one each**: the same shape with the trick taken out is
    /// on this Mac — so a refusal is the trick, not a parser that refuses everything.
    @Test func eachRefusedShapeIsOnThisMacWithoutItsTrick() {
        for endpoint in ["http://localhost/v1", "http://127.0.0.1/v1", "http://localhost:11434/v1",
                         "http://[::1]/v1", "http://127.0.0.1:8080/v1", "https://localhost/v1"] {
            #expect(RemoteDisclosure.tier(ofEndpoint: endpoint) == .onThisMac, "\(endpoint)")
        }
    }

    /// **Both CLIs are remote whatever the endpoint says**, the bundled model is on this Mac, an endpoint is what
    /// its URL is, and no source chosen is no tier at all — nothing is asked.
    @Test func theTierOfEachChoice() {
        for endpoint in ["http://localhost:11434/v1", "https://api.openai.com/v1"] {
            #expect(RemoteDisclosure.tier(of: .claudeCLI, endpoint: endpoint) == .remote)
            #expect(RemoteDisclosure.tier(of: .codexCLI, endpoint: endpoint) == .remote)
            #expect(RemoteDisclosure.tier(of: .localModel, endpoint: endpoint) == .onThisMac)
            #expect(RemoteDisclosure.tier(of: .none, endpoint: endpoint) == nil)
        }
        #expect(RemoteDisclosure.tier(of: .openAICompatible, endpoint: "http://localhost:11434/v1") == .onThisMac)
        #expect(RemoteDisclosure.tier(of: .openAICompatible, endpoint: "https://api.openai.com/v1") == .remote)
        #expect(RemoteDisclosure.tier(of: .openAICompatible, endpoint: "http://localhost.evil.com/v1") == .remote)
    }

    // MARK: - The send-time check: the publisher's text, in every form a prompt carries it

    static let sentence = "She banked the fire before going to bed."
    static let sense = "heap (a fire) with tightly packed fuel so that it burns slowly, through the long night"

    /// **Each prompt a tier may carry the text in is caught, and each it may not is clear** — the explanation, the
    /// translation and the sense list, each built by the builder the providers' client sends.
    @Test func everyPromptCarryingTheTextIsCaughtAndNoneWithoutIt() {
        let explained = SentenceQuestion(sentence: Self.sentence, term: "banked", senseText: Self.sense)
        #expect(RemoteDisclosure.leaks(explained.prompt(for: .onDevice), of: .explain(explained)))
        #expect(!RemoteDisclosure.leaks(explained.prompt(for: .remote), of: .explain(explained)))

        let told = TranslationQuestion(sentence: Self.sentence, target: "zh-Hans", met: .init(term: "banked", sense: Self.sense))
        let untold = TranslationQuestion(sentence: Self.sentence, target: "zh-Hans")
        #expect(RemoteDisclosure.leaks(ModelPrompt.translation(told), of: .translate(told)))
        #expect(!RemoteDisclosure.leaks(ModelPrompt.translation(untold), of: .translate(told)))

        let listed = SenseQuestion(sentence: Self.sentence, partOfSpeech: nil,
                                   senses: ["deposit (money or valuables) in a bank", Self.sense])
        #expect(RemoteDisclosure.leaks(ModelPrompt.sense(listed), of: .pickSense(listed)))
        #expect(!RemoteDisclosure.leaks("Sentence: \(Self.sentence)\nWhich number?", of: .pickSense(listed)))
    }

    /// **A cut, a flattened or a raw sense is caught alike**: a prompt cuts a long sense at 240 or 400 characters and
    /// flattens it onto one line, so a whole-text search would miss exactly what a prompt sends.
    @Test func aSenseIsCaughtCutFlattenedOrRaw() {
        let long = String(repeating: "a definition that runs on and on, ", count: 30)
        let question = SentenceQuestion(sentence: Self.sentence, term: "banked", senseText: "line one\nline two " + long)
        #expect(RemoteDisclosure.leaks("…\(ModelPrompt.flattened(question.senseText ?? "", limit: 240))…", of: .explain(question)))
        #expect(RemoteDisclosure.leaks("…\(question.senseText ?? "")…", of: .explain(question)), "the raw text was missed")
        #expect(RemoteDisclosure.leaks("Dictionary sense: line one line two a definition that runs", of: .explain(question)))
        #expect(!RemoteDisclosure.leaks("Dictionary sense: line one", of: .explain(question)),
                "a fragment shorter than the probe was read as the sense")
    }

    /// **A sense whose opening the reader's sentence happens to hold is still looked for in the rest of it.** Only its
    /// first 32 characters were probed, and a probe the reader's words hold is dropped — so a sentence quoting the start
    /// of a definition exempted the whole definition, and sending all of it was not caught.
    @Test func aSenseWhoseOpeningTheSentenceQuotesIsStillLookedForInTheRest() {
        let sense = "a sum of money exacted as a penalty by a court of law or other authority for breaking a rule"
        let sentence = "The notice said \"a sum of money exacted as a penalty\" and nothing more."
        let question = SentenceQuestion(sentence: sentence, term: "fine", senseText: sense)
        #expect(RemoteDisclosure.leaks("Sentence: \(sentence)\nWord: fine\nDictionary sense: \(sense)", of: .explain(question)),
                "the rest of the definition went out unnoticed")
        // The control: the reader's sentence alone carries nothing of the publisher's but what it quotes.
        #expect(!RemoteDisclosure.leaks(question.prompt(for: .remote), of: .explain(question)))
    }

    /// **The reader's own words are not the publisher's**: a one-word sense that is the word they looked up, and a gloss
    /// that is part of their own sentence, are not a leak. The control: the same text, when the reader's words do not
    /// hold it, is.
    @Test func theReadersOwnWordsAreNotALeak() {
        let word = SentenceQuestion(sentence: "He sat on the river bank.", term: "riverbank", senseText: "riverbank")
        #expect(!RemoteDisclosure.leaks(word.prompt(for: .remote), of: .explain(word)))
        let other = SentenceQuestion(sentence: "He sat on the shore.", term: "shore", senseText: "riverbank")
        #expect(RemoteDisclosure.leaks("Word: shore\nDictionary sense: riverbank", of: .explain(other)))

        let quoted = SentenceQuestion(sentence: "The court imposed a sum of money as a penalty on him.", term: "fine",
                                      senseText: "a sum of money as a penalty")
        #expect(!RemoteDisclosure.leaks(quoted.prompt(for: .remote), of: .explain(quoted)))
        let unquoted = SentenceQuestion(sentence: "He paid it.", term: "fine", senseText: "a sum of money as a penalty")
        #expect(RemoteDisclosure.leaks("Sentence: He paid it.\nDictionary sense: a sum of money as a penalty",
                                       of: .explain(unquoted)))
    }

    /// A text shorter than the minimum is not looked for — it cannot be told from an ordinary word — and a request
    /// that holds no publisher's text never leaks.
    @Test func whatHoldsNoPublishersTextNeverLeaks() {
        let short = SentenceQuestion(sentence: "A ship.", term: "ship", senseText: "a boat")
        #expect(!RemoteDisclosure.leaks("Explain a boat in a sentence about a boat.", of: .explain(short)))
        #expect(!RemoteDisclosure.leaks("anything at all", of: .prewarm))
        #expect(!RemoteDisclosure.leaks("anything", of: .explain(SentenceQuestion(sentence: "A.", term: "a"))))
    }
}
