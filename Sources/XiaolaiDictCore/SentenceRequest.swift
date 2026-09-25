import Foundation

/// What the app asks the model about a sentence, and who is allowed to see what.
///
/// **Split out of `SentencePane.swift` because these two cross the XPC boundary and the rest does
/// not.** `SentenceQuestion` is decoded by the model service; `ExplainerTier` is the licence rule
/// that decides what may be put in it. The explainers that consume the answer — the ladder, the
/// on-device rung — stay with the app, because choosing between engines is the app's job and the
/// service runs whichever one it was built for.
///
/// The tier travels *with* the question rather than being applied at each call site: the dropping
/// happens once, in `SentenceQuestion.prompt(for:)`, and that is the invariant this file exists to
/// keep reachable from the service side.

/// Who is allowed to see what, when XiaolaiDict explains a sentence.
///
/// **This is a licensing boundary, not a performance one.** The dictionaries are licensed to the
/// reader, not to XiaolaiDict: extracted definitions, examples or translations must never be shipped,
/// published, **or sent to a remote service** (`dev-docs/dictionary-markup.md` §8). So the tiers
/// are not interchangeable, and the difference is legal rather than technical.
public enum ExplainerTier: String, Sendable, CaseIterable {
    /// Runs on this Mac. May see the sentence **and** the dictionary entry.
    case onDevice
    /// A frontier API, opt-in. May see **the reader's own sentence only** — never a definition, an
    /// example or a translation. That kills "explain this definition" over the network and keeps
    /// "parse this sentence", and it simplifies consent: the remote tier sends text the reader was
    /// already reading.
    case remote

    public var maySeeDictionaryText: Bool { self == .onDevice }
}

/// What XiaolaiDict is asking about a sentence.
///
/// The dictionary text is *optional here and dropped at the boundary* rather than being trusted not
/// to be sent: `prompt(for:)` cannot include it for the remote tier, so a caller who assembles the
/// wrong thing gets a prompt without it rather than a licence breach.
/// `Codable` because it crosses XPC to the model service — the same boundary the dictionary
/// questions cross, and the reason the tier's dropping happens in `prompt(for:)` rather than at
/// each call site.
public struct SentenceQuestion: Codable, Sendable, Equatable {
    /// The reader's own sentence. Theirs, not the publisher's — always sendable.
    public let sentence: String
    /// The word they looked up.
    public let term: String
    /// The sense's definition, where one is known. **Publisher's text.**
    public let senseText: String?

    public init(sentence: String, term: String, senseText: String? = nil) {
        self.sentence = sentence
        self.term = term
        self.senseText = senseText
    }

    /// The prompt for `tier`, with anything that tier may not see removed **here**, once, rather
    /// than at each call site — and with every untrusted field flattened and cut here for the same
    /// reason.
    ///
    /// **The bounding moved into this method because one rung was built without it.** It used to
    /// live in `ModelPrompt.explanation`, which the local rung calls and Apple's rung does not:
    /// `OnDeviceSentenceExplainer` asks this method directly, so the reader's captured sentence and
    /// the publisher's sense text reached Apple's model raw and unbounded — on exactly the Mac
    /// where Apple's rung answers, which is any Mac without the downloaded model. A rule that has
    /// to be remembered at each call site is a rule one call site will be written without. Here,
    /// there is nowhere to build a prompt that skips it.
    public func prompt(for tier: ExplainerTier) -> String {
        var lines = [
            "Sentence: \(ModelPrompt.flattened(sentence, limit: ModelPrompt.sentenceCharacterLimit))",
            "Word: \(term)",
        ]
        if tier.maySeeDictionaryText, let senseText, !senseText.isEmpty {
            lines.append("Dictionary sense: \(ModelPrompt.flattened(senseText, limit: ModelPrompt.translatedSenseLimit))")
        }
        lines.append("Explain how the word is being used in this sentence, in two or three sentences.")
        return lines.joined(separator: "\n")
    }

    /// Whether `text` could carry publisher's text to a remote service.
    ///
    /// **Nothing sends remotely yet, so nothing calls this yet** — `.remote` is milestone 3's
    /// frontier pane and no explainer claims that tier. The doc here used to say it was "cheap
    /// enough to assert on every remote send", which read as a description of something happening
    /// and was a plan. It stays because the tier it guards is a licence boundary rather than a
    /// preference, and the assertion belongs at the send itself: whatever first builds a request for
    /// `.remote` asserts this over the bytes it is about to put on the wire, not over the prompt it
    /// meant to build.
    public func leaksDictionaryText(_ text: String) -> Bool {
        guard let senseText, !senseText.isEmpty else { return false }
        return text.contains(senseText)
    }
}
