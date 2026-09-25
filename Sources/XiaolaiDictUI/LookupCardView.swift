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
    @State private var showingAlternatives = false
    @State private var showingMemory = false

    public init(
        card: LookupCard, onChoose: ((SensePresentation) -> Void)? = nil,
        onConfirm: (() -> Void)? = nil
    ) {
        self.card = card
        self.onChoose = onChoose
        self.onConfirm = onConfirm
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

    // MARK: - The word

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
            Text(card.heading)
                .font(.system(size: scale.text.display, weight: .semibold))
            if let partOfSpeech = PartOfSpeechLabel.reader(card.partOfSpeech) {
                Text(partOfSpeech)
                    .font(.system(size: scale.text.body).italic())
                    .foregroundStyle(.secondary)
            }
            if let pronunciation = card.pronunciation {
                Text(pronunciation)
                    .font(.system(size: scale.text.body))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: scale.space.inline)
            if let memory = card.memory { memoryBadge(memory) }
            // The help says what the voice will be where that is worth saying: only a compact one
            // installed, or none at all for this language.
            IconButton(
                title: "Say it aloud", symbol: "speaker.wave.2",
                help: Speech.sayItAloudHelp(for: card.term, in: card.sentence)
            ) {
                Speech.say(card.term, in: card.sentence)
            }
            IconButton(
                title: "Open in Dictionary", symbol: "character.book.closed",
                help: SystemDictionary.openHelp
            ) {
                SystemDictionary.open(card.term)
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
    private func memoryBadge(_ memory: MemoryStrip) -> some View {
        Button {
            withAnimation(.easeOut(duration: Token.Motion.hover)) { showingMemory.toggle() }
        } label: {
            Text(memory.occasion, format: .number)
                .font(.system(size: scale.text.micro, weight: .semibold).monospacedDigit())
                .padding(.horizontal, scale.space.inline)
                .padding(.vertical, scale.space.tight)
                // The word's own colour, not a neutral grey. It ties the count to the word it is
                // about and makes a small thing findable without making it loud — the wash is
                // what carries it, and the digit sits on top at full strength.
                .background(Capsule().fill(accent.opacity(Token.Opacity.badgeWash)))
                .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
        .help(Text("^[You have looked this up \(memory.occasion) time](inflect: true)"))
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
                        .foregroundStyle(.tertiary)
                }
                if memory.more > 0 {
                    Text("^[and \(memory.more) more](inflect: true)")
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.tertiary)
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
            // error: no warning colour, no icon, just what happened and what to do about it.
            Text(reason ?? String(localized: "The sense you read could not be identified."))
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .prose(let text):
            Text(text)
                .font(.system(size: scale.text.body))
                // **No line limit.** It was six, and `lineLimit` *discards* — nothing could reveal
                // what it cut and there was no expansion control. The panel now wraps its content
                // in a scroll view bounded by `cardMaxHeight`, so length is handled by scrolling
                // and truncation only hides a public-fallback definition's end.
                .fixedSize(horizontal: false, vertical: true)
                .fixedSize(horizontal: false, vertical: true)
        case .absent:
            Text("No entry for “\(card.term)” in your dictionaries.")
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The evidence

    /// The reader's own sentence, and how much XiaolaiDict is claiming. Together these are what let a
    /// wrong answer be spotted: the claim sits directly under the text it was made from.
    ///
    /// **The claim is drawn whether or not there is a sentence, and that is the repair.** This took
    /// the sentence as a parameter and was called only where there was one, so the "A guess — not
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
                    Text(marked(sentence))
                        .font(.system(size: scale.text.body))
                        .foregroundStyle(.secondary)
                        .lineSpacing(scale.text.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .setApart()
                }
                standing
            }
        }
    }

    /// Said plainly. "XiaolaiDict's guess" and "you chose this" are different claims and the reader is
    /// entitled to know which one they are looking at before they believe it.
    @ViewBuilder
    private var standing: some View {
        // `LookupCard.claim` is nil for the ambiguous card, which says so in its own badge:
        // repeating it here would be the same admission twice on one card.
        if let claim = card.claim {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                Text(claim.explanation)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(card.isHypothesis ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                // Beside the claim it resolves: the reader reads "A guess — not confirmed" and the
                // remedy is the next thing their eye lands on.
                confirmControl
            }
        }
    }

    /// **The one gesture that turns the card's guess into a fact.** Drawn where the doubt is said —
    /// beside the standing line for a proposed sense, beside the badge for the ambiguous card — and
    /// only where the panel has handed over something to do.
    ///
    /// It says *what it will mean*, not what it does mechanically: "Yes, that's it" is the reader's
    /// own sentence about the answer, where "Confirm" is the app's word for a database write.
    @ViewBuilder
    private var confirmControl: some View {
        if let onConfirm {
            Button(action: onConfirm) {
                Label("Yes, that’s it", systemImage: "checkmark")
                    .font(.system(size: scale.text.small, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help(Text("Record this as the sense you met"))
        }
    }

    /// Says the quiet part where the reader can act on it. `among` is how many senses were in the
    /// running, because "one of four" is a job the reader can finish and "ambiguous" alone is not.
    private func ambiguousBadge(among: Int) -> some View {
        HStack(spacing: scale.space.line) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: scale.text.micro))
            Text("^[Ambiguous — \(among) sense](inflect: true) fit this sentence")
                .font(.system(size: scale.text.small, weight: .medium))
        }
        .padding(.horizontal, scale.space.inline)
        .padding(.vertical, scale.space.tight)
        .background(Capsule().fill(Color.orange.opacity(Token.Opacity.badgeWash)))
        .foregroundStyle(.orange)
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
            size: scale.text.body, emphasis: options.emphasis, accent: accent)
    }

    /// The word's own colour, the same one the history card will give it — the hash is stable, so
    /// a word met in the panel and later seen in the drawer is the same colour both times.
    private var accent: Color {
        ReadingPalette.accent(for: card.lemma).color(in: scheme)
    }

    // MARK: - The way out

    @ViewBuilder
    private var wayOut: some View {
        if !card.alternatives.isEmpty {
            VStack(alignment: .leading, spacing: scale.space.inline) {
                Button {
                    withAnimation(.easeOut(duration: Token.Motion.hover)) {
                        showingAlternatives.toggle()
                    }
                } label: {
                    HStack(spacing: scale.space.line) {
                        Image(systemName: showingAlternatives ? "chevron.down" : "chevron.right")
                            .font(.system(size: scale.text.micro))
                        Text("^[\(card.otherSenseCount) other sense](inflect: true)")
                            .font(.system(size: scale.text.label, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)

                if showingAlternatives {
                    ForEach(card.alternatives) { sense in
                        alternative(sense)
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
                showingAlternatives = card.opensAlternatives
            }
        }
    }

    /// Tapping one promotes it. That is the correction path for the 17% the fallback selector gets
    /// confidently wrong, and it is a single click by design.
    private func alternative(_ sense: SensePresentation) -> some View {
        Button { onChoose?(sense) } label: {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                Text(sense.ordinal, format: .number)
                    .font(.system(size: scale.text.small).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: scale.space.ordinal, alignment: .trailing)
                Text(sense.label)
                    .font(.system(size: scale.text.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if sense.metBefore {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.tertiary)
                        .help(Text("You have met this sense before"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One lookup, as the panel shows it: the card, and the few things that belong around it.
///
/// **What this replaced, and why each piece went.** The panel used to be a 260 pt sidebar listing
/// every dictionary and every sense, beside the publisher's entry rendered in a `WKWebView`, with
/// the chosen sense marked somewhere inside it. That is a reference work. The sidebar's job — reach
/// any sense — is done by the card's own "other senses", one click instead of a permanent column.
/// The web view's job — the publisher's full treatment, its examples, its etymology — is done by
/// Dictionary.app, which is one click in the heading and is better at it than a pane this size
/// could be.
///
/// What did *not* go: the memory strip, the notices, the waiting state, and every action the old
/// chrome carried — speak, copy, explain, pin, and studying an auxiliary dictionary's sense (D8).
/// Those were the panel doing its job rather than the panel being a dictionary.
public struct LookupPanelContent: View {
    @Environment(\.scale) private var scale
    @Environment(\.pinNote) private var pin
    @Environment(\.studySense) private var studySense
    @Environment(\.openDictionarySettings) private var openDictionarySettings
    @Environment(\.reportPanelFit) private var reportPanelFit
    @Environment(\.translation) private var translator
    @Environment(\.explainer) private var explainer
    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
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

    public init(presentation: LookupPresentation, waiting: String? = nil) {
        self.presentation = presentation
        self.waiting = waiting
    }

    /// The word's own colour, which the card's shadow is thrown in. The same accent the marked
    /// word in the sentence wears, so the glow under the card and the word inside it agree.
    private var accent: Color {
        ReadingPalette.accent(for: presentation.lemma.text).color(in: scheme)
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
        // **Scrolls rather than growing past `cardMaxHeight`, and the bound is here rather than on
        // the card.** A sense list is unbounded — 49 for *hold* in the bilingual Oxford, 73 for
        // *run* in NOAD — and the panel's window follows its content
        // (`.windowResizability(.contentSize)`), so without this the window grew until it ran off
        // the display. `PanelPlacement.fitted` then puts it back on screen, which without a scroll
        // view would only move the clipping from the screen's edge to the window's.
        //
        // It was on `LookupCardView` first, and that was wrong: the translation and explanation
        // panes are siblings of the card, not children of it, so a long generated answer grew the
        // window past the cap and then had no scrolling path to its own end. Everything the window
        // is sized from has to be inside one scroll view, which is `content`.
        //
        // `.scrollBounceBehavior(.basedOnSize)` so a short panel does not rubber-band: a two-line
        // answer is not a scrollable thing and must not behave like one.
        ScrollView { content }
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            minWidth: scale.space.cardMinWidth,
            idealWidth: scale.space.cardWidth,
            maxWidth: scale.space.cardMaxWidth,
            alignment: .leading)
        // **After the width frame, and `fixedSize` no longer fixes the height.** Measured: with
        // `.fixedSize(vertical: true)` still in the chain the panel took its natural height and the
        // cap did nothing — `noPanelIsTallerThanTheCap` failed against a 1,200-point panel. Fixing
        // a size vertically is the opposite of letting a scroll view bound it, and the scroll view
        // is what bounds it now. The horizontal half is gone with it because it was already false.
        .frame(maxHeight: scale.space.cardMaxHeight)
        // **And the window is as tall as that.** The cap bounds the scrolling region; nothing made
        // the *window* take the height the content asked for, so it stayed at the opening default —
        // measured 398 × 240 for every card, three runs, with the dictionary control, translate,
        // explain, copy and pin all below a fold the panel gives no sign of having. The view was
        // never at fault: `PanelHeightTests` measures its `fittingSize` at 267 pt for a one-line
        // answer and 405 for a long one. `LookupPanelController.show` writes the frame by hand, on
        // open and on every reuse, and a frame set by hand is not one SwiftUI revisits.
        //
        // Bounded by the same cap, so growing stops exactly where scrolling starts: a taller window
        // would hold empty space under the content.
        .fitsItsContent(upTo: scale.space.cardMaxHeight, report: reportPanelFit)
        // **The card is the window.** Its scene is `.plain`, which draws no background at all, so
        // the surface, the edge and the lift are the card's own — and they live here, in the
        // layer that has the tokens, rather than as literals in the scene that hosts it.
        .background(CardSurface.panel(for: scheme), in: shape)
        .overlay(shape.strokeBorder(
            Color.primary.opacity(Token.Opacity.border), lineWidth: Token.Stroke.hairline))
        .clipShape(shape)
        // Depth first, then colour. The neutral shadow is what actually lifts the card off the
        // desktop; the accent one is the word's colour thrown under it, and on its own it would
        // either stain the wallpaper or do nothing.
        .shadow(
            color: .black.opacity(Token.Opacity.cardLift),
            radius: scale.shadow.panelRadius,
            x: scale.shadow.panelOffset, y: scale.shadow.panelOffset)
        .shadow(
            color: accent.opacity(Token.Opacity.accentShadow),
            radius: scale.shadow.glowRadius,
            x: scale.shadow.glowOffset, y: scale.shadow.glowOffset)
        // Asymmetric, because the shadows are. Uniform padding would leave dead space above and
        // to the left of a window that is exactly the size of its content.
        .padding(.top, scale.shadow.glowBefore)
        .padding(.leading, scale.shadow.glowBefore)
        .padding(.bottom, scale.shadow.glowAfter)
        .padding(.trailing, scale.shadow.glowAfter)
        // The panel has gone: nothing is waiting for this answer, and a generation running for a
        // closed panel is one the reader is paying for twice.
        .onDisappear { translating?.cancel(); explaining?.cancel() }
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
        return SentenceTranslator.sameLanguage(sourceLanguage, translator.target)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: scale.radius.panel, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
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
                // **A way to take the text away, because there is no other.** This branch is the
                // public fallback's answer — prose rather than senses — and it drew no footer at all,
                // so the only text on the card could be neither copied nor selected. Selecting it was
                // never possible: the panel's scene is `.plain`, which gives a borderless window with
                // `canBecomeKey` false (measured 2026-09-25), and `textSelection` needs a key window.
                // Copy needs none.
                //
                // Copy alone, and no pin: prose is not a sense, so a note made from it would carry no
                // standing — which is the one thing `PinnedNote.Standing` exists to prevent.
                proseFooter(card)
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
                        })
                        // A different dictionary is a different card: what was translated for the
                        // last one is neither shown nor still being worked on.
                        // A different dictionary is a different card — and so is the same card once
                        // the sense mark arrives, which happens *after* it is first drawn: an
                        // explanation written while the card said nothing about the sense would
                        // otherwise sit under a card that now names one.
                        .onChange(of: showing) { clearPanes() }
                        // **Only where it changes the card.** A reader who has already chosen a
                        // sense here has the mark they asked for, and clearing on the selector's
                        // late answer took away a translation they had asked for after choosing.
                        .onChange(of: presentation.sense) {
                            if !selection.hasChosen(in: entry) { clearPanes() }
                        }
                    // Only beside the card it was made for. A different dictionary, or a sense that
                    // arrived after it was asked, is a different card.
                    if let translation, translation.of == translationKey(for: entry) {
                        TranslationPaneView(pane: translation)
                    }
                    // Beside the card it was asked about, like the translation. An explanation and a
                    // translation are two answers to two questions, and each is drawn only while its
                    // own question still stands.
                    if let explanation, let sentence = presentation.sentence,
                       explanation.of == SentenceQuestion.reading(card(for: entry), sentence: sentence) {
                        SentencePaneView(explanation: explanation.answer)
                    }
                    matchCaveat(entry)
                    senseKeyCaveat(entry)
                    footer(entry)
                }
            }
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
            Notice(
                text: Text("This word was read off the screen, so it may not be exactly right."),
                symbol: "eye.trianglebadge.exclamationmark")
        }
    }

    /// A dictionary that answered with a different headword says so. `entry.match` was computed
    /// and dropped, so a near match read as the term's own entry.
    @ViewBuilder
    private func matchCaveat(_ entry: DictionaryEntry) -> some View {
        if PanelCaveats.answeredAnotherWord(entry) {
            Notice(
                text: Text("\(entry.dictionary.name) answered with \(entry.headword), which is not the word you looked up."),
                symbol: "arrow.triangle.branch")
        }
    }

    /// **A dictionary that marks no senses says so on the card, and the cure goes beside it.**
    ///
    /// The card already says "This dictionary does not mark senses, so none can be pointed at here."
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
                Button("Choose a dictionary that marks senses…") { openDictionarySettings() }
                    .buttonStyle(.glass)
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
            memory: presentation.memory)
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
            sentence: presentation.sentence, alternatives: [], memory: presentation.memory)
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
        VStack(alignment: .leading, spacing: scale.space.inline) {
            dictionaryRow
            actions(entry)
        }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.bottom, scale.space.padDown)
    }

    /// **Which entry the reader is reading, and the way to another — as a disclosure, not a menu.**
    ///
    /// The same gesture the card already uses for "12 other senses", so it is a vocabulary the reader
    /// has already met here. Two things follow from it being a disclosure rather than a popup: each
    /// entry gets a full row, which is what makes room for a label that tells *fine¹* from *fine²*;
    /// and it opens no second window, so it cannot meet the click-away dismissal that a menu extending
    /// outside the panel's frame might. `--panel-report` measures that, and this control does not wait
    /// on the answer.
    @ViewBuilder
    private var dictionaryRow: some View {
        let list = DictionaryList(of: entries)
        if list.isWorthShowing {
            VStack(alignment: .leading, spacing: scale.space.inline) {
                Button {
                    withAnimation(.easeOut(duration: Token.Motion.hover)) {
                        showingDictionaries.toggle()
                    }
                } label: {
                    HStack(spacing: scale.space.line) {
                        Image(systemName: showingDictionaries ? "chevron.down" : "chevron.right")
                            .font(.system(size: scale.text.micro))
                        Text(verbatim: list.rows[showing ?? opening].label)
                            .font(.system(size: scale.text.micro, weight: .medium))
                            .lineLimit(1)
                        if list.otherDictionaries > 0 {
                            // Dictionaries, never entries: NOAD answering four times is one other
                            // dictionary, and counting entries would say four.
                            Text("^[\(list.otherDictionaries) other dictionary](inflect: true)")
                                .font(.system(size: scale.text.micro))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showingDictionaries {
                    ForEach(list.rows) { row in
                        Button { showing = row.index } label: {
                            HStack(spacing: scale.space.line) {
                                Image(systemName: row.index == (showing ?? opening)
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: scale.text.micro))
                                Text(verbatim: row.label)
                                    .font(.system(size: scale.text.micro))
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(row.index == (showing ?? opening)
                                         ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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
            HStack(spacing: scale.space.inline) {
                Spacer(minLength: 0)
                IconButton(
                    title: "Copy this definition",
                    symbol: copied ? "checkmark" : "doc.on.doc"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyable, forType: .string)
                    copied = true
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, scale.space.padAcross)
            .padding(.bottom, scale.space.padDown)
        }
    }

    /// The actions, on their own row under the dictionary control.
    private func actions(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: scale.space.inline) {
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
            copyButton(entry)
            pinButton(entry)
        }
    }

    /// The reader's sentence **put into** their own language — on request, because it is a reveal,
    /// and fed the sense the card is leading with.
    /// A footer action that runs something and waits for it: the same symbol swap, the same
    /// disabling, the same help. Two of them had grown their own copies, and their behaviour under
    /// a second click had already diverged.
    private func footerAction(
        _ symbol: String, running: Bool, help: LocalizedStringKey, act: @escaping () -> Void
    ) -> some View {
        // The *symbol* swaps while it runs; the name does not. "ellipsis" is what waiting looks like,
        // not what the control is called, and VoiceOver needs the latter.
        IconButton(
            title: help, symbol: running ? "ellipsis" : symbol, isEnabled: !running, action: act)
            .foregroundStyle(.secondary)
    }

    private var translateButton: some View {
        footerAction("character.bubble", running: translating != nil, help: "Translate this sentence") {
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
        footerAction("text.bubble", running: explaining != nil, help: "Explain this sentence") {
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
            title: "Copy the word and this sense",
            // The checkmark is what *was copied*, so it is the symbol and never the name.
            symbol: copied ? "checkmark" : "doc.on.doc",
            help: copyable == nil
                ? Text("No sense was identified, so there is nothing to copy")
                : Text("Copy the word and this sense"),
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
    private func pinButton(_ entry: DictionaryEntry) -> some View {
        let keep = card(for: entry).senseToKeep
        return IconButton(
            title: "Keep this sense as a note", symbol: "pin",
            help: keep == nil
                ? Text("No sense was identified, so there is nothing to keep")
                : Text("Keep this sense as a note"),
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
