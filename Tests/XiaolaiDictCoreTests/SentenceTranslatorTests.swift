import XiaolaiDictTestSupport
import Testing
import XiaolaiDictCore

/// The translation pane's engine order: the local model where it is, Apple's framework where it is
/// not, and never an answer that does not say which engine gave it.
struct SentenceTranslatorTests {
    /// **An echo of a quoted sentence is still an echo.** The reader's captured sentence can carry
    /// its own quotation marks — dialogue in a novel is the ordinary case — and unwrapping only the
    /// answer made the two normalise differently, so the check that exists to catch an echo passed it.
    @Test func aQuotedSentenceHandedBackIsNotATranslation() {
        let quoted = "“The ship's hold was full.”"
        #expect(!TranslationCheck.isTranslation(quoted, of: quoted))
        #expect(!TranslationCheck.isTranslation("The ship's hold was full.", of: quoted))
        #expect(!TranslationCheck.isTranslation(quoted, of: "The ship's hold was full."))
        #expect(TranslationCheck.isTranslation("这艘船的货舱装满了。", of: quoted))
    }

    private static let question = TranslationQuestion(
        sentence: "The ship's hold was full.", target: "zh-Hans",
        met: .init(term: "hold", sense: "the cargo space of a ship"))

    private static func translator(
        local: ModelReply?, apple: AppleTranslationResult, appleAsked: Recorder<Int> = Recorder(0),
        localAsked: Recorder<[TranslationQuestion]> = Recorder([])
    ) -> SentenceTranslator {
        SentenceTranslator(
            local: { question in localAsked.withLock { $0.append(question) }; return local },
            apple: { _, _, _ in appleAsked.withLock { $0 += 1 }; return apple },
            language: { _ in "en" })
    }

    /// The model answered: its translation, labelled as its own, and Apple is never asked.
    @Test func theLocalModelAnswersFirst() async {
        let appleAsked = Recorder(0)
        let outcome = await Self.translator(
            local: .translation("这艘船的货舱装满了。"), apple: .translated("船的船满了。"), appleAsked: appleAsked
        ).translate(Self.question)
        #expect(outcome == .translated("这艘船的货舱装满了。", by: .localModel))
        #expect(appleAsked.withLock { $0 } == 0)
    }

    /// The question the model gets carries the chosen sense — the pane is fed it, not run apart.
    @Test func theChosenSenseGoesToTheModel() async {
        let asked = Recorder<[TranslationQuestion]>([])
        _ = await Self.translator(local: .translation("货舱"), apple: .failed, localAsked: asked)
            .translate(Self.question)
        #expect(asked.withLock { $0.first?.met?.sense } == "the cargo space of a ship")
    }

    /// Without the model — not downloaded, too little memory, no service — Apple's framework
    /// answers, **and the answer says so**, which is what lets the pane label it the weaker engine.
    @Test(arguments: [
        ModelReply?.none, .failure(.notInstalled), .failure(.insufficientMemory(needed: 2, available: 1)),
        .failure(.generationFailed("echo")),
    ])
    func withoutTheModelAppleAnswersAndIsNamed(local: ModelReply?) async {
        let outcome = await Self.translator(local: local, apple: .translated("船的船满了。")).translate(Self.question)
        #expect(outcome == .translated("船的船满了。", by: .appleTranslation))
    }

    /// `.supported` is Apple's catalogue, not this Mac: a pair without its pack says so.
    @Test func aMissingLanguagePackIsSaid() async {
        let outcome = await Self.translator(local: nil, apple: .notInstalled).translate(Self.question)
        #expect(outcome == .needsLanguagePack(source: "en", target: "zh-Hans"))
    }

    /// An echo from either engine is not a translation.
    @Test func anEchoFromEitherEngineIsNotATranslation() async {
        let outcome = await Self.translator(
            local: .translation("The ship's hold was full."), apple: .translated("the ship's HOLD was full.")
        ).translate(Self.question)
        #expect(outcome == .unavailable)
    }

    /// Nothing to translate into the reader's own language, and neither engine is woken for it.
    @Test func aSentenceAlreadyInTheReadersLanguageIsNotTranslated() async {
        let appleAsked = Recorder(0)
        let localAsked = Recorder<[TranslationQuestion]>([])
        let translator = SentenceTranslator(
            local: { question in localAsked.withLock { $0.append(question) }; return .translation("x") },
            apple: { _, _, _ in appleAsked.withLock { $0 += 1 }; return .translated("x") },
            language: { _ in "zh-Hans" })
        #expect(await translator.translate(Self.question) == .sameLanguage)
        #expect(appleAsked.withLock { $0 } == 0 && localAsked.withLock { $0.isEmpty })
    }

    /// Simplified and Traditional are two languages to a reader; English and British English are one.
    @Test func scriptsSeparateLanguagesAndRegionsDoNot() async {
        let translate = { (source: String, target: String) async -> TranslationOutcome in
            await SentenceTranslator(local: { _ in .translation("译文") }, apple: { _, _, _ in .failed },
                                     language: { _ in source })
                .translate(TranslationQuestion(sentence: "text", target: target))
        }
        #expect(await translate("zh-Hant", "zh-Hans") == .translated("译文", by: .localModel))
        #expect(await translate("en", "en-GB") == .sameLanguage)
        // A tag with no script is filled in the way the system would: `zh` is Simplified, so a
        // reader of Traditional is not told their sentence is already in their language.
        #expect(await translate("zh", "zh-Hant") == .translated("译文", by: .localModel))
        #expect(await translate("zh", "zh-Hans") == .sameLanguage)
    }

    /// **An answer still in the sentence's own language is not a translation**, however unlike the
    /// input it reads — a model that paraphrases instead of translating, or hands the English back
    /// in other words, has not answered. Nor is the sentence in quotation marks.
    @Test func ananswerInTheSourceLanguageIsNotATranslation() {
        let english = "The ship's hold was full of grain and the rats had got at the biscuit."
        #expect(!TranslationCheck.isTranslation(
            "The cargo compartment of the vessel was filled with grain.", of: english, into: "zh-Hans"))
        #expect(TranslationCheck.isTranslation("这艘船的货舱装满了谷物。", of: english, into: "zh-Hans"))
        #expect(!TranslationCheck.isTranslation("“\(english)”", of: english, into: "zh-Hans"))
        // Without a target named, only the echo itself can be caught.
        #expect(TranslationCheck.isTranslation("A paraphrase of the same sentence in English.", of: english))
    }

    /// A reader who has moved on is shown nothing, and no second engine is woken for them.
    @Test func aCancelledTranslationAnswersNothing() async {
        let appleAsked = Recorder(0)
        let translator = SentenceTranslator(
            local: { _ in .failure(.notInstalled) },
            apple: { _, _, _ in appleAsked.withLock { $0 += 1 }; return .translated("船舱") },
            language: { _ in "en" })
        let task = Task {
            await withTaskCancellationHandler {
                await translator.translate(Self.question)
            } onCancel: {}
        }
        task.cancel()
        #expect(await task.value == .unavailable)
        #expect(appleAsked.withLock { $0 } == 0, "a cancelled lookup woke the fallback engine")
    }

    @Test(arguments: [("船舱装满了。", "The ship's hold was full.", true),
                      ("", "The ship's hold was full.", false),
                      ("  the SHIP'S hold   was full. ", "The ship's hold was full.", false)])
    func theEchoCheck(output: String, source: String, isTranslation: Bool) {
        #expect(TranslationCheck.isTranslation(output, of: source) == isTranslation)
    }
}
