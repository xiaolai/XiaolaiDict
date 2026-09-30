import AVFoundation
import SwiftUI
@testable import XiaolaiDict
@testable import XiaolaiDictUI
import Testing

/// Stage 6, as Spike S1 left it: use the system's voices, take the best one installed, and say so
/// when the best one installed is only a compact voice.
@MainActor
struct SpeechTests {
    /// Voices cannot be constructed freely, so the ranking is tested against whatever this Mac has.
    private let installed = AVSpeechSynthesisVoice.speechVoices()

    @Test func itPrefersTheBestQualityInstalled() throws {
        let english = installed.filter { $0.language.hasPrefix("en") }
        try #require(!english.isEmpty, "this Mac has no English voice at all")
        let chosen = try #require(Speech.bestVoice(for: "en", among: installed))
        let best = english.map(\.quality.rawValue).max()
        #expect(chosen.quality.rawValue == best, "picked \(chosen.quality.rawValue), best installed is \(best ?? -1)")
    }

    /// A bare language code matches every region, so a reader with only en-GB still gets a voice.
    @Test func aBareCodeMatchesAnyRegion() throws {
        let chosen = try #require(Speech.bestVoice(for: "en", among: installed))
        #expect(chosen.language.hasPrefix("en"))
    }

    /// No voice is a fact to report, not a crash and not silence pretending to be speech.
    @Test func aLanguageWithNoVoiceIsReported() {
        #expect(Speech.bestVoice(for: "zz", among: installed) == nil)
        #expect(Speech.caveat(for: "zz", among: installed)?.isEmpty == false)
    }

