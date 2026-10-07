import CaptureModel
import DictionaryModel
import ModelKit
import StudyKit
import StudyPresentation
import XiaolaiDictCore
import SwiftUI

/// The panel, as a card: **the answer, the evidence, the way out.**
///
/// Read top to bottom it is one sentence — *this word, here, means this; here is where you read
/// it; here is how sure XiaolaiDict is; and here is everything else it could mean.* The order is the
/// design. Putting the alternatives first makes a reference work; putting the evidence last makes
/// a claim nobody can check.
public struct LookupCardView: View {
    @Environment(\.scale) private var scale
    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let card: LookupCard
    /// Promoting a sense: the reader's tap turns XiaolaiDict's hypothesis into a fact, and is the single
    /// most valuable thing they can do here — it is how a wrong guess gets corrected and how the
    /// ledger learns something it can stand behind.
    public var onChoose: ((SensePresentation) -> Void)?
    /// **Agreeing with the card's own guess.** Non-nil only where the sense on screen is a hypothesis
    /// *and* can actually be recorded — the panel works that out, because only it holds the entry the
    /// encounter is built from, and it passes nothing where there is nothing to write. So the control
    /// exists exactly where it can act, rather than being drawn and then refusing.
    ///
    /// Without it, `chosen_by: reader` could only ever be recorded for a *correction*: the only
    /// tappable senses were the other ones, so every answer the selector got right stayed a hypothesis
    /// for good and a reader who agreed had no way to say so.
    public var onConfirm: (() -> Void)?
    /// Expansion from the compact card reveals all meanings immediately.
    public var showsAllMeanings: Bool
    @State private var showingAlternatives = false
    @State private var showingMemory = false

