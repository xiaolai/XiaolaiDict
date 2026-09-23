import AVFoundation
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
    @Test func aCompactOnlyLanguageSaysSo() {
        let caveat = Speech.caveat(for: "en", among: installed)
        let best = installed.filter { $0.language.hasPrefix("en") }.map(\.quality.rawValue).max()
        if best == AVSpeechSynthesisVoiceQuality.default.rawValue {
            #expect(caveat?.contains("compact") == true, "a compact-only language said nothing about it")
            #expect(caveat?.contains("Spoken Content") == true, "it did not say where to get better ones")
        } else {
            #expect(caveat == nil, "a good voice was apologised for")
        }
    }

    /// Speaking nothing is not an error, and must not raise one.
    @Test(arguments: ["", "   ", "\n\t"])
    func blankTextIsNotSpoken(text: String) {
        Speech.say(text)
    }
    /// **The wire, not the value.** `Speech.caveat` was complete, memoised and tested while nothing
    /// in the card asked for it — the reader with only a compact voice was told nothing for as long
    /// as the card has existed. The check is on what reaches the button, because that is the part
    /// that was missing.
    @Test func theSpeakButtonCarriesTheCaveatAboutTheVoice() throws {
        let card = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI/LookupCardView.swift")
        let source = try String(contentsOf: card, encoding: .utf8)
        #expect(source.contains("help: Speech.caveat(forSpeaking: card.term) ?? \"Say it aloud\""),
                "the speak button says nothing about the voice it will use")
    }

    /// And a word in a language with no voice at all is told so rather than failing silently.
    @Test func aLanguageWithNoVoiceIsNamedRatherThanSilent() {
        let caveat = Speech.caveat(for: "xx-nonexistent", among: [])
        #expect(caveat == String(localized: "No voice is installed for this language."))
    }

}
