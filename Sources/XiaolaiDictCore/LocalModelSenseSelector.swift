/// The top rung: Qwen, in the model service, guided to the candidate set.
///
/// The same closed-set question the on-device rung asks, with the same instructions, prompt,
/// narrowing and generation options — so the two are scored on one field and differ in nothing but
/// the model. The model
/// answers with a position in the list it was given, and the answer is checked against that list
/// **here**, mechanically: a small model that answers "10" of eight senses (Qwen3.5-2B did, once)
/// gets an abstention, never a nearest match.
///
/// What falls through and what does not is the ladder's whole contract. "Not downloaded", "does not
/// fit in memory right now" and "the service could not be reached" are `.unavailable` — the model is
/// not here, and the next rung runs. A refusal is `.refused`: the model *was* here and declined this
/// sentence, which the ledger keeps apart.
public struct LocalModelSenseSelector: SenseSelecting {
    /// One round trip to the model service. **Nil is "no usable reply"** — not only a service that
    /// could not be reached: a deadline, a caller that gave up, and a transport that failed all
    /// arrive here as nil, and the rung treats them alike because none of them is an answer.
    public typealias Ask = @Sendable (SenseQuestion) async -> ModelReply?

    private let ask: Ask
    private let matchesPartOfSpeech: Bool

    public init(matchesPartOfSpeech: Bool = true, ask: @escaping Ask) {
        self.ask = ask
        self.matchesPartOfSpeech = matchesPartOfSpeech
    }

    public func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        let considered: [SenseCandidate], reading: String
        switch SenseCandidates.preflight(
            candidates, matching: matchesPartOfSpeech ? partOfSpeech : nil, reading: sentence,
            context: context
        ) {
        case .settled(let answer): return answer
        case .ask(let asking, let sentence): (considered, reading) = (asking, sentence)
        }

        // **Asked only for a list the answer can name.** The service refuses a longer one as an
        // invalid request — a defect in whatever built it — and an entry with a hundred senses is
        // not a defect, it is *run* in a large dictionary. The rung below has no such bound.
        guard considered.count <= ModelPrompt.maximumSenses else { return .abstained(.unavailable) }
        // **Cut before it crosses the process boundary.** The prompt keeps only
        // `senseCharacterLimit` characters of each sense, so sending whole bodies — up to 99 of
        // them, and a single COBUILD sense runs to hundreds of characters — serialises kilobytes
        // that are then thrown away on the other side.
        let question = SenseQuestion(
            sentence: reading, partOfSpeech: partOfSpeech,
            senses: considered.map { String($0.text.prefix(ModelPrompt.senseCharacterLimit)) })
        switch await ask(question) {
        case .sense(0)?:
            // The answer its instructions call correct and expected: the sentence does not settle
            // which sense this is. **Not `.tooClose`** — 0 is offered for "no sense clearly fits"
            // and for "two or more fit equally well" in the same breath, so it cannot support the
            // claim that several fit.
            return .abstained(.undecided)
        case .sense(let number)?:
            // **A number that names no sense in the list is not a decision**, and must not stop the
            // ladder: 2B answered "10" of eight senses once. The rung could not run, so the next one does.
            guard number >= 1, number <= considered.count else { return .abstained(.unavailable) }
            let chosen = considered[number - 1]
            // **No margin**: a model answers with a position in a list, not a score, so there is
            // no gap over a runner-up to report and a number here would be one this rung made up —
            // which the accuracy report would then read as confidence.
            return .chose(key: chosen.key, margin: nil, entryID: chosen.entryID)
        case .failure(.refused)?:
            return .abstained(.refused)
        // **A request this rung built and the service refused is a defect here** — the bounds are
        // checked above, so reaching this means the two sides disagree about what a sense question
        // is. It is *not* trapped on: the service is a separate process that can be a different
        // build of this app entirely, and killing the reader's app over a version skew is a worse
        // answer than falling to the rung below. The reader gets a sense; the disagreement shows up
        // as this rung never answering, which `--sense-report` measures.
        case .failure(.invalidRequest)?:
            return .abstained(.unavailable)
        // Not installed, too little memory now, a generation that failed, an answer of the wrong
        // shape, or no service at all: the model is not here **for this lookup**, and the rung
        // below runs. These are not all the same thing — a corrupt installation and a busy Mac end
        // up here alike — and what tells them apart is `--model-status`, which asks the service
        // directly rather than inferring from a rung that fell through.
        case .failure?, .translation?, .explanation?, .prewarmed?, .status?, .unloading?, nil:
            return .abstained(.unavailable)
        }
    }
}