    public init(
        card: LookupCard, onChoose: ((SensePresentation) -> Void)? = nil,
        onConfirm: (() -> Void)? = nil, showsAllMeanings: Bool = false
    ) {
        self.card = card
        self.onChoose = onChoose
        self.onConfirm = onConfirm
        self.showsAllMeanings = showsAllMeanings
        _showingAlternatives = State(initialValue: showsAllMeanings)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            heading
            memoryDetail
            answer
            evidence
            wayOut
        }
        .padding(scale.space.pad)
        // **Sized by its content, bounded by legibility.** The card is as tall as what it has to
        // say and no taller; the width floor and ceiling are a measure — a definition wants
        // roughly 55–70 characters a line, and a card that can be dragged narrower than that
        // breaks a sense into slivers.
        .frame(
            minWidth: scale.space.cardMinWidth,
            idealWidth: scale.space.cardWidth,
            maxWidth: scale.space.cardMaxWidth,
            alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A disclosure opening or closing, as a fade — and through `MotionPreference`, so the one
    /// place that says what Reduce Motion does to this app says it for the card as well.
    private var disclosure: Animation {
        MotionPreference.animation(.easeOut(duration: Token.Motion.hover), reduceMotion: reduceMotion)
    }

    // MARK: - The word

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
            // The word itself, in the label colour. The row's secondary is for what surrounds
            // it, and the headword had been taking it too — grey, on its own card.
            Text(card.heading)
                .font(.system(size: scale.text.display, weight: .semibold))
                .foregroundStyle(.primary)
            if let partOfSpeech = PartOfSpeechLabel.reader(card.partOfSpeech) {
                Text(partOfSpeech)
                    .font(.system(size: scale.text.body).italic())
                    .foregroundStyle(.secondary)
            }
            if let pronunciation = card.pronunciation {
                // Secondary, not tertiary. How the word sounds is content, and tertiary measured
                // 1.88:1 on the light card and 2.2:1 on the dark one (2026-10-01).
                Text(pronunciation)
                    .font(.system(size: scale.text.body))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: scale.space.inline)
            // **`stack` between the targets, not `inline`.** Each is 28 pt round a glyph of about
            // 15, so at `inline` the glyphs sat 18 pt apart against the 24 the platform asks of
            // controls with no edge of their own.
            HStack(alignment: .firstTextBaseline, spacing: scale.space.stack) {
                if let memory = card.memory { memoryBadge(memory) }
                // The help says what the voice will be where that is worth saying: only a compact
                // one installed, or none at all for this language. **And nothing where it is not**
                // — handed the control's own name as its help, VoiceOver read the name twice.
                IconButton(
                    .sayAloud,
                    help: Speech.caveat(forSpeaking: card.term, in: card.sentence).map { Text(verbatim: $0) }
                ) {
                    Speech.say(card.term, in: card.sentence)
                }
                IconButton(.openInDictionary) {
                    SystemDictionary.open(card.term)
                }
            }
        }
        // Both heading actions, one colour: they are the card's chrome, not its answer.
        .foregroundStyle(.secondary)
    }

    /// How many times before, as a digit.
    ///
    /// The strip this replaced said "3rd lookup" in prose across the top of the panel. It is the
    /// same fact and a different message: a number sits there to be ignored, a sentence tells the
    /// reader they have failed to learn this word twice already. They opened a dictionary, not a
    /// progress report.
    ///
    /// **A bare digit was too little, though.** A pink "50" beside a speaker read as a score or a
    /// page number (2026-10-01); its accessibility name was the number alone; its hit area was
    /// about 15 pt tall; and the digit, in the accent on an 18% wash of the same accent, was the
    /// smallest text on the card at the lowest contrast. So it carries History's own clock, a name
    /// that says what is counted, the platform's 28 pt target round the capsule, and its digit in
    /// the label colour — the wash and the glyph are what tie it to the word.
    private func memoryBadge(_ memory: MemoryStrip) -> some View {
        Button {
            withAnimation(disclosure) { showingMemory.toggle() }
        } label: {
            HStack(spacing: scale.space.tight) {
                ActionSymbol.historyPane.image
                    .foregroundStyle(accent)
                Text(memory.occasion, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .font(.system(size: scale.text.micro, weight: .semibold))
            // At its own width, always: squeezed by the heading it drew its digit as an ellipsis.
            .fixedSize()
            .padding(.horizontal, scale.space.inline)
            .padding(.vertical, scale.space.tight)
            .background(Capsule().fill(accent.opacity(Token.Opacity.badgeWash)))
            // The capsule stays the size of what it says; the target round it does not.
            .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
            .contentShape(Rectangle())
            .showBordersEdge()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("^[\(memory.occasion) reading](inflect: true) of this word"))
        // The tooltip is also what VoiceOver says after the name, so it is said once, here.
        .help(Text("Show where you read this word before"))
    }

    /// Where and when the earlier ones were — **never what they said**. An earlier encounter says
    /// *you should know this*; an earlier gloss answers the question and destroys the retrieval
    /// (C2). `PriorEncounter` has no field for one.
    @ViewBuilder
    private var memoryDetail: some View {
        if showingMemory, let memory = card.memory {
            VStack(alignment: .leading, spacing: scale.space.line) {
                // **By position, not by the text.** These are formatted lines — "two days ago, in
                // Safari: A page" — so two encounters on the same page inside one relative-time
                // bucket are the same string, and `id: \.self` gives SwiftUI duplicate identities
                // for rows that are genuinely two. The list is immutable and drawn in one pass, so
                // the index is a true identity here rather than a workaround.
                ForEach(Array(memory.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
                if memory.more > 0 {
                    Text("^[and \(memory.more) more](inflect: true)")
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - The answer

    @ViewBuilder
    private var answer: some View {
        switch card.answer {
        case .sense(let sense):
            // Set as prose at reading size, not as a dictionary line item. This is the thing the
            // reader came for and it should be the largest text after the word itself.
            Text(sense.label)
                .font(.system(size: scale.text.strong))
                .lineSpacing(scale.text.leading)
                .fixedSize(horizontal: false, vertical: true)
        case .ambiguous(let sense, let among):
            // The favourite, shown at full size — it is still the best answer anyone has — with
            // the badge beside it doing the work the old non-answer did, in three words instead
            // of a sentence that told the reader nothing they could act on.
            VStack(alignment: .leading, spacing: scale.space.line) {
                Text(sense.label)
                    .font(.system(size: scale.text.strong))
                    .lineSpacing(scale.text.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // **The badge is this card's standing line**, so the confirmation goes beside it for
                // the same reason it goes beside the other. `standing` is nil here — `LookupCard.claim`
                // deliberately says nothing for an ambiguous card — so without this the one state that
                // most needs resolving would have no way to resolve it.
                HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                    ambiguousBadge(among: among)
                    confirmControl
                }
            }
        case .undecided(let reason):
            // An abstention is the selector working, so it reads as a statement rather than as an
            // error: no warning colour, no icon, just what happened and what to do about it. In
            // the label colour, because on this card it *is* the answer.
            Text(reason ?? String(localized: "The meaning you read could not be identified."))
                .font(.system(size: scale.text.body))
                .fixedSize(horizontal: false, vertical: true)
        case .prose(let text):
            Text(text)
                .font(.system(size: scale.text.body))
                // **No line limit.** It was six, and `lineLimit` *discards* — nothing could reveal
                // what it cut and there was no expansion control. The panel now wraps its content
                // in a scroll view bounded by `cardMaxHeight`, so length is handled by scrolling
                // and truncation only hides a public-fallback definition's end.
                .fixedSize(horizontal: false, vertical: true)
        case .absent:
            Text("No entry for “\(card.term)” in your dictionaries.")
                .font(.system(size: scale.text.body))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The evidence

    /// The reader's own sentence, and how much XiaolaiDict is claiming. Together these are what let a
    /// wrong answer be spotted: the claim sits directly under the text it was made from.
    ///
    /// **The claim is drawn whether or not there is a sentence, and that is the repair.** This took
    /// the sentence as a parameter and was called only where there was one, so the "A guess, not
    /// confirmed" line did not exist on a card with no captured context — the selector's hypothesis
    /// rendered exactly as confidently as the reader's own tap, in the one state where the reader has
    /// least to check it against. The state is ordinary rather than exotic:
    /// `SenseSelector.preflight` answers `.chose` as soon as the part-of-speech filter leaves one
    /// candidate, *before* it looks for a sentence, and `LookupRunner` passes no sentence whenever
    /// the capture's context is not `.complete`.
    ///
    /// `setApart()` now marks the sentence alone, which is also what it is for: the hairline says
    /// *this is not the same kind of text as the thing above it*, and the reader's own words are that
    /// — the claim underneath is the app speaking about them.
    @ViewBuilder
    private var evidence: some View {
        let sentence = card.sentence.flatMap { $0.isEmpty ? nil : $0 }
        if sentence != nil || card.claim != nil {
            VStack(alignment: .leading, spacing: scale.space.line) {
                if let sentence {
                    // The reader's own words, in the label colour. Secondary measured 3.9:1 on the
                    // light card, under the bar for text this size — and this is the line they
                    // check the answer against.
                    Text(marked(sentence))
                        .font(.system(size: scale.text.body))
                        .lineSpacing(scale.text.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .setApart()
                    // **Under the sentence, and only where there is one.** The notice explains a span the
                    // reader has just seen underlined; without the sentence there is no span to explain,
                    // and the phrase alone would be an answer to a question nobody asked.
                    if let phrase = card.phrase {
                        PhraseNoticeView(phrase: phrase, accent: accent)
                    }
                }
                standing
            }
        }
    }

    /// Said plainly. "XiaolaiDict's guess" and "you chose this" are different claims and the reader is
    /// entitled to know which one they are looking at before they believe it.
    ///
    /// **Told apart by a mark, not by a colour.** The guess was orange text — 2.27:1 on the light
    /// card, the least legible line on it, with hue as the only thing separating it from a
    /// confirmed sense. A question mark in front of ordinary text says the same to a reader who
    /// cannot tell orange from grey.
    @ViewBuilder
    private var standing: some View {
        // `LookupCard.claim` is nil for the ambiguous card, which says so in its own badge:
        // repeating it here would be the same admission twice on one card.
        if let claim = card.claim {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                if card.isHypothesis {
                    StatusLabel(.unconfirmed, text: Text(verbatim: claim.explanation))
                } else {
                    Text(verbatim: claim.explanation)
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
                // Beside the claim it resolves: the reader reads "A guess, not confirmed" and the
                // remedy is the next thing their eye lands on.
                confirmControl
            }
        }
    }

    /// **The one gesture that turns the card's guess into a fact.** Drawn where the doubt is said —
    /// beside the standing line for a proposed sense, beside the badge for the ambiguous card — and
    /// only where the panel has handed over something to do.
    ///
    /// It says *what it will mean*, not what it does mechanically: "Yes, That's It" is the reader's
    /// own sentence about the answer, where "Confirm" is the app's word for a database write.
    ///
    /// **A button that looks like one.** It was tinted text under `.plain` — blue at 3.9:1 light
    /// and 3.25:1 dark, with no edge, no hover and no pressed state, so nothing but its colour said
    /// it could be pressed. A small bordered button is the platform's own answer to all four, and
    /// bordered rather than glass because the card is paper: glass is for a control floating over
    /// content, and this is in it.
    @ViewBuilder
    private var confirmControl: some View {
        if let onConfirm {
            Button(action: onConfirm) {
                Label("Yes, That’s It", systemImage: ActionSymbol.confirmMeaning.symbol)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(Text("Record this as the meaning you read"))
        }
    }

    /// Says the quiet part where the reader can act on it. `among` is how many senses were in the
    /// running, because "one of four" is a job the reader can finish and "ambiguous" alone is not.
    private func ambiguousBadge(among: Int) -> some View {
        StatusLabel(.unconfirmed, text: Text("Ambiguous: ^[\(among) meaning](inflect: true) fit this sentence"))
    }

    /// The same marking the history card uses, down to the reader's emphasis setting — which this
    /// used to ignore, hardcoding semibold in `.primary` while the drawer honoured the preference
    /// and coloured by the word's own accent.
    private func marked(_ sentence: String) -> AttributedString {
        // **The captured range, and a search only where there is none.** Searching took the first
        // case-insensitive substring, so looking up *he* in "The man said he was fine" marked the
        // *he* inside "The", and a word appearing twice in its own sentence marked whichever came
        // first. The range is checked against the sentence before it is trusted: one from another
        // sentence would otherwise bracket whatever sits at that offset.
        let text = sentence as NSString
        let captured = card.sentenceRange.flatMap { range -> NSRange? in
            guard range.location >= 0, NSMaxRange(range) <= text.length,
                  text.substring(with: range).compare(card.term, options: .caseInsensitive) == .orderedSame
            else { return nil }
            return range
        }
        return MarkedSentence.text(
            sentence,
            marking: Lemmatizer.parts(
                of: card.term, surface: card.term, in: sentence,
                at: captured ?? text.range(of: card.term, options: .caseInsensitive)),
            phrase: card.phrase,
            size: scale.text.body, emphasis: options.emphasis, accent: accent)
    }

    /// The word's own colour, the same one the history card will give it — the hash is stable, so
    /// a word met in the panel and later seen in the drawer is the same colour both times. Keyed
    /// by the **lemma**, and in the shade Increase Contrast asks for.
    private var accent: Color {
        ReadingPalette.color(forLemma: card.lemma, in: scheme, contrast: contrast)
    }

    // MARK: - The way out

    @ViewBuilder
    private var wayOut: some View {
        if !card.alternatives.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(disclosure) { showingAlternatives.toggle() }
                } label: {
                    HStack(spacing: scale.space.line) {
                        DisclosureChevron(isOpen: showingAlternatives)
                        Text("^[\(card.otherSenseCount) other meaning](inflect: true)")
                            .font(.system(size: scale.text.label, weight: .medium))
                    }
                }
                .buttonStyle(CardRowButtonStyle())
                .accessibilityValue(showingAlternatives ? Text("Expanded") : Text("Collapsed"))

                if showingAlternatives {
                    // **Under the block each belongs to.** A dictionary numbers its senses inside
                    // a part-of-speech block and starts again in the next, so one flat list drew
                    // 1…8, 1, 3, 4, 1 — see `LookupCard.alternativeGroups`.
                    ForEach(card.alternativeGroups) { group in
                        if card.namesAlternativeGroups,
                           let partOfSpeech = PartOfSpeechLabel.reader(group.partOfSpeech) {
                            Text(verbatim: partOfSpeech)
                                .font(.system(size: scale.text.small).italic())
                                .foregroundStyle(.secondary)
                                .padding(.leading, scale.space.inline)
                                .padding(.top, scale.space.inline)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.senses) { sense in
                            alternative(sense)
                        }
                    }
                }
            }
            // **Keyed to the entry, not to `onAppear`.** SwiftUI keeps this child's identity when
            // the reader switches dictionary, so `openedOnce` stayed true and the alternatives
            // stayed however the *previous* entry had left them: an entry the selector could not
            // decide came up collapsed, against `opensAlternatives`, because a different entry's
            // list had been closed by hand.
            //
            // `task(id:)` rather than `onChange`: it runs on first appearance too, so one rule
            // covers both and there is no `openedOnce` to get out of step.
            .task(id: card.heading) {
                showingAlternatives = showsAllMeanings || card.opensAlternatives
            }
        }
    }

    /// Tapping one promotes it. That is the correction path for the 17% the fallback selector gets
    /// confidently wrong, and it is a single click by design.
    private func alternative(_ sense: SensePresentation) -> some View {
        Button { onChoose?(sense) } label: {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                // Secondary: the number is how the reader finds this sense in the dictionary, and
                // tertiary was 1.88:1.
                Text(sense.ordinal, format: .number)
                    .font(.system(size: scale.text.small).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: scale.space.ordinal, alignment: .trailing)
                Text(sense.label)
                    .font(.system(size: scale.text.body))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if sense.metBefore {
                    // History's clock, the same mark the count in the heading wears: both say
                    // *you have been here*. It was `checkmark.circle`, which elsewhere in the app
                    // is "Already Know" — a claim about the reader this row does not make.
                    ActionSymbol.historyPane.image
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Read before"))
                        .help(Text("You have read this meaning before"))
                }
            }
        }
        .buttonStyle(CardRowButtonStyle(fillsWidth: true))
        .accessibilityHint(Text("Records this as the meaning you read"))
    }
}

/// The disclosure triangle the card's two lists open from. One view so the two symbols are named
/// once; they are not actions, so they are not in `ActionSymbol`.
struct DisclosureChevron: View {
    @Environment(\.scale) private var scale
    let isOpen: Bool

    var body: some View {
        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.system(size: scale.text.micro, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// **A line of text on the card that can be pressed** — a disclosure, a sense to choose, a
/// dictionary to switch to.
///
/// These were `.buttonStyle(.plain)` with a tint or nothing at all: no hover, no pressed state and
/// no edge, so colour was the only thing saying a line was a control, and for the sense rows not
/// even that (2026-10-01). The platform's answer for a row is a wash under the pointer and a
/// stronger one under the press, which is what a list row and a menu item both do.
///
/// The padding is the target: a 12 pt line is about 15 pt tall, and `line` above and below takes
/// it past the 20 pt a pointer needs. `showBordersEdge` draws an outline when the reader has asked
/// the system for one, which is the setting these borderless rows had no answer to.
struct CardRowButtonStyle: ButtonStyle {
    /// Whether the row takes the card's width, so the whole line is the target rather than its
    /// words. A disclosure hugs its label; a row in a list does not.
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        CardRow(configuration: configuration, fillsWidth: fillsWidth)
    }

    private struct CardRow: View {
        @Environment(\.scale) private var scale
        let configuration: Configuration
        let fillsWidth: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, scale.space.line)
                .padding(.horizontal, scale.space.inline)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Token.Target.edgeRadius, style: .continuous)
                        .fill(Color.primary.opacity(wash)))
                .showBordersEdge()
                .onHover { hovering = $0 }
        }

        private var wash: Double {
            if configuration.isPressed { return Token.Opacity.controlPressed }
            return hovering ? Token.Opacity.controlHover : 0
        }
    }
}

/// An optional short dictionary preview expands into the existing reading card, all its meanings,
/// the publisher's examples, and the study actions. The existing reading card remains the default.
/// The request identity in `PanelView` resets the disclosure for each new word; late answers for
/// the current word leave the reader's choice of compact or expanded intact.
public struct LookupPanelContent: View {
    @Environment(\.scale) private var scale
    @Environment(\.pinNote) private var pin
    @Environment(\.studySense) private var studySense
    @Environment(\.enrolSense) private var enrolSense
    @Environment(\.openDictionarySettings) private var openDictionarySettings
    @Environment(\.reportPanelFit) private var reportPanelFit
    @Environment(\.translation) private var translator
    @Environment(\.explainer) private var explainer
    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    /// Whether a status row follows the footer, which decides how much room the footer leaves
    /// under itself: the card's own bottom padding where it is the last thing, a row gap where
    /// the status row is.
    @Environment(\.lookupKeepStatus) private var keepStatus
    @Environment(\.closeLookup) private var close
    public let presentation: LookupPresentation
    /// What it is waiting for, in words. Nil once the dictionaries have answered.
    public let waiting: String?
    /// Which dictionary's entry the **reader switched to**. The card opens on the primary's — see
    /// `opening` — and switching is the
    /// reader asking — which is what makes an auxiliary sense studiable under D8.
    /// Which entry the **reader** switched to. Nil until they do, so the card follows `opening`
    /// — and a primary that arrives after the first draw is still where the card lands.
    @State private var showing: Int?
    /// **The explanation, with the question it answers.** It had no key at all, so an answer stayed
    /// on screen after its own question changed — confirming an ambiguous favourite tells both panes
    /// the sense, and only the translation noticed. Same shape as `TranslationPane`, arrived at the
    /// hard way.
    @State private var explanation: SentencePane?
    /// The explanation in flight — **held, like the translation, rather than started and
    /// forgotten**. A bare task outlives the card that started it, and the answer it eventually
    /// writes lands on whatever card is there by then. Cancelling stops this side waiting; a
    /// generation already inside the model service runs until the service bounds it.
    @State private var explaining: Task<Void, Never>?
    @State private var translation: TranslationPane?
    /// The one translation in flight. Replacing it cancels the one before, so two clicks cannot
    /// finish out of order, and it is cancelled when the card goes away. **Cancelling stops this
    /// side waiting** — a generation already running inside the model service is not something a
    /// client can stop, and the service's own watchdog is what bounds that.
    @State private var translating: Task<Void, Never>?
    @State private var copied = false
    /// **The sentence's own language, read once per sentence and off the layout path.**
    ///
    /// `NLLanguageRecognizer` is the same cost that forced `Speech.caveat` to memoise at 43 ms a call,
    /// so it must not be asked from a view body. The *source* is cached rather than the verdict:
    /// compared against `translator.target` at draw time the comparison is free, and a reader who
    /// changes their language is answered immediately — a cached Bool would have kept the translate
    /// control hidden.
    @State private var sourceLanguage: String?
    /// Whether the list of entries is open. Closed by default and closed again on landing somewhere
    /// else: the card leads with the primary dictionary (D7), and the others are there to be looked at.
    @State private var showingDictionaries = false
    /// **The sense the reader tapped, per entry.** `choose` used to write to the ledger and nothing
    /// else, so the card went on drawing the selector's proposal as its mark and — worse — a
    /// translation asked afterwards was still told the sense the reader had just rejected. A tap is
    /// a fact (`chosen_by: reader`); it replaces the hypothesis here as well as in the ledger.
    ///
    /// The decision is `PanelSelection`'s rather than this view's, so it can be asked questions
    /// from a test: keyed by the entry it was made in, and answering whether the selector's late
    /// proposal still changes what is on screen.
    @State private var selection = PanelSelection()
    @State private var showingDetails: Bool

    public init(presentation: LookupPresentation, waiting: String? = nil, detailsInitiallyExpanded: Bool = false) {
        self.presentation = presentation
        self.waiting = waiting
        _showingDetails = State(initialValue: detailsInitiallyExpanded)
    }

    private var isCompact: Bool { options.usesCompactLookup && !showingDetails }

    private var accent: Color {
        ReadingPalette.color(forLemma: presentation.lemma.text, in: scheme, contrast: contrast)
    }

    private var entries: [DictionaryEntry] {
        guard case .entries(let found, _) = presentation.outcome else { return [] }
        return Array(found)
    }

    /// Where the card opens: **the primary dictionary's entry**, not the first the service
    /// happened to return.
    ///
    /// `showing` is an index into the service's order, and it started at 0 under a comment
    /// promising the primary came first. Nothing put it there — the resolver chooses the primary
    /// independently, so the dictionary on screen and the dictionary whose sense was resolved and
    /// recorded could be different ones, with the reader shown an entry that had no mark and no
    /// explanation of why.
    // Not private: the defect was that nothing chose this, so it is asserted directly.
    var opening: Int {
        guard let primaryEntry = presentation.primaryEntry,
              let index = entries.firstIndex(where: { PanelSelection.identity(of: $0) == primaryEntry })
        else { return 0 }
        return index
    }

    private var entry: DictionaryEntry? { entry(at: showing ?? opening) ?? entries.first }

    /// One entry by index, bounds-checked. Named because three places index this list, and an index
    /// into a collection that may have changed is the kind of thing that wants one spelling.
    private func entry(at index: Int) -> DictionaryEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }

    public var body: some View {
        // No memory strip across the top any more — the count is a badge in the card's own
        // heading, where it is a fact rather than a remark.
        //
        // **Everything the window is sized from is inside the surface's one scroll view.** The
        // bound was on `LookupCardView` first, and that was wrong: the translation and explanation
        // panes are siblings of the card, not children of it, so a long generated answer grew the
        // window past the cap and then had no scrolling path to its own end.
        //
        // **And the footer is not.** It was the last thing in that scrolled stack, so with the
        // other senses open the dictionary switcher and all five actions sat below a fold the card
        // gave no sign of having (three screenshots, 2026-10-01, none showing a single action).
        // `PanelSurface` pins it under the scrolling region.
        //
        // **The compact preview has nothing to pin and no glow**: it is a short answer with one way
        // to more, so it is drawn at the quick card's own width and radius with a neutral lift only.
        PanelSurface(accent: isCompact ? nil : accent, compact: isCompact) {
            content
        } bar: {
            if !isCompact { pinnedFooter }
        }
        // The panel has gone: nothing is waiting for this answer, and a generation running for a
        // closed panel is one the reader is paying for twice.
        .onDisappear { translating?.cancel(); explaining?.cancel() }
        // **Here, on the panel, and not on the card inside it**: the compact preview does not mount that card, and
        // a translation asked for from the expanded one must still be dropped when the lookup moves on.
        // A different dictionary is a different card: what was translated for the last one is neither shown nor
        // still being worked on — and so is the same card once the sense mark arrives, which happens *after* it is
        // first drawn: an explanation written while the card said nothing about the sense would otherwise sit
        // under a card that now names one.
        .onChange(of: showing) { clearPanes() }
        // **Only where it changes the card.** A reader who has already chosen a sense here has the mark they asked
        // for, and clearing on the selector's late answer took away a translation they had asked for after choosing.
        .onChange(of: presentation.sense) {
            if let entry, !selection.hasChosen(in: entry) { clearPanes() }
        }
        // **Off the layout path, and keyed by the sentence.** `NLLanguageRecognizer` is the same cost
        // that forced `Speech.caveat` to memoise at 43 ms a call, so a view body may not ask it.
        .task(id: presentation.sentence) {
            let sentence = presentation.sentence ?? ""
            sourceLanguage = sentence.isEmpty ? nil : translator.sourceLanguage(sentence)
        }
    }

    /// Whether the sentence is already in the reader's own language — compared **now**, against a
    /// source detected once. Cached as a verdict it would have gone stale the moment the reader
    /// changed their language, leaving the control hidden for a sentence it could have translated.
    private var alreadyInTheReadersLanguage: Bool {
        guard let sourceLanguage else { return false }
        return SentenceLanguage.same(sourceLanguage, translator.target)
    }

    @ViewBuilder
    private var content: some View {
        if !options.usesCompactLookup {
            detailedContent
        } else if showingDetails {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button {
                        showingDetails = false
                    } label: {
                        Label(ActionSymbol.fewerDetails.title, systemImage: ActionSymbol.fewerDetails.symbol)
                            .frame(minHeight: Token.Target.minimum)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    IconButton(.closeLookup, action: close)
                }
                .font(.system(size: scale.text.label))
                .foregroundStyle(.secondary)
                .padding(.horizontal, scale.space.padAcross)
                .padding(.top, scale.space.padDown)
                detailedContent
            }
        } else {
            switch presentation.outcome {
            case .none:
                WaitingView(detail: waiting)
            case .notFound:
                compactCard(cardWithoutAnEntry(.absent))
            case .plainText(let text, _):
                compactCard(cardWithoutAnEntry(.prose(text)))
            case .entries:
                if let entry { compactCard(card(for: entry)) }
            }
        }
    }

    private func compactCard(_ card: LookupCard) -> some View {
        CompactLookupCardView(card: card, incomplete: compactIsIncomplete) {
            showingDetails = true
        }
    }

    /// Keep a short quality signal visible; expansion carries the precise explanation and remedy.
    private var compactIsIncomplete: Bool {
        if PanelCaveats.serviceUnanswered(presentation.outcome)
            || PanelCaveats.readOffTheScreen(presentation.capture, warning: options.warnsAboutScreenReading) {
            return true
        }
        if let entry, PanelCaveats.answeredAnotherWord(entry) { return true }
        if case .entries(_, let unreadable) = presentation.outcome { return !unreadable.isEmpty }
        return false
    }

    @ViewBuilder
    private var detailedContent: some View {
        switch presentation.outcome {
        case .none:
            WaitingView(detail: waiting)
        case .notFound:
            VStack(alignment: .leading, spacing: scale.space.stack) {
                LookupCardView(card: cardWithoutAnEntry(.absent))
                // **A miss and an unanswered question are not the same result.** Both drew "No
                // entry … in your dictionaries", which is a confirmed absence — so a crashed or
                // unreachable XPC service, with the public fallback also finding nothing, told the
                // reader their dictionaries do not have the word.
                if PanelCaveats.serviceUnanswered(presentation.outcome) { serviceCaveat }
            }
        case .plainText(let text, _):
            VStack(alignment: .leading, spacing: scale.space.stack) {
                let card = cardWithoutAnEntry(.prose(text))
                LookupCardView(card: card)
                if PanelCaveats.serviceUnanswered(presentation.outcome) { serviceCaveat }
                // Its one action, Copy, is in `pinnedFooter`.
            }
        case .entries(_, let unreadable):
            if let entry {
                VStack(alignment: .leading, spacing: scale.space.stack) {
                    captureCaveat
                    if !unreadable.isEmpty {
                        // Named once however many of its records failed: claiming all of them, or
                        // only one, would both be guesses.
                        // The dictionary names are data, so they are interpolated into a
                        // localizable format string rather than concatenated into one.
                        Notice(text: Text(
                            "An entry in \(unreadable.joined(separator: ", ")) could not be read, so what is shown is not all of it."))
                    }
                    LookupCardView(
                        card: card(for: entry), onChoose: { choose($0, in: entry) },
                        // Nil where there is nothing to record, so the control is never drawn over a
                        // sense it could not write — the encounter that would be written *is* the
                        // condition for drawing it.
                        onConfirm: confirmable(entry).map { encounter in
                            { confirm(encounter, in: entry) }
                        }, showsAllMeanings: options.usesCompactLookup)
                    // **Where the answer will be, while it is being written.** Waiting was a footer
                    // icon turning into an ellipsis; the pane says what is being worked on, and
                    // replaces an answer being asked for again rather than sitting under it.
                    if translating != nil {
                        ModelWaitingPane(message: Text("Translating this sentence…"))
                    } else if let translation, translation.of == translationKey(for: entry) {
                        // Only beside the card it was made for. A different dictionary, or a sense
                        // that arrived after it was asked, is a different card.
                        TranslationPaneView(pane: translation, retry: translate)
                    }
                    // Beside the card it was asked about, like the translation. An explanation and a
                    // translation are two answers to two questions, and each is drawn only while its
                    // own question still stands.
                    if explaining != nil {
                        ModelWaitingPane(message: Text("Explaining this sentence…"))
                    } else if let explanation, let sentence = presentation.sentence,
                              explanation.of == SentenceQuestion.reading(card(for: entry), sentence: sentence) {
                        SentencePaneView(explanation: explanation.answer, retry: explain)
                    }
                    matchCaveat(entry)
                    senseKeyCaveat(entry)
                    if options.usesCompactLookup { DictionaryDetailsView(entry: entry) }
                }
            }
        }
    }

    /// **What stays put while the card scrolls**: which dictionary answered, and what can be done
    /// with the answer.
    ///
    /// By outcome, like `content`, because the two have to agree about which card is on screen.
    /// A prose answer has one action — **a way to take the text away, because there is no other**:
    /// selecting it was never possible, since the panel's scene is `.plain`, which gives a
    /// borderless window with `canBecomeKey` false (measured 2026-09-25), and `textSelection`
    /// needs a key window. Copy needs none. Copy alone, and no pin: prose is not a sense, so a note
    /// made from it would carry no standing — which is the one thing `PinnedNote.Standing` exists
    /// to prevent.
    @ViewBuilder
    private var pinnedFooter: some View {
        switch presentation.outcome {
        case .entries:
            if let entry { footer(entry) }
        case .plainText(let text, _):
            proseFooter(cardWithoutAnEntry(.prose(text)))
        case .none, .notFound:
            EmptyView()
        }
    }

    /// Shown wherever the dictionary service could not be asked. It says the answer is incomplete
    /// without guessing what the answer would have been.
    private var serviceCaveat: some View {
        Notice(text: Text("Your dictionaries could not all be asked, so this may not be the whole answer."))
    }

    /// **How the word was read, where that is worth doubting.** `presentation.capture` was carried
    /// to the card and never consumed, so a word read off the pixels with Vision — which unlike
    /// the Accessibility paths can be *wrong* rather than merely absent — was presented exactly
    /// like an exact text-range capture. This is the panel's half of the rule that every capture
    /// carries its own quality signal.
    @ViewBuilder
    private var captureCaveat: some View {
        if PanelCaveats.readOffTheScreen(
            presentation.capture, warning: options.warnsAboutScreenReading) {
            Notice(text: Text("This word was read off the screen, so it may not be exactly right."))
        }
    }

    /// A dictionary that answered with a different headword says so. `entry.match` was computed
    /// and dropped, so a near match read as the term's own entry.
    @ViewBuilder
    private func matchCaveat(_ entry: DictionaryEntry) -> some View {
        if PanelCaveats.answeredAnotherWord(entry) {
            Notice(text: Text(
                "\(entry.dictionary.name) answered with \(entry.headword), which is not the word you looked up."))
        }
    }

    /// **A dictionary that marks no senses says so on the card, and the cure goes beside it.**
    ///
    /// The card already says "This dictionary does not mark separate meanings, so none can be pointed at here."
    /// — a condition with a two-click cure, and no way to reach it. One row below, the translation
    /// pane sends the reader to a missing language pack; this is the same courtesy for the setting
    /// that decides whether the whole sense path can work at all (D7).
    ///
    /// Asked of `entry.senseKeyKind`, never of the message: matching the reader's own sentence to
    /// decide whether to offer a fix would break the first time anyone reworded it.
    ///
    /// **Not gated on how many dictionaries answered.** The footer's chips are, and that gate would
    /// have hidden this in exactly the case that needs it — one entry, no senses, nothing to switch
    /// between.
    @ViewBuilder
    private func senseKeyCaveat(_ entry: DictionaryEntry) -> some View {
        if entry.senseKeyKind == SenseKeyKind.none {
            HStack(spacing: scale.space.inline) {
                Spacer(minLength: 0)
                // Bordered, not glass: this is a button in the card's content, on paper, and
                // glass is for a control floating over content. The ellipsis stays — it opens
                // another window.
                Button("Choose Another Dictionary…") { openDictionarySettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, scale.space.padAcross)
        }
    }

    private func card(for entry: DictionaryEntry) -> LookupCard {
        let mark = mark(for: entry)
        return LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: presentation.met),
            term: presentation.term, lemma: presentation.lemma.text,
            sentenceRange: presentation.sentenceRange,
            sentence: presentation.sentence, mark: mark,
            memory: presentation.memory, phrase: presentation.phrase)
    }

    /// **A card with no entry behind it.** Both states the primary dictionary can leave the panel
    /// in — nothing found, and prose rather than senses — differ only in the answer, so they are
    /// one builder: written out twice, a change to the sentence or the memory strip reached one
    /// card and not the other.
    private func cardWithoutAnEntry(_ answer: LookupCard.Answer) -> LookupCard {
        LookupCard(
            term: presentation.term, lemma: presentation.lemma.text,
            heading: presentation.term, partOfSpeech: nil,
            pronunciation: nil, answer: answer,
            // **Shown on the no-entry card too**, and this is where it matters most: a reader whose
            // *take* found nothing is exactly the reader who needs to be told the sentence held
            // *take something into account*. A phrase answer does not depend on the word's.
            sentence: presentation.sentence, alternatives: [], memory: presentation.memory,
            phrase: presentation.phrase)
    }

    /// A tap on a sense is the reader's, and is recorded as theirs — the correction path for a
    /// guess, and under D8 the only way an auxiliary dictionary's sense becomes a study item.
    ///
    /// The encounter is built **first**, and nothing is marked where it cannot be: an entry with no
    /// id, or a dictionary whose senses carry none, gives a tap that would be a confirmation with
    /// nothing behind it.
    private func choose(_ sense: SensePresentation, in entry: DictionaryEntry) {
        guard let key = sense.key,
              let encounter = SenseEncounter.of(entry, senseKey: key, chosenBy: .reader, at: .now)
        else { return }
        studySense(encounter)
        selection.choose(key, in: entry)
        clearPanes()
    }

    /// **What confirming the card's own guess would record, or nil where nothing can be.**
    ///
    /// One function, answering both "may this be offered?" and "what is written if it is" — because two
    /// conditions that must agree are the arrangement that produced every broken switch on this card.
    /// Nil where the card is not claiming a guess (there is nothing to confirm), where the reader has
    /// already chosen here, and where the sense cannot be keyed: "a sense a dictionary cannot key is
    /// never presented as confirmed, however it was marked".
    ///
    /// The ambiguous favourite counts. It is the state that most needs resolving, and the card draws
    /// the control beside its badge for that reason.
    private func confirmable(_ entry: DictionaryEntry) -> SenseEncounter? {
        guard !selection.hasChosen(in: entry) else { return nil }
        let card = card(for: entry)
        guard card.isHypothesis else { return nil }
        let sense: SensePresentation? = {
            if let leading = card.leadingSense { return leading }
            if case .ambiguous(let favourite, _) = card.answer { return favourite }
            return nil
        }()
        guard let sense, let key = sense.key else { return nil }
        return SenseEncounter.of(entry, senseKey: key, chosenBy: .reader, at: .now)
    }

    /// The reader agreed with the sense already on screen. Recorded as theirs, exactly as a tap on an
    /// alternative is — the ledger keeps `model` and `reader` apart and never merges them, so this
    /// adds the reader's row rather than rewriting the selector's.
    ///
    /// **It clears no pane, and that is the whole difference from `choose`.** Promoting a *different*
    /// sense makes everything said about the old one wrong; agreeing with this one changes what the
    /// card claims and not what it says, so a translation the reader asked for stays. Where a pane's
    /// own question really did change — the ambiguous favourite, which neither pane was told — the
    /// pane is dropped by its own key rather than by a blanket clear here. `ConfirmingASenseTests`
    /// is that rule in both directions.
    ///
    /// The copy indicator *is* reset: the pasteboard holds "(a guess — not confirmed)", and after this
    /// the card no longer says that, so a standing checkmark would promise a clipboard the reader does
    /// not have.
    private func confirm(_ encounter: SenseEncounter, in entry: DictionaryEntry) {
        studySense(encounter)
        selection.choose(encounter.senseKey ?? "", in: entry)
        copied = false
    }

    /// Whatever was said about the card as it was is not about the card as it is: a translation in
    /// flight was told the old sense, and an answer already on screen was written for it.
    private func clearPanes() {
        // **The checkmark is about what is on the pasteboard**, and what was copied was the card as
        // it was. Left standing, it says the sense now shown is the one the reader has, while the
        // pasteboard still holds the old one.
        copied = false
        translating?.cancel()
        translating = nil
        translation = nil
        explaining?.cancel()
        explaining = nil
        explanation = nil
    }

    /// The mark the card draws and every question is built from: the reader's own tap **in this
    /// entry** where there is one, and the selector's proposal otherwise.
    private func mark(for entry: DictionaryEntry) -> SenseMark? {
        selection.mark(for: entry, proposing: presentation.sense, ownedBy: presentation.senseOwner)
    }

    // MARK: - The row under the card

    /// The actions that are about this lookup rather than about this word, and — where there is
    /// more than one — which dictionary answered.
    private func footer(_ entry: DictionaryEntry) -> some View {
        // **It wraps.** Measured 2026-09-25: at the card's 312 pt minimum the usable width is 276 pt,
        // and four 28 pt targets with their gaps leave 128 pt for a dictionary control against NOAD's
        // name at 164.1 pt — one row cannot hold both. Of the ways out, wrapping is the only one whose
        // correctness does not depend on how long a dictionary's name or a headword happens to be.
        VStack(alignment: .leading, spacing: scale.space.line) {
            dictionaryRow
            actions(entry)
        }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.top, scale.space.inline)
        .padding(.bottom, footerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pinnedToTheCard(in: scheme)
    }

    /// The card's own bottom padding where the footer is its last row, and a row gap where the
    /// status row follows — that row brings its own.
    private var footerBottomPadding: CGFloat {
        keepStatus == nil ? scale.space.padDown : scale.space.inline
    }

    /// A disclosure opening or closing, through the one place that answers Reduce Motion.
    private var disclosure: Animation {
        MotionPreference.animation(.easeOut(duration: Token.Motion.hover), reduceMotion: reduceMotion)
    }

    /// **Which entry the reader is reading, and the way to another — as a disclosure, not a menu.**
    ///
    /// The same gesture the card already uses for "12 other meanings", so it is a vocabulary the reader
    /// has already met here. Two things follow from it being a disclosure rather than a popup: each
    /// entry gets a full row, which is what makes room for a label that tells *fine¹* from *fine²*;
    /// and it opens no second window, so it cannot meet the click-away dismissal that a menu extending
    /// outside the panel's frame might. `--panel-report` measures that, and this control does not wait
    /// on the answer.
    @ViewBuilder
    private var dictionaryRow: some View {
        let list = DictionaryList(of: entries)
        if list.isWorthShowing {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(disclosure) { showingDictionaries.toggle() }
                } label: {
                    HStack(spacing: scale.space.line) {
                        DisclosureChevron(isOpen: showingDictionaries)
                        // **Through `row(at:)`, never a bare subscript.** `entry` falls back the same
                        // way for the same reason, so the heading names the entry the card draws.
                        if let current = list.row(at: showing ?? opening) ?? list.rows.first {
                            Text(verbatim: current.label)
                                .font(.system(size: scale.text.small, weight: .medium))
                                .lineLimit(1)
                                // One line, so a long name is cut — and then the whole of it is
                                // a hover away rather than nowhere.
                                .help(Text(verbatim: current.label))
                        }
                        if list.otherDictionaries > 0 {
                            // Dictionaries, never entries: NOAD answering four times is one other
                            // dictionary, and counting entries would say four.
                            Text("^[\(list.otherDictionaries) other dictionary](inflect: true)")
                                .font(.system(size: scale.text.small))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(CardRowButtonStyle())
                .accessibilityValue(showingDictionaries ? Text("Expanded") : Text("Collapsed"))

                if showingDictionaries {
                    ForEach(list.rows) { row in
                        let isShown = row.index == (showing ?? opening)
                        Button { showing = row.index } label: {
                            HStack(spacing: scale.space.line) {
                                // The filled mark is the state; its colour only follows the
                                // window, as every selection does — accent where the window is
                                // the one being worked in, grey where it is not.
                                Image(systemName: isShown ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: scale.text.small))
                                    .foregroundStyle(
                                        isShown
                                            ? AnyShapeStyle(SelectionAppearance.ring(appearsActive: appearsActive))
                                            : AnyShapeStyle(.secondary))
                                    .accessibilityHidden(true)
                                Text(verbatim: row.label)
                                    .font(.system(size: scale.text.small, weight: isShown ? .medium : .regular))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(CardRowButtonStyle(fillsWidth: true))
                        // **The trait, not only the glyph.** The filled circle said which row was
                        // chosen to a reader who could see it; VoiceOver was told each row was a
                        // button and nothing about which one was current.
                        .accessibilityAddTraits(isShown ? .isSelected : [])
                    }
                }
            }
            // **Closed whenever the reader lands somewhere else**, so choosing a row closes the list
            // it was chosen from and a late-arriving primary does not leave it hanging open over a card
            // it is no longer about. `task(id:)` rather than `onChange` so first appearance is covered
            // by the same rule — the same reason the alternatives use it.
            .task(id: showing ?? opening) { showingDictionaries = false }
        }
    }

    /// The one action a prose answer has. Built from `LookupCard.copyableText` like the footer's copy
    /// button, so the two cannot put different things on the pasteboard for the same card.
    @ViewBuilder
    private func proseFooter(_ card: LookupCard) -> some View {
        if let copyable = card.copyableText {
            HStack(spacing: scale.space.stack) {
                Spacer(minLength: 0)
                IconButton(
                    title: "Copy This Definition",
                    symbol: (copied ? ActionSymbol.done : ActionSymbol.copy).symbol
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyable, forType: .string)
                    copied = true
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, scale.space.padAcross)
            .padding(.top, scale.space.inline)
            .padding(.bottom, footerBottomPadding)
            .pinnedToTheCard(in: scheme)
        }
    }

    /// The actions, on their own row under the dictionary control.
    private func actions(_ entry: DictionaryEntry) -> some View {
        // `stack` between the targets, for the reason the heading gives: at `inline` the glyphs
        // were 18 pt apart.
        HStack(spacing: scale.space.stack) {
            Spacer(minLength: 0)
            if presentation.sentence?.isEmpty == false {
                // **Absent, not disabled, where translating could say nothing.** `translate` answers
                // `.sameLanguage` on its first line, so for a reader whose own language is the
                // sentence's this was a guaranteed dead end on every card. Hidden rather than dimmed:
                // on a card this dense a control that can never activate on their machine is clutter
                // explaining something they will never need. The cost, accepted: for a reader of two
                // languages it comes and goes between lookups, unexplained.
                if !alreadyInTheReadersLanguage { translateButton }
                explainButton
            }
            enrolButton(entry)
            copyButton(entry)
            pinButton(entry)
        }
    }

    /// **Add this meaning to what the reader is studying.** Separate from tapping a sense, which
    /// records that they met it, and separate from pinning, which keeps it on screen.
    ///
    /// Offered only where a target can actually be built, and **disabled with the reason** where it
    /// cannot rather than silently doing nothing: a dictionary that marks no senses can still be
    /// studied at the entry rung, but an entry with no id of its own cannot be named at all, and a
    /// control that refuses a click is a broken switch.
    ///
    /// The bookmark, and the word *Save* — the symbol and the word the Library uses for the pane
    /// the meaning then appears in. It was "Keep for learning" under a stack of cards, so the
    /// reader pressed Keep and looked for the result under Saved.
    private func enrolButton(_ entry: DictionaryEntry) -> some View {
        let target = enrollable(entry)
        return IconButton(
            .saveMeaning,
            help: target == nil
                ? Text("This dictionary cannot name this entry, so it cannot be saved")
                : nil,
            isEnabled: target != nil
        ) {
            guard let target else { return }
            enrolSense(target)
            // Durable acknowledgement is drawn by the request-keyed keep status.
        }
        // Legible when off, for the reason spelled out on the copy button below.
        .foregroundStyle(target == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
    }

    /// What enrolling this card would save, or nil where nothing can be.
    ///
    /// **The sense where the card has one that can be keyed, the entry otherwise.** Both are honest
    /// rungs (`study-unit.md` §3) and the ledger tells them apart; what neither can survive is an
    /// entry with no id, because a target keyed to nothing is a card that can never be found again.
    ///
    /// `chosenBy` carries through unchanged, so a sense the model proposed enrols as a proposal and
    /// is not gradable until the reader agrees — the guess never becomes a fact by being saved.
    private func enrollable(_ entry: DictionaryEntry) -> SenseEncounter? {
        guard let entryKey = entry.entryKey else { return nil }
        let card = card(for: entry)
        if let sense = card.leadingSense, let key = sense.key {
            // **The standing the card is drawing is the standing that is saved.** A proposal enrols
            // as a proposal and is not gradable until the reader agrees; a tap is theirs. Reading it
            // off the card rather than deciding again here is what stops the two disagreeing.
            let chosenBy: SenseChoice? =
                switch sense.standing {
                case .confirmed(let choice): choice
                case .proposed: .model
                case .unclaimed: nil
                }
            if let encounter = SenseEncounter.of(entry, senseKey: key, chosenBy: chosenBy, at: .now) {
                return encounter
            }
        }
        // The entry rung: no sense the dictionary can key, so nothing is claimed about which one.
        return SenseEncounter(
            dictionary: entry.dictionary, entryID: entryKey, senseKey: nil, senseKeyKind: .none,
            sensePath: nil, entrySenseCount: entry.senseCount, senseHash: nil,
            gloss: Self.leadingDefinition(in: entry), chosenBy: nil, chosenAt: .now)
    }

    /// The first definition the entry marks — what an entry-rung card reveals until the reader
    /// narrows it. **Local only**, the same rule every stored gloss carries.
    static func leadingDefinition(in entry: DictionaryEntry) -> String? {
        for block in entry.blocks {
            for sense in block.senses where !(sense.definition ?? "").isEmpty { return sense.definition }
        }
        return nil
    }

    /// A footer action that runs something and waits for it. Two of them had grown their own
    /// copies, and their behaviour under a second click had already diverged.
    ///
    /// **While it runs it is a spinner, and it is not a button.** It used to swap its symbol for
    /// `ellipsis`, which is the platform's *More* — a control that looked like it opened a menu
    /// and was disabled. A small `ProgressView` is what waiting looks like; the pane under the
    /// card says what for.
    @ViewBuilder
    private func footerAction(
        _ kind: ActionSymbol, title: LocalizedStringKey, running: Text?, act: @escaping () -> Void
    ) -> some View {
        if let running {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
                .accessibilityLabel(running)
                .help(running)
        } else {
            IconButton(kind, title: title, action: act)
                .foregroundStyle(.secondary)
        }
    }

    /// The reader's sentence **put into** their own language — on request, because it is a reveal,
    /// and fed the sense the card is leading with.
    private var translateButton: some View {
        footerAction(
            .translate, title: "Translate This Sentence",
            running: translating == nil ? nil : Text("Translating this sentence…"), act: translate)
    }

    /// Asks for the translation — from the footer, and again from the pane's own Retry.
    private func translate() {
        guard let entry, let sentence = presentation.sentence else { return }
        let card = card(for: entry)
        let question = TranslationQuestion.reading(card, sentence: sentence, target: translator.target)
        let key = translationKey(for: entry)
        let actions = translator
        translating?.cancel()
        translating = Task {
            let outcome = await actions.translate(question)
            guard !Task.isCancelled else { return }
            translation = TranslationPane(outcome, of: key)
            translating = nil
        }
    }

    /// What a translation is about: the sentence, the language, the dictionary on screen and the
    /// sense the card was leading with when it was asked.
    private func translationKey(for entry: DictionaryEntry) -> TranslationPane.Key {
        TranslationPane.Key(
            sentence: presentation.sentence ?? "", target: translator.target,
            dictionary: entry.dictionary.key,
            sense: TranslationQuestion.metSense(of: card(for: entry))?.sense)
    }

    private var explainButton: some View {
        footerAction(
            .explain, title: "Explain This Sentence",
            running: explaining == nil ? nil : Text("Explaining this sentence…"), act: explain)
    }

    /// Asks for the explanation — from the footer, and again from the pane's own Retry.
    private func explain() {
        // Built from the card, by the same function the pane is compared against — so what was
        // asked and what is drawn cannot be two different questions. It used to be assembled here
        // and thrown away, which is how an answer came to outlive its own question.
        guard let entry, let sentence = presentation.sentence else { return }
        let question = SentenceQuestion.reading(card(for: entry), sentence: sentence)
        explaining?.cancel()
        let explain = explainer.explain
        explaining = Task {
            // **The downloaded model first.** Reaching for Apple's here would make the pane
            // work only for readers who have Apple Intelligence — which the LLM-pane decision
            // says it must not.
            let answer = await explain(question)
            guard !Task.isCancelled else { return }
            explanation = SentencePane(answer: answer, of: question)
            explaining = nil
        }
    }

    /// Copy takes the sense on screen, ambiguous included — but an uncertain one says so in the
    /// copied text, because a paste has no badge beside it.
    ///
    /// **Disabled where there is no sense, rather than silently doing nothing.** It used to switch
    /// over the answer here and fall through: on a card the selector abstained on — and on every
    /// card from a dictionary that marks no senses, which is three of the seven enabled here — the
    /// button was drawn enabled, took the click and left the pasteboard untouched. What it is
    /// allowed to act on is `LookupCard.senseToKeep`, which can be asked that question from a test.
    private func copyButton(_ entry: DictionaryEntry) -> some View {
        let copyable = card(for: entry).copyableText
        return IconButton(
            title: "Copy the Word and This Meaning",
            // The checkmark is what *was copied*, so it is the symbol and never the name.
            symbol: (copied ? ActionSymbol.done : ActionSymbol.copy).symbol,
            // Only where it has something to add: the name is the tooltip otherwise, and a help
            // that repeated the name was read twice by VoiceOver.
            help: copyable == nil
                ? Text("No meaning was identified, so there is nothing to copy")
                : nil,
            isEnabled: copyable != nil
        ) {
            guard let copyable else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyable, forType: .string)
            copied = true
        }
        // **Drawn as disabled, not merely disabled — and still legible.** A `.plain` button's label
        // keeps whatever foreground style it was given, so `.secondary` here would look identical
        // enabled or not, which is the broken switch one layer further in. `.quaternary` was the
        // first answer and went too far the other way: on the card, on screen, it reads as *absent*,
        // and a control the reader cannot see is one they never hover — so the tooltip saying why it
        // is off is unreachable, which was the whole point of disabling it rather than hiding it.
        // Tertiary is kept for exactly this: on this card it means *off*, and nothing else wears it.
        .foregroundStyle(copyable == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
    }

    /// **A guess may be kept, and it is kept as a guess.** The proposal once was to enable this for
    /// `.ambiguous` because the panel badges it — and the badge is the *panel's*, not the note's. A
    /// note carries no standing of its own, so pinning one laundered a sense the selector was unsure
    /// of into a note that reads exactly like a confirmed one: a failure rendering as confidently as
    /// a success, at the one surface that outlives the panel. `senseToKeep` carries the standing for
    /// exactly that reason.
    ///
    /// **Disabled where there is no sense**, for the same reason as copy: the `default: return` this
    /// replaces made it a button that took a click and did nothing.
    ///
    /// *Pin as a Note*, not "Keep this sense as a note": there were two *keep*s in one row, this and
    /// "Keep for learning", with unrelated icons and unrelated effects.
    private func pinButton(_ entry: DictionaryEntry) -> some View {
        let keep = card(for: entry).senseToKeep
        return IconButton(
            .pinNote,
            help: keep == nil
                ? Text("No meaning was identified, so there is nothing to pin")
                : nil,
            isEnabled: keep != nil
        ) {
            guard let keep else { return }
            let card = card(for: entry)
            pin(PinnedNote(
                heading: card.heading, dictionary: entry.dictionary,
                partOfSpeech: card.partOfSpeech, pronunciation: card.pronunciation,
                text: keep.sense.label, standing: keep.standing))
        }
        // Legible when off, for the reason spelled out on the copy button above.
        .foregroundStyle(keep == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
    }
}


/// **Which caveats a result needs, as decisions rather than as view code.**
///
/// Each of these was a signal the card was handed and dropped: a service failure rendered as a
/// confirmed miss, an optically recognised word rendered like an exact capture, a near match
/// rendered as the term's own entry. They live here because a `@ViewBuilder` condition cannot be
/// asserted, and "a failure must never render as confidently as a success" is exactly the kind of
/// rule that stops holding quietly.
public enum PanelCaveats {
    /// The dictionary service could not be asked, so the answer may be less than the whole one.
    /// **Both outcomes that carry a failure count** — a miss and an unanswered question drew the
    /// same "No entry … in your dictionaries".
    public static func serviceUnanswered(_ outcome: LookupOutcome?) -> Bool {
        switch outcome {
        case .notFound(let why): why != nil
        case .plainText(_, let why): !why.isEmpty
        default: false
        }
    }

    /// Read off the pixels with Vision, which unlike every Accessibility path can be *wrong*
    /// rather than merely absent.
    public static func readOffTheScreen(_ capture: CaptureQuality?, warning: Bool = true) -> Bool {
        guard warning else { return false }
        return capture?.isDoubtful == true
    }

    /// The dictionary answered with a different headword altogether.
    public static func answeredAnotherWord(_ entry: DictionaryEntry) -> Bool {
        entry.match == .otherHeadword
    }
}

// MARK: - Previews

#if DEBUG
/// The card at its three real states, at the width it is meant to be — ~400, not the 760×520
/// document window the panel used to open at. An answer is not a document.
private func card(_ mark: SenseMark?) -> LookupCard {
    let entry = sampleEntry("New Oxford American Dictionary")
    return LookupCard(
        presentation: EntryPresentation(entry: entry, mark: mark, met: []),
        term: "fine",
        sentence: "It was a fine piece of filmmaking, and the weather held.",
        mark: mark)
}

#Preview("The reader chose it") {
    LookupCardView(card: card(.chosen(key: "m_en_gbus0362750.005", by: .reader)))
        .frame(width: 400)
        .background(.background)
}

/// The state the design exists for: XiaolaiDict guessed, says so, and the way to correct it is one click.
#Preview("XiaolaiDict guessed it") {
    LookupCardView(card: card(.chosen(key: "m_en_gbus0362750.020", by: .model)))
        .frame(width: 400)
        .background(.background)
}

/// An abstention — the selector working, not failing.
#Preview("XiaolaiDict could not tell") {
    LookupCardView(card: card(.couldNot(.tooClose)))
        .frame(width: 400)
        .background(.background)
}

#Preview("XiaolaiDict guessed it, dark") {
    LookupCardView(card: card(.chosen(key: "m_en_gbus0362750.020", by: .model)))
        .frame(width: 400)
        .background(.background)
        .preferredColorScheme(.dark)
}
#endif
