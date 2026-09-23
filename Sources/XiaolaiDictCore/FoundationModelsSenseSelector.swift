import FoundationModels
import Foundation

/// Rung 2: Apple's on-device model, guided to the candidate set — below the local model, which is
/// the top rung wherever it is downloaded, and above `NLEmbedding`.
///
/// The model is never asked to *write* anything — it is asked which of a numbered list of senses
/// fits, and answers with a number. An answer outside the list is rejected mechanically, so the
/// worst failure is a wrong existing sense and never an invented one.
///
/// Two things the platform forces, both of which become abstentions:
///
/// - **Availability.** Apple Intelligence is off, unsupported, or still downloading on plenty of
///   Macs, and unavailable in mainland China, a core audience. Measured `deviceNotEligible` on the
///   development Mac and `available` on the E2E machine.
/// - **Guardrails.** The permissive guardrails apply to *string* responses; guided structured
///   generation keeps the default ones, so a refusal is possible — measured on a crime-news
///   sentence under both settings. A refusal maps to `.refused`, **never to a pick of this rung's
///   own** — a selector that answers anyway when the model declined is a selector that is guessing.
public struct FoundationModelsSenseSelector: SenseSelecting {
    private let matchesPartOfSpeech: Bool

    /// `matchesPartOfSpeech` is the same structural narrowing rung 1 gets. It is applied to every
    /// rung so that no rung is scored against another on a different field.
    public init(matchesPartOfSpeech: Bool = true) {
        self.matchesPartOfSpeech = matchesPartOfSpeech
    }

    public func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        let keyable: [SenseCandidate], reading: String
        switch SenseCandidates.preflight(
            candidates, matching: matchesPartOfSpeech ? partOfSpeech : nil, reading: sentence,
            context: context
        ) {
        case .settled(let answer): return answer
        case .ask(let asking, let sentence): (keyable, reading) = (asking, sentence)
        }

        // Asked through `SenseEngine`, not here. This site used to match `.available` itself and
        // drop the `.unavailable(reason)` payload, so nothing could say *why* a reader was on the
        // fallback rung — while `OnDeviceSentenceExplainer` kept the reason and rendered it. One
        // question, one place, and the setup board now reads the same answer this does.
        guard SenseEngine.status().isOnDevice else { return .abstained(.unavailable) }
        do {
            // **The same question the local model is asked**, from the one place it is written: two
            // rungs compared on differently worded prompts would be measured on different fields.
            // The same bound rung 1 keeps, for the same reason: the answer's schema cannot name a
            // position past it, so a longer list would have its tail made unreachable rather than
            // being refused. Two rungs measured on one field have to ask one question.
            guard keyable.count <= ModelPrompt.maximumSenses else { return .abstained(.unavailable) }
            let question = SenseQuestion(
                sentence: reading, partOfSpeech: partOfSpeech, senses: keyable.map(\.text))
            let session = LanguageModelSession(instructions: ModelPrompt.senseInstructions)
            let answer = try await session.respond(
                to: ModelPrompt.sense(question), generating: SenseAnswer.self)
            // Mechanically checked against the list it was given. Anything else is an abstention,
            // never a nearest match — and **which** abstention is the same question rung 1 answers,
            // so the two are not scored on different fields. 0 is the instructions' own answer for
            // "the sentence does not settle it"; any other number names no sense in the list, which
            // is not a decision at all and must not stop the ladder.
            let number = answer.content.senseNumber
            if number == 0 { return .abstained(.undecided) }
            guard number >= 1, number <= keyable.count else { return .abstained(.unavailable) }
            return .chose(
                key: keyable[number - 1].key, margin: 1, entryID: keyable[number - 1].entryID)
        } catch {
            // None of these is a reason to pick something. But a refusal is the model declining
            // *this sentence*, and is kept apart from a context overflow or the model going away.
            return .abstained(ModelRefusal.isRefusal(error) ? .refused : .unavailable)
        }
    }
}

/// **The same schema rung 1 answers with**, bound included: an unbounded one let Apple's model
/// return a number that names no sense, which the caller then had to reject — and the two rungs,
/// which the ladder's order is measured from, were being asked in two different grammars.
@Generable
struct SenseAnswer {
    @Guide(description: "The number of the sense the word carries in the sentence, or 0 if none clearly fits.",
           .range(0...ModelPrompt.maximumSenses))
    var senseNumber: Int
}
