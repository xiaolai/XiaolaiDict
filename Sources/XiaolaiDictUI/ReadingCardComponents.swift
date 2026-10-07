import Capture
import Foundation
import StudyKit
import SwiftUI
import XiaolaiDictCore

/// Shared paper, edge and lift. Callers retain their own content and pile sizing.
///
/// `accent` is the edge as it is to be drawn — from `CardSurface.border(…contrast:)`, which is
/// where Increase Contrast is answered, so this does not dilute it a second time.
struct ReadingCardChrome: ViewModifier {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    let accent: Color
    var hovering = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: scale.radius.card, style: .continuous)
        content
            .background(shape.fill(CardSurface.fill(for: scheme, hovering: hovering)))
            .overlay(shape.strokeBorder(accent, lineWidth: Token.Stroke.hairline))
            .compositingGroup()
            .shadow(color: .black.opacity(Token.Opacity.cardShadow), radius: scale.shadow.cardRadius, y: scale.shadow.cardOffset)
            .contentShape(shape)
    }
}

struct ReadingPronunciation: View {
    @Environment(\.scale) private var scale
    let word: String
    let sentence: String
    var help: Text? = nil
    var say: (() -> Void)? = nil
    var body: some View {
        // **The tooltip is the voice's caveat where there is one, and the button's name where
        // there is not.** It used to be handed "Say it aloud" as its help, which VoiceOver then
        // read after the name — the same words twice.
        IconButton(.sayAloud, help: help ?? Speech.caveat(forSpeaking: word, in: sentence).map { Text(verbatim: $0) },
                   size: scale.text.small) {
            if let say { say() } else { Speech.say(word, in: sentence) }
        }
        // Secondary, not tertiary: it is an enabled control, and tertiary is the colour of one
        // that is not (measured about 2.1:1 on a white card, 2026-10-01).
        .foregroundStyle(.secondary)
    }
}

struct ReadingSentence: View {
    @Environment(\.scale) private var scale
    let sentence: String
    let ranges: [NSRange]
    let accent: Color
    var emphasis: WordEmphasis = CardOptions().emphasis
    var truncated = false
    var body: some View {
        SentenceWindowText(windows: SentenceExcerpt.windows(sentence: sentence, marks: ranges),
                           fullSentence: sentence, style: styled)
            // **Primary.** The reader's own sentence is the card's content, and it was drawn in
            // the secondary label colour: 2.85:1 at 12 pt on a white card, measured 2026-10-01.
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func styled(_ window: SentenceExcerpt) -> AttributedString {
        var text = MarkedSentence.text(window.text, marking: window.marks, size: scale.text.body,
                                       emphasis: emphasis, accent: accent)
        if truncated { text.append(AttributedString("…")) }
        return text
    }
}

/// **The capsule both of a card's small marks wear** — the repeat count beside the word and the
/// sense badge at the end of the line.
///
/// One shape, because they were two copies of the same six modifiers and a change to the padding
/// or the wash would have had to be made twice or drift. What stays separate is everything that
/// says what each one *is*: the colour, the help text and the accessibility label. They are the
/// same furniture carrying different facts, not the same badge.
struct BadgeCapsule: ViewModifier {
    let scale: Scale

    func body(content: Content) -> some View {
        content
            .font(.system(size: scale.text.micro, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, scale.space.inline)
            .padding(.vertical, scale.space.tight)
            .background(Capsule().fill(Color.primary.opacity(Token.Opacity.count)))
    }
}

/// Where a reading card is being shown, for the one thing that differs between the two places.
enum ReadingCardDensity: Sendable {
    /// In the Reading History panel, under a day's heading: the day is already said.
    case drawer
    /// In the Library's grid or list, where nothing above the card dates it: the card says when.
    case library
}

/// What a reading card can do beyond what every card can — speak, show its meaning, open the
/// Dictionary. Each is offered only where its handler is given, as an icon on the card **and** as
/// a row of its context menu, from this one value.
struct ReadingCardActions {
    /// Put the reading away, reversibly. Not offered where `restore` is.
    var discard: (() -> Void)?
    /// Bring a discarded reading back. Given, it replaces Discard.
    var restore: (() -> Void)?
    /// Save this meaning for study. Not offered for a reading that is already saved, which shows
    /// the saved mark instead.
    var save: (() -> Void)?
    /// Open this reading in the Library.
    var showInLibrary: (() -> Void)?
}

/// One reading: **the same card wherever a reading is shown.**
///
/// The Reading History panel and the Library each drew their own, and measured 2026-10-01 they
/// disagreed on fourteen points about one record — the lemma in black here and the surface form
/// in the word's colour there, a count chip on one, the part of speech on one, an icon button for
/// an action the other spelled out in words. A reader had to learn the same reading twice, and
/// `meet` on one surface beside `meeting` on the other read as two words.
///
/// What a reading looks like, decided once:
///
/// - the headword is **the form the reader met**, in the lemma's colour, with "×N" beside it
///   where it was met more than once;
/// - the part of speech, and the sense badge at the far end of the same line — a proposed sense
///   is told from a confirmed one by its "?", not by being dimmer;
/// - the reader's sentence in the primary colour, the word marked the way they chose in Settings;
/// - a last row: where it was read at the leading end, and every action at the trailing end, each
///   with the symbol, name and role `ActionSymbol` gives it. The same actions are the card's
///   context menu.
///
/// The word and **the reader's own sentence** — never a definition unless they ask. A review
/// surface that answers the question destroys the retrieval that makes reviewing worth anything,
/// so the meaning is absent from the layout until it is revealed, and `revealed` is not kept.
struct ReadingCardView: View {
    let entry: ReadingEntry
    var density: ReadingCardDensity = .drawer
    /// Buried cards are drawn as a bare plate and nothing else — see `CardLayer`.
    var layer: CardLayer = .front
    var actions = ReadingCardActions()

