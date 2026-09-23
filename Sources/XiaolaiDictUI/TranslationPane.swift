import AppKit
import SwiftUI
import XiaolaiDictCore

/// What the translation pane says for one outcome — and, above all, **which engine said it**.
///
/// Apple's framework is the stopgap while the local model is not downloaded, and it is measured to be
/// the weaker engine: it takes no instructions, so it cannot be told the sense the reader met, and it
/// misread four of eight hard sentences — *table … until next month* as 提交, the opposite. Unlabelled,
/// its answer would render exactly as confidently as the model's. So its answer always carries a
/// caveat in the reader's terms, and the model's never does: the label is how a measured-worse answer
/// stops looking like a measured-better one.
public struct TranslationPane: Equatable {
    public enum Body: Equatable {
        case text(String)
        /// Apple's framework has no pack for **this pair**. It reports `.supported` for exactly
        /// these, so only `.installed` counts — and what is missing is the pair, not the target on
        /// its own: a reader with Chinese installed and no English→Chinese pack is told the truth
        /// only if both are named.
        case languagePack(source: String, target: String)
        case sameLanguage
        case unavailable
    }

    public let body: Body
    /// Said under Apple's answer, and under nothing else.
    public let caveat: String?
    /// Whether this **outcome** is one to offer a download beside. Whether the app can actually
    /// start one is read live where the pane is drawn: a download that began while the translation
    /// was in flight would otherwise still be offered by a snapshot taken before it.
    public let offersDownload: Bool
    /// The card this belongs to — the sentence, the language, the dictionary shown and the sense it
    /// was told. A pane is drawn only beside the card it was made for: switching dictionaries, or a
    /// sense mark arriving late, makes a different card, and an answer about the old one is not
    /// about this one.
    public let of: Key

    public struct Key: Equatable, Sendable {
        let sentence: String
        let target: String
        let dictionary: String
        let sense: String?

        public init(sentence: String, target: String, dictionary: String, sense: String?) {
            self.sentence = sentence
            self.target = target
            self.dictionary = dictionary
            self.sense = sense
        }
    }

    /// Whether the pane sends the reader to where the missing language pack is added.
    public var opensLanguageSettings: Bool {
        if case .languagePack = body { return true }
        return false
    }

    /// System Settings → General → Language & Region, where **Translation Languages…** adds a pack.
    /// Measured on the E2E Mac, 2026-09-23: this URL opens that pane with the button on it. The app
    /// cannot add a pack itself — `canRequestDownloads` is false for a session built on installed
    /// languages — so taking the reader to the button is the offer.
    public static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")

    public init(_ outcome: TranslationOutcome, of key: Key) {
        of = key
        switch outcome {
        case .translated(let text, by: .localModel):
            body = .text(text)
            caveat = nil
            offersDownload = false
        case .translated(let text, by: .appleTranslation):
            body = .text(text)
            caveat = Self.weakerEngine
            offersDownload = true
        case .needsLanguagePack(let source, let target):
            body = .languagePack(source: source, target: target)
            caveat = nil
            offersDownload = true
        case .sameLanguage:
            body = .sameLanguage
            caveat = nil
            offersDownload = false
        case .unavailable:
            body = .unavailable
            caveat = nil
            offersDownload = true
        }
    }

    /// The weaker engine, said as what it means for this sentence rather than as a ranking.
    static var weakerEngine: String {
        String(localized: "Translated by Apple, which cannot be told which sense you met and misreads some sentences.",
               comment: "Under a translation of the reader's sentence when Apple's Translation framework produced it")
    }
}

extension TranslationQuestion {
    /// The reader's sentence, **fed the sense the card is showing** — never run apart from it. Two
    /// subsystems side by side that can disagree while both look certain is worse than no pane.
    ///
    /// Only a sense the card leads with goes along. An ambiguous or undecided card has admitted it
    /// does not know, and handing its favourite to the translator would present the guess twice.
    public static func reading(_ card: LookupCard, sentence: String, target: String) -> TranslationQuestion {
        TranslationQuestion(sentence: sentence, target: target, met: metSense(of: card))
    }

    /// The sense a card leads with, where it leads with one.
    static func metSense(of card: LookupCard) -> MetSense? {
        guard case .sense(let shown) = card.answer else { return nil }
        return MetSense(term: card.term, sense: shown.label)
    }
}

