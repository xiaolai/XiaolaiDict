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
        await SenseCandidates.asking(
            candidates, matching: matchesPartOfSpeech ? partOfSpeech : nil, reading: sentence,
            context: context
        ) { keyable, reading in
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
                // **Temperature 0, like rung 1.** Picking a sense is a choice from a numbered list,
                // not writing; sampling only lets one sentence be answered two ways. Left at the
                // backend's default, this rung was the one half of a pair the invariant claims is
                // deterministic — and the ladder's order is measured by comparing the two.
                let answer = try await session.respond(
                    to: ModelPrompt.sense(question), generating: SenseNumber.self,
                    options: GenerationOptions(temperature: 0))
                // Mechanically checked against the list it was given. Anything else is an abstention,
                // never a nearest match — and **which** abstention is the same question rung 1 answers,
                // so the two are not scored on different fields. 0 is the instructions' own answer for
                // "the sentence does not settle it"; any other number names no sense in the list, which
                // is not a decision at all and must not stop the ladder.
                let number = answer.content.senseNumber
                if number == 0 { return .abstained(.undecided) }
                guard number >= 1, number <= keyable.count else { return .abstained(.unavailable) }
                return .chose(
                    key: keyable[number - 1].key, margin: nil, entryID: keyable[number - 1].entryID)
            } catch let error as LanguageModelError {
                // None of these is a reason to pick something, so every arm abstains and the ladder
                // goes on to the rung below. What differs is what the ledger is told, and whether the
                // failure is this build's fault.
                //
                // **The refusal is asked of `ModelRefusal` and nowhere else.** Matching
                // `.refusal, .guardrailViolation` here as well put a second spelling of that rule in
                // this file, and inside it `isRefusal` was true by construction — so its
                // `.unavailable` arm could not be taken, and the two spellings could drift with
                // nothing failing.
                if ModelRefusal.isRefusal(error) {
                    // The model declining *this sentence* — a fact about the reader's text, kept apart
                    // from the model being absent.
                    return .abstained(.refused)
                }
                switch error {
                case .unsupportedGenerationGuide, .unsupportedTranscriptContent, .unsupportedCapability:
                    // The schema and the instructions are compiled into this binary, so this is a
                    // defect here rather than a fact about the reader's Mac. It traps in a debug build
                    // and still abstains in a shipped one: a reader must not lose their lookup over it.
                    // The trap is right here and wrong in the local rung, where the answer comes from a
                    // separately-built process that may be a different version of this app.
                    assertionFailure("this rung's own request was refused: \(error)")
                    return .abstained(.unavailable)
                case .contextSizeExceeded:
                    // The list outgrew the window. Deliberately not narrowed to fit: dropping
                    // candidates to make room is how the sense the reader actually met gets dropped,
                    // and a confidently-wrong answer is worse than falling to a rung that can hold the
                    // whole list. `NLEmbedding` holds it.
                    return .abstained(.unavailable)
                default:
                    return .abstained(.unavailable)
                }
            } catch {
                // Not the model's own error type at all — a cancellation, or something the framework
                // wrapped. Nothing to distinguish, and nothing to pick.
                return .abstained(.unavailable)
            }
        }
    }
}