    /// S1's finding, turned into something the reader is told: nothing is downloaded by default,
    /// and a reader who does not know better voices exist will conclude XiaolaiDict sounds bad.
    ///
    /// **Against a list filtered to compact, not against whatever this Mac happens to have.** The
    /// branch used to be exercised only on a machine with no good voice installed — so the moment
    /// Ava was downloaded here it started passing through the `nil` arm, and the wording assertion
    /// it exists for stopped running. A voice cannot be constructed, but a list can be narrowed.
    @Test func aCompactOnlyLanguageSaysWhatToGetAndWhereFrom() throws {
        let compactOnly = installed.filter { $0.quality == .default }
        try #require(!compactOnly.filter { $0.language.hasPrefix("en") }.isEmpty)
        let caveat = try #require(Speech.caveat(for: "en", among: compactOnly))
        #expect(caveat.contains("compact"), "a compact-only language said nothing about it")
        #expect(caveat.contains("Ava"), "it did not name the voice worth getting")
        #expect(caveat.contains("VoiceOver Utility"), "it did not say where voices are installed")
        #expect(!caveat.contains("System Settings"), """
            it still sends the reader to System Settings, which on macOS 27 has no voice list at all
            """)
    }

    /// **And it does not promise a download that does not exist.** No variety of Chinese is in the
    /// voice catalogue at any quality above compact, so telling a Chinese reader that better ones
    /// are a free download is an errand that ends nowhere — in their own language.
    @Test func alanguageWithNothingBetterIsToldThatPlainly() throws {
        let compactOnly = installed.filter { $0.quality == .default }
        try #require(!compactOnly.filter { $0.language.hasPrefix("zh") }.isEmpty,
                     "this Mac has no Chinese voice to test against")
        let caveat = try #require(Speech.caveat(for: "zh", among: compactOnly))
        #expect(caveat.contains("nothing better"), "got: \(caveat)")
        #expect(!caveat.contains("VoiceOver Utility"), "it offered a download that does not exist")
    }

    /// A good voice is never apologised for — the caveat exists to report a shortfall.
    ///
    /// **Skipped rather than required where there is no good voice.** A `#require` here would turn
    /// the suite red on every Mac that has downloaded nothing, which is the default state and is
    /// the end-to-end machine's state. The arm this misses is the negative of
    /// `aCompactOnlyLanguageSaysWhatToGetAndWhereFrom`, which runs everywhere.
    @Test func agoodVoiceIsNotApologisedFor() {
        let good = installed.filter { $0.quality != .default }
        guard let voice = good.first else { return }
        #expect(Speech.caveat(for: voice.language, among: good) == nil)
    }

    /// The recommendation is a claim about macOS, so it says which languages it is making one for.
    @Test func onlyLanguagesWithAMeasuredAnswerAreRecommended() {
        #expect(Speech.recommendation(for: "en-US") == "Ava")
        #expect(Speech.recommendation(for: "en") == "Ava")
        #expect(Speech.recommendation(for: "en-GB") == "Serena")
        #expect(Speech.recommendation(for: "zh-Hans") == nil)
        #expect(Speech.recommendation(for: "ja") == nil)
    }

    /// **The wire, not the value.** `Speech.caveat` was complete, memoised and tested while nothing
    /// in the card asked for it — the reader with only a compact voice was told nothing for as long
    /// as the card has existed. The check is on what reaches the button, because that is the part
    /// that was missing.
    ///
    /// The composition it used to read for — `caveat(forSpeaking:) ?? "Say it aloud"`, written out
    /// at the call site — is now `Speech.sayItAloudHelp(for:)`, because the drawer wrote the same
    /// thing out a second time and the two reached the translator differently. The wire is what
    /// still matters here; `theHelpIsTheCaveatWhereThereIsOne` covers what the helper composes.
    @Test func theSpeakButtonCarriesTheCaveatAboutTheVoice() throws {
        let card = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI/LookupCardView.swift")
        // Comment lines are dropped first: a scanner that cannot tell a declaration from an
        // explanation is satisfied by the call site written out inside a comment, which is exactly
        // how this rule would come to hold on paper and not in the view.
        let source = try String(contentsOf: card, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(source.contains("help: Speech.sayItAloudHelp(for: card.term, in: card.sentence)"),
                "the speak button says nothing about the voice it will use")
    }

    /// What the extracted helper composes, as opposed to who calls it. A caveat is a sentence
    /// `Speech` has already localized, so it arrives verbatim; with nothing worth saying the help
    /// is the plain key a translator gets. The two `Text`s are built differently on purpose, which
    /// is what lets this tell them apart.
    @Test func theHelpIsTheCaveatWhereThereIsOne() {
        let sentence = "They could not hold the line."
        let help = Speech.sayItAloudHelp(for: "hold", in: sentence)
        if let caveat = Speech.caveat(forSpeaking: "hold", in: sentence) {
            #expect(help == Text(verbatim: caveat), "the caveat did not reach the button's help")
        } else {
            #expect(help == Text("Say it aloud"), "a good voice was apologised for")
        }
    }

    /// And a word in a language with no voice at all is told so rather than failing silently.
    @Test func aLanguageWithNoVoiceIsNamedRatherThanSilent() {
        let caveat = Speech.caveat(for: "xx-nonexistent", among: [])
        #expect(caveat == String(localized: "No voice is installed for this language."))
    }

    /// **A word alone does not say what language it is in, and the cost is the wrong voice rather
    /// than silence.** Measured on this Mac with `NLLanguageRecognizer`, 14 of 17 common English
    /// headwords are misread on their own — *fine* as Italian, *hold* as Danish, *sanction* as
    /// French, *gift* as Swedish, *die* and *bald* and *war* and *man* as German — and this Mac has
    /// a voice for every one of those, so nothing reports a failure: the word is simply pronounced
    /// in Italian. The reader's own sentence is on the card, and both call sites passed `nil`.
    ///
    /// `#require` on the premise rather than an `#expect`: if this Mac's recogniser ever reads the
    /// bare word as English, the fixture can no longer show the sentence mattering, and the test
    /// must refuse to run rather than pass while proving nothing.
    @Test func theSentenceDecidesWhichLanguageAWordIsSpokenIn() throws {
        for (word, sentence) in [
            ("fine", "It was a fine piece of filmmaking, and the weather held."),
            ("die", "The die was cast before anyone spoke."),
            ("gift", "She sent the book as a gift to her brother."),
        ] {
            try #require(
                Speech.language(forSpeaking: word, in: nil) != "en",
                "this Mac reads “\(word)” alone as English, so it cannot show the sentence mattering")
            #expect(
                Speech.language(forSpeaking: word, in: sentence) == "en",
                "“\(word)” would be spoken in \(Speech.language(forSpeaking: word, in: sentence))")
        }
    }

    /// With no sentence there is still a voice: the word is all there is, and guessing from it beats
    /// refusing to speak.
    @Test func withNoSentenceTheWordIsAllThereIs() {
        #expect(Speech.language(forSpeaking: "filmmaking", in: nil).isEmpty == false)
        #expect(Speech.language(forSpeaking: "", in: nil) == "en", "an empty word still needs a voice to fall back on")
    }

    /// The drawer's speak button is the second call site, and it had the same `nil`.
    @Test func theDrawersSpeakButtonAlsoReadsTheSentence() throws {
        let drawer = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI/HistoryDrawerViews.swift")
        let source = try String(contentsOf: drawer, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(source.contains("Speech.say(entry.surface, in: entry.sentence)"))
        #expect(source.contains("Speech.sayItAloudHelp(for: entry.surface, in: entry.sentence)"))
    }
}
