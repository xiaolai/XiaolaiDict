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
    @State private var showingAlternatives = false
    /// Open from the start where XiaolaiDict has admitted it cannot tell — see `opensAlternatives`.
    @State private var openedOnce = false
    @State private var showingMemory = false

    public init(card: LookupCard, onChoose: ((SensePresentation) -> Void)? = nil) {
        self.card = card
        self.onChoose = onChoose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            heading
            memoryDetail
            answer
            if let sentence = card.sentence, !sentence.isEmpty { evidence(sentence) }
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
            action("speaker.wave.2", help: "Say it aloud") { Speech.say(card.term) }
            action("character.book.closed", help: "Open in Dictionary") {
                SystemDictionary.open(card.term)
            }
        }
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
                ForEach(memory.lines, id: \.self) { line in
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

    private func action(_ symbol: String, help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: scale.text.body))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text(help))
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
                ambiguousBadge(among: among)
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
                .lineLimit(Token.Limit.proseLines)
                .fixedSize(horizontal: false, vertical: true)
        case .absent:
            Text("No entry for “\(card.term)” in your dictionaries.")
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The evidence

    /// The reader's own sentence, and how much XiaolaiDict is claiming. Together these are what let a
    /// wrong answer be spotted: the claim sits directly above the text it was made from.
    private func evidence(_ sentence: String) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text(marked(sentence))
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .lineSpacing(scale.text.leading)
                .fixedSize(horizontal: false, vertical: true)
            standing
        }
        .padding(.leading, scale.space.inline)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(Token.Opacity.border))
                .frame(width: Token.Stroke.hairline)
        }
    }

    /// Said plainly. "XiaolaiDict's guess" and "you chose this" are different claims and the reader is
    /// entitled to know which one they are looking at before they believe it.
    @ViewBuilder
    private var standing: some View {
        if case .sense(let sense) = card.answer {
            // The ambiguous card says so in its own badge; repeating it here would be the same
            // admission twice on one card.
            Text(sense.standing.explanation)
                .font(.system(size: scale.text.small))
                .foregroundStyle(card.isHypothesis ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
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
        MarkedSentence.text(
            sentence,
            marking: Lemmatizer.parts(
                of: card.term, surface: card.term, in: sentence,
                at: (sentence as NSString).range(of: card.term, options: .caseInsensitive)),
            size: scale.text.body, emphasis: options.emphasis, accent: accent)
    }

    /// The word's own colour, the same one the history card will give it — the hash is stable, so
    /// a word met in the panel and later seen in the drawer is the same colour both times.
    private var accent: Color {
        ReadingPalette.accent(for: card.term).color(in: scheme)
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
            .onAppear {
                guard !openedOnce else { return }
                openedOnce = true
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
    @Environment(\.translation) private var translator
    @Environment(\.explainer) private var explainer
    @Environment(\.colorScheme) private var scheme
    public let presentation: LookupPresentation
    /// What it is waiting for, in words. Nil once the dictionaries have answered.
    public let waiting: String?
    /// Which dictionary's entry the card is showing. The primary's is first, and switching is the
    /// reader asking — which is what makes an auxiliary sense studiable under D8.
    @State private var showing = 0
    @State private var explanation: SentenceExplanation?
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
    /// **The sense the reader tapped, per entry.** `choose` used to write to the ledger and nothing
    /// else, so the card went on drawing the selector's proposal as its mark and — worse — a
    /// translation asked afterwards was still told the sense the reader had just rejected. A tap is
    /// a fact (`chosen_by: reader`); it replaces the hypothesis here as well as in the ledger.
    ///
    /// **Keyed by the entry it was made in**, because a sense key means nothing outside the
    /// dictionary that issued it: held as one value, a tap in an auxiliary entry became the primary
    /// entry's mark, and two dictionaries whose keys happen to collide could confirm the wrong
    /// sense outright — which copy, pin, translation and explanation would all then carry.
    @State private var chosen: [String: SenseMark] = [:]

    public init(presentation: LookupPresentation, waiting: String? = nil) {
        self.presentation = presentation
        self.waiting = waiting
    }

    /// The word's own colour, which the card's shadow is thrown in. The same accent the marked
    /// word in the sentence wears, so the glow under the card and the word inside it agree.
    private var accent: Color {
        ReadingPalette.accent(for: presentation.term).color(in: scheme)
    }

    private var entries: [DictionaryEntry] {
        guard case .entries(let found, _) = presentation.outcome else { return [] }
        return Array(found)
    }

    private var entry: DictionaryEntry? {
        entries.indices.contains(showing) ? entries[showing] : entries.first
    }

    public var body: some View {
        // No memory strip across the top any more — the count is a badge in the card's own
        // heading, where it is a fact rather than a remark.
        content
        .frame(
            minWidth: scale.space.cardMinWidth,
            idealWidth: scale.space.cardWidth,
            maxWidth: scale.space.cardMaxWidth,
            alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
            LookupCardView(card: absentCard)
        case .plainText(let text, _):
            LookupCardView(card: proseCard(text))
        case .entries(_, let unreadable):
            if let entry {
                VStack(alignment: .leading, spacing: scale.space.stack) {
                    if !unreadable.isEmpty {
                        // Named once however many of its records failed: claiming all of them, or
                        // only one, would both be guesses.
                        Notice(text: "An entry in \(unreadable.joined(separator: ", ")) could not be read, so what is shown is not all of it.")
                    }
                    LookupCardView(card: card(for: entry), onChoose: { choose($0, in: entry) })
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
                            if chosen[Self.identity(of: entry)] == nil { clearPanes() }
                        }
                    // Only beside the card it was made for. A different dictionary, or a sense that
                    // arrived after it was asked, is a different card.
                    if let translation, translation.of == translationKey(for: entry) {
                        TranslationPaneView(pane: translation)
                    }
                    if let explanation { SentencePaneView(explanation: explanation) }
                    footer(entry)
                }
            }
        }
    }

    private func card(for entry: DictionaryEntry) -> LookupCard {
        let mark = mark(for: entry)
        return LookupCard(
            presentation: EntryPresentation(entry: entry, mark: mark, met: presentation.met),
            term: presentation.term, sentence: presentation.sentence, mark: mark,
            memory: presentation.memory)
    }

    private var absentCard: LookupCard {
        LookupCard(
            term: presentation.term, heading: presentation.term, partOfSpeech: nil,
            pronunciation: nil, dictionary: "", answer: .absent,
            sentence: presentation.sentence, alternatives: [], memory: presentation.memory)
    }

    private func proseCard(_ text: String) -> LookupCard {
        LookupCard(
            term: presentation.term, heading: presentation.term, partOfSpeech: nil,
            pronunciation: nil, dictionary: "", answer: .prose(text),
            sentence: presentation.sentence, alternatives: [], memory: presentation.memory)
    }

    /// A tap on a sense is the reader's, and is recorded as theirs — the correction path for a
    /// guess, and under D8 the only way an auxiliary dictionary's sense becomes a study item.
    private func choose(_ sense: SensePresentation, in entry: DictionaryEntry) {
        guard let key = sense.key,
              let encounter = OutcomeView.encounter(from: entry, senseKey: key)
        else { return }
        studySense(encounter)
        chosen[Self.identity(of: entry)] = .chosen(key: key, by: .reader)
        clearPanes()
    }

    /// Which entry a tap belongs to: the dictionary that issued the sense, and the entry inside it.
    /// Both halves are needed — one dictionary answers a word with several entries, and a sense key
    /// is only meaningful inside the dictionary that issued it.
    private static func identity(of entry: DictionaryEntry) -> String {
        "\(entry.dictionary.key)\u{1}\(entry.entryKey ?? "")"
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
        chosen[Self.identity(of: entry)] ?? presentation.sense
    }

    // MARK: - The row under the card

    /// The actions that are about this lookup rather than about this word, and — where there is
    /// more than one — which dictionary answered.
    private func footer(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: scale.space.inline) {
            if entries.count > 1 { dictionaries }
            Spacer(minLength: scale.space.inline)
            if presentation.sentence?.isEmpty == false {
                translateButton
                explainButton
            }
            copyButton(entry)
            pinButton(entry)
        }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.bottom, scale.space.padDown)
    }

    /// One line where the sidebar was a column. The reader studies from one dictionary (D7); the
    /// others are here to be looked at, and looking is a click.
    private var dictionaries: some View {
        HStack(spacing: scale.space.line) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, found in
                Button { showing = index } label: {
                    Text(found.dictionary.name)
                        .font(.system(size: scale.text.micro, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, scale.space.inline)
                        .padding(.vertical, scale.space.tight)
                        .background(Capsule().fill(Color.primary.opacity(
                            index == showing ? Token.Opacity.countToday : Token.Opacity.count)))
                        .foregroundStyle(index == showing ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(Text(found.dictionary.name))
            }
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
        Button(action: act) {
            Image(systemName: running ? "ellipsis" : symbol)
                .font(.system(size: scale.text.body))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(running)
        .help(Text(help))
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
            let sense: String? = {
                guard let entry, case .sense(let shown) = card(for: entry).answer else { return nil }
                return shown.label
            }()
            let question = SentenceQuestion(
                sentence: presentation.sentence ?? "", term: presentation.term, senseText: sense)
            explaining?.cancel()
            let explain = explainer.explain
            explaining = Task {
                // **The downloaded model first.** Reaching for Apple's here would make the pane
                // work only for readers who have Apple Intelligence — which the LLM-pane decision
                // says it must not.
                let answer = await explain(question)
                guard !Task.isCancelled else { return }
                explanation = answer
                explaining = nil
            }
        }
    }

    private func copyButton(_ entry: DictionaryEntry) -> some View {
        Button {
            // The card as it is drawn — including a sense the reader tapped, which is the one
            // they mean to copy.
            let card = card(for: entry)
            if case .sense(let sense) = card.answer {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(card.heading) — \(sense.label)", forType: .string)
                copied = true
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: scale.text.body))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text("Copy the word and this sense"))
    }

    private func pinButton(_ entry: DictionaryEntry) -> some View {
        Button {
            let card = card(for: entry)
            guard case .sense(let sense) = card.answer else { return }
            pin(PinnedNote(
                term: presentation.term, heading: card.heading, dictionary: entry.dictionary,
                partOfSpeech: card.partOfSpeech, pronunciation: card.pronunciation,
                text: sense.label, senseKey: sense.key, pinnedAt: .now))
        } label: {
            Image(systemName: "pin").font(.system(size: scale.text.body))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text("Keep this sense as a note"))
    }
}