    @Environment(\.scale) private var scale
    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// Per card, and deliberately not remembered. Revealing a meaning is an act the reader
    /// performs when they want it; a drawer that reopened with every answer already showing would
    /// be the C2 failure arrived at by a slower route.
    @State private var revealed = false

    var body: some View {
        details
            // The content fades rather than leaving the hierarchy, so a buried card still measures
            // its real height and the fan does not jump when the pile opens.
            .opacity(layer.showsContent ? 1 : 0)
            // **And it cannot be clicked or tabbed to.** A buried plate sits a peek lower than the
            // card in front, so the last row of its invisible content — the actions — lies in the
            // sliver that shows. Now that a closed pile lets clicks through to its front card,
            // that sliver would have been six unseen buttons.
            .allowsHitTesting(layer.showsContent)
            .disabled(!layer.showsContent)
            .padding(scale.space.pad)
            // **A buried card takes the height the layout gives it.** `CardPile` places every
            // plate at the front card's height so the slivers peeking below line up evenly — but
            // a proposed height is only a proposal, and this view had no height constraint, so
            // each plate sized itself to its own content and poked out by however tall its own
            // word happened to make it. Measured in the closed pile: the first plate peeked 2.5 pt
            // and the second 7.5 pt, against a design that says both are `peek`. The arithmetic
            // was right the whole time and `CardPileTests` passed the whole time; nothing checked
            // that the view honoured it.
            //
            // **Both bounds, never just the upper one.** SwiftUI's frame rule: with only a maximum,
            // a frame grows to a larger proposal but keeps its child's size when the proposal is
            // smaller — so a plate could stretch up to the front card's height and never shrink to
            // it. That passed a test whose front card was the tallest, and on screen, with a
            // one-line "beauty" in front of two-line cards, the first plate peeked 25 pt against
            // 7.5. With a minimum as well, the frame "unconditionally adopts the size proposed for
            // it": the front card's height, in both directions. What overflows is the buried
            // card's own content, which is already invisible.
            //
            // Only when buried. A front card is proposed its own height and must never stretch to
            // fill whatever frame it happens to be put in — a preview or a test hands it a tall
            // one, and a card that grew to fill it would be measuring the container.
            .frame(
                maxWidth: .infinity,
                minHeight: layer == .buried ? 0 : nil,
                maxHeight: layer == .buried ? .infinity : nil,
                alignment: .topLeading)
            // Opaque, and deliberately not another material: the drawer around it is already
            // glass, and layering glass inside glass muddies both.
            .modifier(ReadingCardChrome(
                accent: CardSurface.border(for: entry, layer: layer, in: scheme, contrast: contrast),
                hovering: hovering && layer.showsContent))
            .onHover { hovering = $0 }
            .motionAwareAnimation(.easeOut(duration: Token.Motion.hover), value: hovering)
            // Everything the icons do, by name — for the reader who does not know the icons, and
            // for the keyboard, which reaches a context menu where it cannot reach a hover.
            .contextMenu { if layer.showsContent { menu } }
            .accessibilityElement(children: .combine)
            // A buried card is the same lookup as one the reader will see when the pile opens.
            // Read out twice, it would be two words rather than one shown two ways.
            .accessibilityHidden(!layer.showsContent)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            VStack(alignment: .leading, spacing: scale.space.inline) {
                headline
                if entry.cue != .none { sentenceLine }
                if revealed, let gloss = entry.sense?.gloss { meaning(gloss) }
            }
            actionRow
        }
    }

    /// The word's own colour: its lemma's, so `meet` and `meeting` are one colour on every
    /// surface, and the miss grey where nothing was found.
    private var accent: Color { ReadingPalette.color(for: entry, in: scheme, contrast: contrast) }

