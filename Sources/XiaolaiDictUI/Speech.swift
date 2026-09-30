import AVFoundation
import DictionaryModel
import SwiftUI
import XiaolaiDictBase
import XiaolaiDictCore
import os

/// Saying a word aloud, with the best voice the reader actually has.
///
/// **Spike S1 settled the design**: measured from inside the published Developer ID bundle on the
/// E2E machine, `speechVoices()` returns 180 voices — *every one of them `default` quality* — and
/// the compact Samantha synthesised 31,498 frames. So the bundle can speak, and Stage 6 is "use the
/// system" rather than "ship a model".
///
/// The same measurement found why the good voices were missing, and it is not a XiaolaiDict problem:
/// `/Library/Application Support/Speech/SpeechSynthesisVoices` is **empty** — no enhanced or
/// premium voice has ever been downloaded — and `say -v '?'` sees exactly the same 
/// picture from outside any bundle. That is machine state, and it is the reader's to change.
///
/// Which is why this picks the best voice available rather than the system default, and says when
/// what it found is only a compact one. A compact voice is noticeably worse, and a reader who does
/// not know better ones exist will conclude that XiaolaiDict sounds bad.
@MainActor
public enum Speech {
    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "speech")
    private static let synthesizer = AVSpeechSynthesizer()

    /// `AVSpeechSynthesisVoice.speechVoices()` costs **43 ms** a call — measured, 180 voices on the
    /// E2E machine — and the panel asks for the caveat from a SwiftUI body, which is evaluated many
    /// times per layout. Unmemoised, that alone kept the entry's web view from rendering inside the
    /// E2E suite's window. The installed set does not change during a lookup.
    ///
    /// A voice downloaded while XiaolaiDict is running will not be noticed until the next launch. The
    /// caveat is advisory, so a stale "only a compact voice" for one session is a fair price for a
    /// panel that renders.
    private static var cachedVoices: [AVSpeechSynthesisVoice]?
    private static var cachedCaveats: [String: String?] = [:]

    public static var installedVoices: [AVSpeechSynthesisVoice] {
        if let cachedVoices { return cachedVoices }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        cachedVoices = voices
        return voices
    }

    /// The best voice installed for `language`, preferring premium, then enhanced, then compact.
    /// Nil when the reader has no voice for that language at all.
    public static func bestVoice(
        for language: String, among voices: [AVSpeechSynthesisVoice]? = nil
    ) -> AVSpeechSynthesisVoice? {
        let voices = voices ?? installedVoices
        let matching = voices.filter { $0.language.hasPrefix(language) }
        // `language` may be a bare code ("en") or a full tag ("en-US"); a bare one matches every
        // region, which is what a reader with only en-GB installed needs.
        guard !matching.isEmpty else { return nil }
        for quality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced, .default] {
            if let best = matching.first(where: { $0.quality == quality }) { return best }
        }
        return matching.first
    }

    /// What the reader can be told about the voice that will be used. Nil when there is nothing
    /// worth saying — a premium or enhanced voice speaks for itself.
    public static func caveat(
        for language: String, among voices: [AVSpeechSynthesisVoice]? = nil
    ) -> String? {
        // Memoised per language: the panel asks for this from a view body.
        if voices == nil, let known = cachedCaveats[language] { return known }
        let answer = uncachedCaveat(for: language, among: voices ?? installedVoices)
        if voices == nil { cachedCaveats[language] = answer }
        return answer
    }

    private static func uncachedCaveat(
        for language: String, among voices: [AVSpeechSynthesisVoice]
    ) -> String? {
        guard let voice = bestVoice(for: language, among: voices) else {
            return String(localized: "No voice is installed for this language.")
        }
        guard voice.quality == .default else { return nil }
        guard let better = recommendation(for: language) else {
            // A language macOS offers nothing better for. Saying "better ones are a download"
            // anyway is an errand that ends in confusion, and it is the reader's own language
            // this happens to — Chinese has no voice above compact to download at all.
            return String(localized: """
                Only a compact voice is available for this language. macOS offers nothing better \
                for it.
                """)
        }
        return String(
            localized: "Only a compact voice is installed. \(better) is a free download in \(Self.voiceLibrary).",
            comment: "Voice caveat: which voice to get, and the app that installs it")
    }

    /// The voice worth downloading for `language`, by name.
    ///
    /// **Hardcoded, because nothing can be asked.** There is no API that lists the voices a Mac
    /// *could* install — only the ones it has — so this is a measured claim about macOS rather than
    /// a reading of it, and it is written down with what was measured.
    ///
    /// Measured on macOS 27 (build 26A428) on 2026-10-01, through `--speech-report` inside the
    /// signed bundle: **Ava (Premium)** installs, is vended by `AVSpeechSynthesisVoice` as
    /// `com.apple.voice.premium.en-US.Ava`, and **renders 35,483 frames** against the compact
    /// Samantha's 31,498. That last number is the part worth keeping — the reported macOS Tahoe
    /// fault is that premium voices are *silently* skipped, so "it installed" would not have been
    /// evidence that it speaks.
    ///
    /// Nil for anything not named, and Chinese is deliberately not named: the voice catalogue
    /// covers 25 languages and no variety of Chinese is among them.
    static func recommendation(for language: String) -> String? {
        if language.hasPrefix("en-GB") { return "Serena" }
        if language.hasPrefix("en") { return "Ava" }
        return nil
    }

    /// **Where a voice is actually installed on macOS 27, which is not System Settings.**
    ///
    /// The caveat used to send readers to System Settings → Accessibility → Spoken Content. There
    /// is no voice list there any more: searching Settings for "Manage Voices" returns no results,
    /// and the phrase appears nowhere in `ExtensionKit/Extensions`, `PrivateFrameworks`,
    /// `CoreServices`, `/System/Applications` or any `.loctable` on the machine — checked
    /// 2026-10-01. VoiceOver Utility is where the list survives, and it is where Ava was found.
    static var voiceLibrary: String {
        // Localized, for the reason `PrivacySettings` localizes its two paths: a translation is
        // not a rendering of the English but whatever the running system prints on that screen.
        String(localized: "VoiceOver Utility → Speech",
               comment: "Where macOS installs voices — use the system's own wording for both names")
    }

    /// VoiceOver Utility itself, so the reader can be taken there rather than told a path.
    public static let voiceLibraryURL = URL(fileURLWithPath: "/System/Applications/Utilities/VoiceOver Utility.app")

    /// The caveat for the text that would be spoken, found the way `say` finds its voice — from
    /// the reader's own sentence where there is one.
    ///
    /// **Restored 2026-09-23, having stopped reaching the reader when the card replaced the
    /// panel.** The old panel asked for this; the card had no caller, so the whole thing — the
    /// memoisation measured at 43 ms a call, the wording, its tests — sat unreachable under a green
    /// suite, which is the failure class this project has recorded twice. It rides on the speak
    /// button's own help text: that is where the reader already is when the voice matters, and it
    /// costs no layout. Nil where there is nothing worth saying.
    public static func caveat(forSpeaking text: String, in sentence: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return caveat(for: language(forSpeaking: trimmed, in: sentence))
    }

    /// **Which language a word will be spoken in, decided from the sentence it was read in.**
    ///
    /// A single word tells `NLLanguageRecognizer` far too little, and the cost is not silence — it
    /// is the wrong voice, confidently. Measured on this Mac, 14 of 17 common English headwords are
    /// misread on their own: *fine* as Italian, *hold* as Danish, *sanction* as French, *gift* as
    /// Swedish, *die* and *bald* and *war* and *man* as German. This Mac has a voice for every one
    /// of those, so nothing reports a failure and nothing is caveated — the word is simply
    /// pronounced in Italian. The reader's own sentence settles it: *die* alone reads as German,
    /// *die* in "The die was cast…" as English.
    ///
    /// This is ADR-0001's rule about scripts, arriving at the other end of the app: one word gives
    /// the recogniser too little to work with, so never ask it about one where a sentence is at hand.
    ///
    /// **`sentence` has no default.** A default is exactly what let both call sites pass nothing
    /// while the sentence sat one property away on the value they already held.
    public static func language(forSpeaking text: String, in sentence: String?) -> String {
        Lemmatizer.language(of: text, in: sentence) ?? "en"
    }

    /// **The tooltip on a speak button, wherever one is drawn.**
    ///
    /// Written out twice — once on the lookup card, once on a history card — it had already drifted
    /// in the way that is hardest to see. The drawer's was `Text("Say it aloud")`, so the compiler
    /// extracted it and a translator got it; the card's was assembled as a `String` and reached
    /// `Text` through the verbatim overload, which extracts nothing. Same tooltip, translated in one
    /// surface and English in the other, and no test would ever have said so.
    ///
    /// The caveat, where there is one, is a sentence this type has already localized, so it arrives
    /// verbatim; the ordinary case is a key.
    public static func sayItAloudHelp(for text: String, in sentence: String?) -> Text {
        caveat(forSpeaking: text, in: sentence).map { Text(verbatim: $0) } ?? Text("Say it aloud")
    }

    /// Says `text` in the language it appears to be in. Silence is reported to the log rather than
    /// to the reader: a word that will not speak is a small failure, and interrupting a lookup to
    /// say so would be a larger one.
    public static func say(_ text: String, in sentence: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: trimmed)
        let spoken = language(forSpeaking: trimmed, in: sentence)
        utterance.voice = bestVoice(for: spoken)
        guard utterance.voice != nil else {
            log.notice("no voice installed for \(spoken, privacy: .public); nothing spoken")
            return
        }
        synthesizer.speak(utterance)
    }
}
