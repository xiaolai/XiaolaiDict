#if canImport(FoundationModels)
import FoundationModels
#endif
import Foundation

/// Rung 2: Apple's on-device model, guided to the candidate set.
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
///   generation keeps the default ones, so a refusal is possible on adult reading material. A
///   refusal maps to **abstention, never to a fallback pick** — a selector that answers anyway when
///   the model declined is a selector that is guessing.
public struct FoundationModelsSenseSelector: SenseSelecting {
    /// Each sense is cut to this many characters in the prompt. The context window is enormous for
    /// this input; the cut is to keep one 49-sense entry from crowding out the sentence.
    static let senseCharacterLimit = 240

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
        let keyable = SenseCandidates.considered(
            candidates, matching: matchesPartOfSpeech ? partOfSpeech : nil)
        guard !keyable.isEmpty else { return .abstained(.noCandidates) }
        guard keyable.count > 1 else {
            return .chose(key: keyable[0].key, margin: .infinity, entryID: keyable[0].entryID)
        }
        guard context == .complete, let sentence,
              !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .abstained(.noContext) }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .abstained(.unavailable) }
        // Asked through `SenseEngine`, not here. This site used to match `.available` itself and
        // drop the `.unavailable(reason)` payload, so nothing could say *why* a reader was on the
        // fallback rung — while `OnDeviceSentenceExplainer` kept the reason and rendered it. One
        // question, one place, and the setup board now reads the same answer this does.
        guard SenseEngine.status().isOnDevice else { return .abstained(.unavailable) }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let answer = try await session.respond(
                to: Self.prompt(for: keyable, sentence: sentence, partOfSpeech: partOfSpeech),
                generating: SenseAnswer.self)
            // Mechanically checked against the list it was given. Anything else is an abstention,
            // never a nearest match.
            let number = answer.content.senseNumber
            guard number >= 1, number <= keyable.count else { return .abstained(.tooClose) }
            return .chose(
                key: keyable[number - 1].key, margin: 1, entryID: keyable[number - 1].entryID)
        } catch {
            // A refusal, a context overflow, or the model going away mid-answer. None of them is a
            // reason to pick something.
            return .abstained(.unavailable)
        }
        #else
        return .abstained(.unavailable)
        #endif
    }

    static let instructions = """
        You identify which dictionary sense of a word is being used in a sentence.
        You are given the word, the sentence it appears in, and a numbered list of that word's \
        senses from a dictionary.
        Answer with the number of the single sense that the word carries in that sentence.
        Answer 0 if no sense clearly fits, or if two or more fit equally well. Answering 0 is \
        correct and expected whenever the sentence does not settle the question.
        """

    static func prompt(for candidates: [SenseCandidate], sentence: String, partOfSpeech: String?) -> String {
        var lines = ["Sentence: \(sentence)"]
        if let partOfSpeech { lines.append("The word is used as a \(partOfSpeech).") }
        lines.append("Senses:")
        for (index, candidate) in candidates.enumerated() {
            lines.append("\(index + 1). \(candidate.text.prefix(senseCharacterLimit))")
        }
        lines.append("Which number?")
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct SenseAnswer {
    @Guide(description: "The number of the sense the word carries in the sentence, or 0 if none clearly fits.")
    var senseNumber: Int
}
#endif