    /// The form the reader met. The lemma only where the ledger kept no surface form.
    private var headword: String { entry.surface.isEmpty ? entry.lemma : entry.surface }

    /// The word and how often; then what it was doing and which sense it was.
    private var headline: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                Text(verbatim: headword)
                    .font(.system(size: scale.text.strong, weight: .semibold))
                    .foregroundStyle(accent)
                if entry.times > 1 { timesRead }
                if entry.result == .notFound { missBadge }
                Spacer(minLength: scale.space.inline)
                // Only where nothing above the card says the day.
                if density == .library {
                    // The hour for a reading made today, the date for an older one.
                    Group {
                        if ArchiveCardDate.showsTime(entry.at, now: .now, calendar: .current) {
                            Text(entry.at, format: .dateTime.hour().minute())
                        } else {
                            Text(entry.at, format: .dateTime.month().day())
                        }
                    }
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
            }
            let partOfSpeech = PartOfSpeechLabel.reader(entry.partOfSpeech)
            let badge = CardBadge(of: entry)
            if partOfSpeech != nil || badge != nil {
                HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                    if let partOfSpeech {
                        Text(partOfSpeech)
                            .font(.system(size: scale.text.small).italic())
                            .foregroundStyle(.secondary)
                    }
                    // The sense sits at the far end: it is about the entry, where the part of
                    // speech is about the word.
                    Spacer(minLength: scale.space.inline)
                    if let badge { mark(badge) }
                }
            }
        }
    }

    /// **Which** sense, never what it says. A sense the selector proposed is drawn as the
    /// hypothesis it is — the reader has to be able to tell a guess from their own tap. What the
    /// badge says is `CardBadge`'s to decide, once, and that is where the difference lives: a
    /// proposed sense ends in "?". It used to be dimmer as well, in the tertiary colour — which is
    /// the colour of a disabled control, and measured 2.37:1 in small type.
    private func mark(_ badge: CardBadge) -> some View {
        Text(badge.text)
            .modifier(BadgeCapsule(scale: scale))
            .foregroundStyle(.secondary)
            .help(Text(badge.explanation))
            // The explanation was a tooltip and nothing else, so only a pointer could have it.
            .accessibilityHint(Text(badge.explanation))
    }

    // MARK: - Actions

    private var revealAvailable: Bool { entry.sense?.canReveal == true }

    private func toggleReveal() {
        withAnimation(MotionPreference.animation(
            .easeOut(duration: Token.Motion.hover), reduceMotion: reduceMotion)) { revealed.toggle() }
    }

    private func openInDictionary() { SystemDictionary.open(entry.lemma) }

    /// Where it was read, then everything that can be done — as icons, in one order on every
    /// surface: the three that only look, then the three that change something, Discard last and
    /// always in the same corner.
    ///
    /// **Discard is always there.** It appeared on hover and was hidden from assistive technology
    /// whenever the pointer was elsewhere — so for VoiceOver and the keyboard it did not exist.
    /// It is no longer a trash can a row of cards would read as a list of things to delete: the
    /// symbol is Discard's own, and the action can be undone.
    private var actionRow: some View {
        HStack(spacing: 0) {
            footnote
            Spacer(minLength: scale.space.inline)
            ReadingPronunciation(word: entry.surface, sentence: entry.sentence)
            if revealAvailable {
                IconButton(revealed ? .hideMeaning : .showMeaning, size: scale.text.small, action: toggleReveal)
            }
            IconButton(.openInDictionary, size: scale.text.small, action: openInDictionary)
            if entry.studyNoteID != nil {
                savedMark
            } else if let save = actions.save {
                IconButton(.saveMeaning, size: scale.text.small, action: save)
            }
            if let show = actions.showInLibrary {
                IconButton(.showInLibrary, size: scale.text.small, action: show)
            }
            if let restore = actions.restore {
                IconButton(.restoreReading, size: scale.text.small, action: restore)
                    .accessibilityIdentifier("restore-reading-\(entry.id)")
            } else if let discard = actions.discard {
                IconButton(.discardReading, size: scale.text.small, action: discard)
                    .accessibilityIdentifier("discard-reading-\(entry.id)")
            }
        }
        // Secondary: enabled controls, and provenance that is meant to be read.
        .foregroundStyle(.secondary)
    }

    /// A state, not a button: this meaning is already saved, so there is nothing to press.
    private var savedMark: some View {
        ActionSymbol.savedState.image
            .font(.system(size: scale.text.small))
            .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
            .help(Text(ActionSymbol.savedState.title))
            .accessibilityLabel(Text(ActionSymbol.savedState.title))
    }

    /// The card's actions as a menu: the same handlers under their names.
    @ViewBuilder
    private var menu: some View {
        Group {
            IconButton(.sayAloud) { Speech.say(entry.surface, in: entry.sentence) }
            if revealAvailable {
                IconButton(revealed ? .hideMeaning : .showMeaning, action: toggleReveal)
            }
            IconButton(.openInDictionary, action: openInDictionary)
            if entry.studyNoteID == nil, let save = actions.save {
                IconButton(.saveMeaning, action: save)
            }
            if let show = actions.showInLibrary {
                IconButton(.showInLibrary, action: show)
            }
            if let restore = actions.restore {
                Divider()
                IconButton(.restoreReading, action: restore)
            } else if let discard = actions.discard {
                Divider()
                IconButton(.discardReading, action: discard)
            }
        }
        .environment(\.iconButtonShowsTitle, true)
    }

    // MARK: - Content

    /// The sentence, whole when it fits the card's lines and cut to a window around the word when
    /// it does not — the first that fits, chosen at the card's width. Where a window cut the start
    /// off, the whole sentence is one hover away: it is still the reader's own, and never a gloss.
    private var sentenceLine: some View {
        ReadingSentence(sentence: entry.sentence, ranges: entry.markedRanges, accent: accent,
                        emphasis: options.emphasis, truncated: entry.cue == .truncatedSentence)
    }

    /// Shown only because the reader asked. Set apart from the sentence so it cannot be mistaken
    /// for it — the sentence is theirs, this is the dictionary's.
    private func meaning(_ gloss: String) -> some View {
        Text(gloss)
            .font(.system(size: scale.text.small))
            .foregroundStyle(.secondary)
            .lineSpacing(scale.text.leading)
            .fixedSize(horizontal: false, vertical: true)
            .setApart()
            .transition(.opacity)
    }

    /// Where it was read, and — only if the reader asked for it — when. Provenance: true, and
    /// never the thing being reviewed, so it leads the row of actions rather than taking a row of
    /// its own. It used to ride the sentence's last line; the actions' row is there on every card,
    /// with or without a sentence, so one place serves both.
    private var footnote: some View {
        HStack(spacing: scale.space.inline) {
            if let icon = AppIcons.icon(for: entry.place.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: scale.space.sourceIcon, height: scale.space.sourceIcon)
                    // Named even when the name is hidden: the icon is the only thing saying where
                    // this was read, and a reader who cannot see it is owed the same fact.
                    .accessibilityLabel(Text(verbatim: place ?? ""))
                    .help(Text(verbatim: place ?? ""))
            }
            // **Named in the Library, whatever the setting.** A card there has the room, and an icon
            // alone does not always say where: TextEdit's is a white page, which at this size on a
            // white card reads as a blank placeholder (seen 2026-10-02).
            if options.showsPlaceName || density == .library, let place {
                Text(verbatim: place)
                    .font(.system(size: scale.text.small))
                    .lineLimit(1)
                    // One line, so a long page title is cut — and then the whole of it is here.
                    .help(Text(verbatim: place))
            }
            if options.showsTime {
                Text(entry.at.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: scale.text.small))
                    .monospacedDigit()
            }
        }
    }

    /// **How often this reading was met**, shown only when that is more than once.
    ///
    /// Beside the word rather than at the end of the line, because it is about the word: the far
    /// end is the sense badge, which is about the entry. A numeral and a multiplication sign are
    /// not prose and compose the same way in every language this ships in, so the mark is
    /// `verbatim` and the sentence goes in the help and the accessibility label — where it can be
    /// a sentence.
    private var timesRead: some View {
        Text(verbatim: "×\(entry.times)")
            .modifier(BadgeCapsule(scale: scale))
            .foregroundStyle(.secondary)
            // **The sentence is only claimed where there is one.** A reading with no captured
            // context draws no sentence at all, and saying "in this same sentence" over a card
            // that shows none is a claim about text the reader was never shown.
            .help(entry.cue == .none
                  ? Text("Read ^[\(entry.times) time](inflect: true)")
                  : Text("Read ^[\(entry.times) time](inflect: true), in this same sentence"))
            .accessibilityLabel(Text("Read ^[\(entry.times) time](inflect: true)"))
    }

    /// A miss is recorded on purpose, and shown as one. It is usually a typo or a stray selection,
    /// and telling that from a real gap is the point.
    private var missBadge: some View {
        Text("Not found")
            .font(.system(size: scale.text.micro, weight: .medium))
            .padding(.horizontal, scale.space.inline)
            .padding(.vertical, scale.space.tight)
            .background(Capsule().fill(Color.secondary.opacity(Token.Opacity.missBadge)))
            .foregroundStyle(.secondary)
    }

    /// Where it was read, as precisely as the ledger knows — the page or document title where there
    /// is one, otherwise the app.
    private var place: String? {
        if let label = entry.place.label { return label }
        return entry.place.name
    }
}