/// What the panel needs to translate, handed in by the app — which owns the model service and the
/// download. The default translates nothing and offers nothing, so a view built without the app
/// says "could not" rather than pretending.
public struct TranslationActions: Sendable {
    public var translate: @Sendable (TranslationQuestion) async -> TranslationOutcome
    /// The reader's own language, which is what a translation is into.
    public var target: String
    public var canDownloadModel: Bool
    public var downloadModel: @MainActor () -> Void

    public init(
        translate: @escaping @Sendable (TranslationQuestion) async -> TranslationOutcome,
        target: String, canDownloadModel: Bool, downloadModel: @escaping @MainActor () -> Void
    ) {
        self.translate = translate
        self.target = target
        self.canDownloadModel = canDownloadModel
        self.downloadModel = downloadModel
    }

    public static let none = TranslationActions(
        translate: { _ in .unavailable }, target: ReaderLanguage.preferred, canDownloadModel: false,
        downloadModel: {})
}

private struct TranslationActionsKey: EnvironmentKey {
    static let defaultValue = TranslationActions.none
}

extension EnvironmentValues {
    public var translation: TranslationActions {
        get { self[TranslationActionsKey.self] }
        set { self[TranslationActionsKey.self] = newValue }
    }
}

/// The reader's sentence in their own language, revealed on request — **translation is a reveal,
/// not a default**: the reader guesses first and the tool confirms, which is what makes a look-up
/// retrieval practice rather than re-exposure.
struct TranslationPaneView: View {
    @Environment(\.scale) private var scale
    @Environment(\.translation) private var actions
    let pane: TranslationPane
    /// Shown when System Settings would not open — a link macOS no longer answers must not read as
    /// a button the reader failed to press.
    @State private var failedToOpenSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            answer
            if let caveat = pane.caveat {
                Text(caveat)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            waysOut
        }
        .onChange(of: pane) { failedToOpenSettings = false }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.vertical, scale.space.column)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(Token.Opacity.senseWash))
    }

    /// What came back, or why nothing did.
    @ViewBuilder private var answer: some View {
        switch pane.body {
        case .text(let text):
            Text(text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .languagePack(let source, let target):
            Text("""
                 Translating \(Self.languageName(source)) into \(Self.languageName(target)) needs \
                 that language pair. Add it in System Settings, under General → Language & Region → \
                 Translation Languages.
                 """)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        case .sameLanguage:
            Text("This sentence is already in your language.").font(.callout)
        case .unavailable:
            Text("This sentence could not be translated.").font(.callout)
        }
    }

    /// The ways out: where a missing language pair is added, and the download that replaces the
    /// weaker engine. Whether a download can be started is read **now**, not when the translation
    /// came back — one begun since would otherwise be offered by a button that does nothing.
    @ViewBuilder private var waysOut: some View {
        HStack(spacing: scale.space.stack) {
            if let settings = TranslationPane.languageSettings, pane.opensLanguageSettings {
                Button("Open Language & Region…") { open(settings) }
                    .buttonStyle(.glass)
            }
            // Only under the pane that offers the link, and only while it is the same pane: SwiftUI
            // reuses this view for the next outcome, and a failure left standing under a
            // translation that has no settings button at all is about nothing the reader can see.
            if failedToOpenSettings, pane.opensLanguageSettings {
                Text("System Settings would not open. Look for Language & Region under General.")
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            }
            if pane.offersDownload, actions.canDownloadModel {
                Button("Download the local model") { actions.downloadModel() }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
    }

    /// Says so rather than doing nothing: a deep link that a future macOS stops answering would
    /// otherwise be a button with no effect and no explanation.
    private func open(_ url: URL) {
        // Assigned on **every** attempt: set once and left, the message stood over a later attempt
        // that worked, and over a pane that no longer offers the link at all.
        failedToOpenSettings = !NSWorkspace.shared.open(url)
    }

    /// The language's name **in the reader's own language** — from `ReaderLanguage.preferred`, not
    /// `Locale.current`: the bundle ships English only, and `Locale.current` can resolve to that
    /// rather than to what the reader chose. The project makes the same distinction for the
    /// dictionary proposal, for the same reason.
    static func languageName(_ identifier: String) -> String {
        Locale(identifier: ReaderLanguage.preferred).localizedString(forIdentifier: identifier) ?? identifier
    }
}
