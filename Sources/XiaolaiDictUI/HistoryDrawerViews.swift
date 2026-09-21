import XiaolaiDictCore
import SwiftUI

/// Lays cards out as a Notification Center style pile that fans into a list.
///
/// `progress` is the layout's `animatableData`, so SwiftUI interpolates the geometry itself. That
/// is why this is a `Layout` rather than a stack of `.offset` modifiers: `placeSubviews` is handed
/// the real measured height of every card, so the fanned positions are exact without a
/// `GeometryReader` round-trip. The arithmetic lives in `CardPile`, where it can be tested.
struct CardStackLayout: Layout {
    var progress: Double
    var pile: CardPile

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: pile.height(of: measure(subviews, width: width), progress: progress))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = measure(subviews, width: bounds.width)
        for index in subviews.indices {
            guard let placed = pile.placement(
                of: index, in: heights, width: bounds.width, progress: progress) else { continue }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placed.origin.x, y: bounds.minY + placed.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: placed.size.width, height: placed.size.height))
        }
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }
}

/// The panel's content. The window is already at its final docked rect; only this moves.
public struct HistoryDrawerRootView: View {
    @Bindable var model: HistoryDrawerModel

    public init(model: HistoryDrawerModel) {
        self.model = model
    }

    public var body: some View {
        // No geometry yet means the drawer has not been laid out for a display. Drawing nothing is
        // right: a guessed size would be a window the reader can see and cannot explain.
        if let geometry = model.geometry {
            let offset = model.revealed ? CGSize.zero : geometry.hiddenOffset
            ZStack(alignment: .topLeading) {
                HistoryDrawerSurface(model: model, geometry: geometry)
                    .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
                    .offset(
                        x: geometry.contentOrigin.x + offset.width,
                        y: geometry.contentOrigin.y + offset.height)
                    .opacity(model.revealed ? 1 : 0)
                    .animation(.easeOut(duration: Token.Motion.reveal), value: model.revealed)
            }
            .frame(
                width: geometry.windowRect.size.width, height: geometry.windowRect.size.height,
                alignment: .topLeading)
            .clipped()
            .ignoresSafeArea()
        }
    }
}

struct HistoryDrawerSurface: View {
    @Environment(\.scale) private var scale
    @Bindable var model: HistoryDrawerModel
    let geometry: DrawerGeometry

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(Token.Opacity.divider)
            contents
        }
        // Liquid Glass, not an `NSVisualEffectView`. The spike this drawer came from targets
        // macOS 14, where vibrancy was the platform's answer; on macOS 26 and later the material
        // is glass, and it brings its own edge treatment, so the hand-drawn border is gone with it.
        .glassEffect(.regular, in: shape)
        .shadow(color: .black.opacity(Token.Opacity.drawerShadow), radius: scale.shadow.drawerRadius)
    }

    /// The corners touching the screen edge stay square, the way system panels do. Which pair that
    /// is comes from the geometry, so the view does not re-derive it from the edge.
    private var shape: UnevenRoundedRectangle {
        let r = geometry.cornerRadius
        switch geometry.squareCorners {
        case .none:
            return UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: r,
                bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .trailing:
            return UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: r,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
        case .leading:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
        case .top:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: r,
                bottomTrailingRadius: r, topTrailingRadius: 0, style: .continuous)
        case .bottom:
            return UnevenRoundedRectangle(
                topLeadingRadius: r, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: r, style: .continuous)
        }
    }

    private var header: some View {
        HStack(spacing: scale.space.stack) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: scale.text.heading, weight: .medium))
                .foregroundStyle(.tint)
            Text("Read recently")
                .font(.system(size: scale.text.heading, weight: .semibold))
            Spacer(minLength: scale.space.stack)
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else if model.totalEntries > 0 {
                Text("^[\(model.totalEntries) word](inflect: true) · ^[\(model.days.count) day](inflect: true)")
                    .font(.system(size: scale.text.body))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(scale.space.pad)
    }

    @ViewBuilder
    private var contents: some View {
        if let problem = model.problem {
            notice(
                icon: "exclamationmark.triangle", title: "Your reading history is unavailable",
                detail: problem)
        } else if model.days.isEmpty && !model.isLoading {
            notice(
                icon: "book.closed", title: "Nothing read yet",
                detail: "Words you look up appear here, grouped by the day you met them.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.space.section) {
                    ForEach(model.days) { day in
                        if day.isPiled {
                            DayPileView(
                                day: day,
                                expanded: Binding(
                                    get: { model.isExpanded(day) },
                                    set: { model.setExpanded($0, for: day) }))
                        } else {
                            TodayView(day: day, model: model)
                        }
                    }
                }
                .padding(scale.space.pad)
            }
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    private func notice(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: scale.space.stack) {
            Image(systemName: icon)
                .font(.system(size: scale.text.icon))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: scale.text.strong, weight: .semibold))
            Text(detail)
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Today is never piled — it is the part the reader came to read.
/// A card the reader removed, for as long as they can still change their mind.
///
/// It stands in the card's place rather than collapsing it away, so the list does not jump under
/// the pointer at the moment the reader may be reaching back for it.
struct RemovedCardView: View {
    @Environment(\.scale) private var scale
    let entry: ReadingEntry
    let undo: () -> Void

    var body: some View {
        HStack(spacing: scale.space.inline) {
            Text("Removed “\(entry.lemma)”")
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: scale.space.inline)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .font(.system(size: scale.text.label, weight: .medium))
                .foregroundStyle(.tint)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Dashed and unfilled: the space a card used to occupy, not a card. A solid plate here
        // would read as a new kind of row rather than as an absence with a way back.
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.card, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(Token.Opacity.border),
                    style: StrokeStyle(lineWidth: Token.Stroke.hairline, dash: Token.Stroke.absent)))
        .accessibilityElement(children: .combine)
    }
}

struct TodayView: View {
    @Environment(\.scale) private var scale
    let day: ReadingDay
    /// Nil in the previews that show cards alone; removing needs somewhere to report to.
    var model: HistoryDrawerModel?

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            DayHeader(day: day, count: day.entries.count, isToday: true)
            VStack(spacing: scale.space.stack) {
                ForEach(day.entries) { entry in
                    if let model, model.removing.contains(entry.id) {
                        RemovedCardView(entry: entry) { model.keep(entry) }
                    } else {
                        ReadingCardView(
                            entry: entry, onRemove: model.map { m in { m.remove(entry) } })
                    }
                }
            }
        }
    }
}

/// An earlier day: a header and a pile of that day's cards, fanning open on a click.
struct DayPileView: View {
    let day: ReadingDay
    @Binding var expanded: Bool

    @Environment(\.scale) private var scale
    @State private var hovering = false

    /// The same pile the layout places with, so the number of cards built and the number of
    /// positions placed cannot drift apart.
    private var pile: CardPile { CardPile(scale) }

    private struct PiledCard: Identifiable {
        let entry: ReadingEntry
        let layer: CardLayer
        var id: Int { entry.id }
    }

    /// Which cards to build and how each is drawn. `zip` truncates to the layers, so a closed pile
    /// builds only the few that show — rendering fifty views to display three would cost fifty
    /// measurements in `placeSubviews` for nothing visible.
    private var cards: [PiledCard] {
        zip(day.entries, pile.layers(count: day.entries.count, expanded: expanded))
            .map { PiledCard(entry: $0, layer: $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            Button(action: toggle) {
                DayHeader(
                    day: day, count: day.entries.count, isToday: false,
                    trailing: expanded ? "Show Less" : "Show All")
            }
            .buttonStyle(.plain)

            CardStackLayout(progress: expanded ? 1 : 0, pile: pile) {
                // Reversed so the deepest card is drawn first and the newest sits on top.
                ForEach(cards.reversed()) { card in
                    ReadingCardView(entry: card.entry, layer: card.layer)
                }
            }
            // Piled, the whole pile is one target. Fanned out, clicks belong to the cards.
            .overlay { if !expanded { pileButton } }
            // A closed pile is one object, so it answers the pointer as one. The overlay swallows
            // the cards' own hover, so without this the pile was perfectly clickable and completely
            // inert under the cursor.
            .scaleEffect(hovering && !expanded ? Token.Motion.lift : 1, anchor: .top)
            .animation(.easeOut(duration: Token.Motion.hover), value: hovering)
        }
    }

    /// A `Button`, never an `onTapGesture`: a bare gesture is reachable by the mouse and by nothing
    /// else, so the pile was invisible to VoiceOver and to the keyboard while looking clickable.
    private var pileButton: some View {
        Button(action: toggle) {
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text("^[Show all \(day.entries.count) word](inflect: true)"))
    }

    private func toggle() {
        // The pointer is about to be over a fanned list rather than a pile, and the lift belongs to
        // the pile. Left set, it would scale the list the next time the pile closed.
        hovering = false
        withAnimation(.spring(
            response: Token.Motion.fanResponse,
            dampingFraction: Token.Motion.fanDamping)) { expanded.toggle() }
    }
}

private struct DayHeader: View {
    @Environment(\.scale) private var scale
    let day: ReadingDay
    let count: Int
    let isToday: Bool
    var trailing: String?

    var body: some View {
        HStack(spacing: scale.space.inline) {
            Text(title)
                .font(.system(size: scale.text.body, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: scale.text.small, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, scale.space.inline)
                .padding(.vertical, scale.space.tight)
                .background(Capsule().fill(isToday
                    ? Color.accentColor.opacity(Token.Opacity.countToday)
                    : Color.primary.opacity(Token.Opacity.count)))
                .foregroundStyle(isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Spacer(minLength: scale.space.inline)
            if let trailing {
                Text(trailing)
                    .font(.system(size: scale.text.label, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    /// The label is a classification; rendering it is the view's job, in the reader's own locale.
    private var title: String {
        switch day.label {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .weekday: return day.date.formatted(.dateTime.weekday(.wide))
        case .date: return day.date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// One lookup.
///
/// The word and **the reader's own sentence** — never a definition. A review surface that answers
/// the question destroys the retrieval that makes reviewing worth anything, which is the same rule
/// that keeps a gloss off `PriorEncounter`. `ReadingEntry` has nowhere to put one, so this is
/// enforced by the type rather than by the view remembering.
struct ReadingCardView: View {
    @Environment(\.scale) private var scale
    let entry: ReadingEntry
    /// Buried cards are drawn as a bare plate and nothing else — see `CardLayer`.
    var layer: CardLayer = .front
    /// Nil where removing is not offered — a buried card, or a preview of a card on its own.
    var onRemove: (() -> Void)?

    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    /// Per card, and deliberately not remembered. Revealing a meaning is an act the reader
    /// performs when they want it; a drawer that reopened with every answer already showing would
    /// be the C2 failure arrived at by a slower route.
    @State private var revealed = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: scale.radius.card, style: .continuous)
    }

    var body: some View {
        details
            // The content fades rather than leaving the hierarchy, so a buried card still measures
            // its real height and the fan does not jump when the pile opens.
            .opacity(layer.showsContent ? 1 : 0)
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
            .background(shape.fill(CardSurface.fill(
                for: scheme, hovering: hovering && layer.showsContent)))
            // The whole edge carries the word's colour — `strokeBorder`, never `stroke`, so all of
            // it lands inside the card. A stroke centres on its path and would hang half its width
            // over the edge: measured at x=85–90 against a fill that began at 91.
            .overlay(shape.strokeBorder(
                CardSurface.border(for: entry, layer: layer, in: scheme),
                lineWidth: Token.Stroke.hairline))
            // Grouped first, so the card casts one shadow rather than the plate and the border
            // each casting their own.
            .compositingGroup()
            .shadow(
                color: .black.opacity(Token.Opacity.cardShadow),
                radius: scale.shadow.cardRadius, y: scale.shadow.cardOffset)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Token.Motion.hover), value: hovering)
            .accessibilityElement(children: .combine)
            // A buried card is the same lookup as one the reader will see when the pile opens.
            // Read out twice, it would be two words rather than one shown two ways.
            .accessibilityHidden(!layer.showsContent)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            VStack(alignment: .leading, spacing: scale.space.inline) {
                headline
                // **The provenance rides the sentence's last line.** On a row of its own it was a
                // single 11 pt icon alone under a full-width card, and the card read as one that
                // had forgotten to finish. `lastTextBaseline` is what makes it land in the bottom
                // corner of the text rather than beside its first line — with a sentence that
                // wraps, aligning to the first line would leave the gap exactly where it was.
                if entry.cue != .none {
                    HStack(alignment: .lastTextBaseline, spacing: scale.space.inline) {
                        sentenceLine
                        Spacer(minLength: scale.space.inline)
                        footnote
                    }
                }
                if revealed, let gloss = entry.sense?.gloss { meaning(gloss) }
            }
            // No sentence to ride — a lookup with no context still has to say where it came from,
            // so there it keeps a row of its own.
            if entry.cue == .none {
                HStack(spacing: scale.space.inline) {
                    Spacer(minLength: 0)
                    footnote
                }
            }
        }
    }

    /// The word, what it was doing, which sense it was — and the two things the reader can do with
    /// it. The dictionary sits at the far end because it leaves the card; the rest belong to it.
    private var headline: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                Text(entry.lemma)
                    .font(.system(size: scale.text.strong, weight: .semibold))
                if entry.result != .found { missBadge }
                Spacer(minLength: scale.space.inline)
                // Revealed on hover: it is the one control here that destroys something, and a
                // row of cards each showing a trash can reads as a list of things to delete.
                if let onRemove, layer.showsContent {
                    removeButton(onRemove)
                        .opacity(hovering ? 1 : 0)
                        .accessibilityHidden(!hovering)
                }
                dictionaryButton
            }
            HStack(spacing: scale.space.inline) {
                if let partOfSpeech = PartOfSpeechLabel.reader(entry.partOfSpeech) {
                    Text(partOfSpeech)
                        .font(.system(size: scale.text.small).italic())
                        .foregroundStyle(.secondary)
                }
                speakButton
                if revealAvailable { revealButton }
                // The sense sits at the far end: it is the one thing on the line that is a label
                // rather than something to do, and the two buttons belong beside the word they act on.
                Spacer(minLength: scale.space.inline)
                if let sense = entry.sense { senseMark(sense) }
            }
        }
    }

    /// **Which** sense, never what it says. A sense the selector proposed is drawn as the
    /// hypothesis it is — the reader has to be able to tell a guess from their own tap, and a
    /// marker that looked the same either way would be the ledger's distinction thrown away at
    /// the last step.
    ///
    /// Three standings, not two. This drew every unconfirmed sense as a guess, so an entry where
    /// no sense was settled at all read "9 senses?" and "the sense XiaolaiDict guessed" — a claim the
    /// ledger never made. The badge and its words now come from `SenseStanding`, the same source
    /// the lookup card draws from, so one lookup cannot be described two ways.
    private func senseMark(_ sense: SenseNote) -> some View {
        let standing = sense.standing
        return Text(sense.badge)
            .font(.system(size: scale.text.micro, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, scale.space.inline)
            .padding(.vertical, scale.space.tight)
            .background(Capsule().fill(Color.primary.opacity(Token.Opacity.count)))
            .foregroundStyle(standing.isConfirmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .help(Text(standing.explanation))
    }

    private var revealAvailable: Bool { entry.sense?.canReveal == true }

    private var revealButton: some View {
        Button {
            withAnimation(.easeOut(duration: Token.Motion.hover)) { revealed.toggle() }
        } label: {
            Label(
                revealed ? "Hide meaning" : "Reveal meaning",
                systemImage: revealed ? "eye.slash" : "eye")
                .labelStyle(.iconOnly)
                .font(.system(size: scale.text.small))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(revealed ? Text("Hide the meaning") : Text("Reveal the meaning"))
    }

    private var speakButton: some View {
        Button { Speech.say(entry.surface) } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: scale.text.small))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(Text("Say it aloud"))
    }

    /// No confirmation dialog. The reason a reader reaches for this is a word they did not mean
    /// to look up — noticed at once, worth nothing — so a dialog would put friction on the common
    /// case and still not catch a misclick. The undo row that replaces the card catches that.
    private func removeButton(_ remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            Image(systemName: "trash").font(.system(size: scale.text.small))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(Text("Remove from history"))
    }

    private var dictionaryButton: some View {
        Button { SystemDictionary.open(entry.lemma) } label: {
            Image(systemName: "character.book.closed")
                .font(.system(size: scale.text.small))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(Text("Open in Dictionary"))
    }

    /// The sentence, whole when it fits the card's lines and cut to a window around the word when
    /// it does not — the first that fits, chosen at the card's width. Where a window cut the start
    /// off, the whole sentence is one hover away: it is still the reader's own, and never a gloss.
    private var sentenceLine: some View {
        SentenceWindowText(
            windows: SentenceExcerpt.windows(sentence: entry.sentence, marks: entry.markedRanges),
            fullSentence: entry.sentence,
            style: sentence(in:))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Shown only because the reader asked. Set apart from the sentence so it cannot be mistaken
    /// for it — the sentence is theirs, this is the dictionary's.
    private func meaning(_ gloss: String) -> some View {
        Text(gloss)
            .font(.system(size: scale.text.small))
            .foregroundStyle(.secondary)
            .lineSpacing(scale.text.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, scale.space.inline)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(Token.Opacity.border))
                    .frame(width: Token.Stroke.hairline)
            }
            .transition(.opacity)
    }

    /// Where it was read, and — only if the reader asked for it — when. It is provenance: true,
    /// and never the thing being reviewed, so it sits at the trailing edge of whatever row it is
    /// given. **The caller places it**, because where that is depends on whether there is a
    /// sentence for it to ride.
    private var footnote: some View {
        HStack(spacing: scale.space.inline) {
            if let icon = AppIcons.icon(for: entry.place.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: scale.text.small, height: scale.text.small)
                    // Named even when the name is hidden: the icon is the only thing saying where
                    // this was read, and a reader who cannot see it is owed the same fact.
                    .accessibilityLabel(Text(place ?? ""))
                    .help(Text(place ?? ""))
            }
            if options.showsPlaceName, let where_ = place {
                Text(where_)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if options.showsTime {
                Text(entry.at.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: scale.text.small))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A miss is recorded on purpose, and shown as one. It is usually a typo or a stray selection,
    /// and telling that from a real gap is the point.
    private var missBadge: some View {
        Text("not found")
            .font(.system(size: scale.text.micro, weight: .medium))
            .padding(.horizontal, scale.space.inline)
            .padding(.vertical, scale.space.tight)
            .background(Capsule().fill(Color.secondary.opacity(Token.Opacity.missBadge)))
            .foregroundStyle(.secondary)
    }

    /// The sentence with the word the reader looked up picked out, so the card reads as the cue it
    /// is rather than as a line of prose — and, where the capture ran out before the sentence did,
    /// an ellipsis saying so rather than an ending the reader never read.
    private func sentence(in window: SentenceExcerpt) -> AttributedString {
        // `markedRanges`, never `sentenceRange`: the captured range covers the surface as it was
        // found, so emphasising it drew **temper**ed — the word broken in half — and a phrasal
        // verb read as "took it over" needs two marks rather than one span over the pronoun.
        // How a marked word *looks* is `MarkedSentence`'s, shared with the lookup card.
        //
        // **A window that contains the word, never the sentence's opening.** The line limit cuts
        // from the end, so a long sentence with its word late showed two lines of the reader's
        // text without the word they looked up. `SentenceWindowText` shows the tightest window it
        // needs to, and no tighter.
        var text = MarkedSentence.text(
            window.text, marking: window.marks, size: scale.text.body,
            emphasis: options.emphasis,
            accent: ReadingPalette.accent(for: entry)?.color(in: scheme) ?? .primary)
        if entry.cue == .truncatedSentence { text.append(AttributedString("…")) }
        return text
    }

    /// Where it was read, as precisely as the ledger knows — the page or document title where there
    /// is one, otherwise the app.
    private var place: String? {
        if let label = entry.place.label { return label }
        return entry.place.name
    }
}


// MARK: - Previews

// Sample data, so the drawer can be looked at and changed in Xcode's canvas without launching
// XiaolaiDict, reading a ledger or docking a window. `#if DEBUG` because a preview is a development
// tool and has no business in the bundle a reader installs.
#if DEBUG
private extension ReadingEntry {
    /// One card's worth, with the word marked in its sentence the way a real one arrives.
    ///
    /// `context` is not decoration here: a sample that always passes `.complete` would make every
    /// preview card look like the best case, which is the one case that never needed checking.
    static func sample(
        _ lemma: String, _ sentence: String, place: String = "Safari",
        result: LookupResult = .found, context: CaptureQuality.Context = .complete,
        partOfSpeech: String? = nil, sense: SenseNote? = nil,
        minutesAgo: Int = 0, id: Int
    ) -> ReadingEntry {
        let range = (sentence as NSString).range(of: lemma)
        return ReadingEntry(
            id: id, lemma: lemma, surface: lemma, sentence: sentence,
            sentenceRange: range.location == NSNotFound ? nil : range,
            place: ReadingPlace(
                bundleID: place == "Safari" ? "com.apple.Safari" : "com.apple.Terminal",
                name: place, title: place == "Safari" ? "A page" : nil),
            at: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)), result: result,
            quality: .accessibility(.accessibilityTextRange, context: context),
            partOfSpeech: partOfSpeech, sense: sense)
    }
}

private let sampleDays: [ReadingDay] = [
    ReadingDay(id: "2026-09-20", date: .now, label: .today, entries: [
        .sample(
            "ephemeral", "The ephemeral beauty of morning frost.", partOfSpeech: "adjective",
            sense: SenseNote(
                dictionary: "NOAD", ordinal: 1, outOf: 2,
                gloss: "lasting for a very short time", chosenBy: .reader),
            minutesAgo: 4, id: 1),
        // The selector's guess, drawn as the hypothesis it is rather than as the reader's own.
        .sample(
            "hold", "The ship's hold was full.", place: "Ghostty", partOfSpeech: "noun",
            sense: SenseNote(
                dictionary: "NOAD", ordinal: 3, outOf: 21,
                gloss: "a large compartment in the lower part of a ship", chosenBy: .model),
            minutesAgo: 30, id: 2),
        // The app could read no text around the selection, so the ledger stored the selection
        // itself. The card shows the word once and says nothing it cannot back up.
        .sample(
            "qqqq", "qqqq", place: "Ghostty", result: .notFound, context: .missing,
            minutesAgo: 44, id: 3),
        // Captured up to the edge of what could be read. Shown, and shown to be incomplete.
        .sample(
            "ballast", "in ballast and rode high in the", place: "Preview",
            context: .mayBeCut, minutesAgo: 51, id: 4),
    ]),
    ReadingDay(id: "2026-09-19", date: .now.addingTimeInterval(-86400), label: .yesterday, entries: [
        .sample(
            "temper", "Justice tempered with mercy.", partOfSpeech: "verb",
            sense: SenseNote(
                dictionary: "NOAD", ordinal: 4, outOf: 12,
                gloss: "serve as a neutralizing or counterbalancing force to", chosenBy: .reader),
            minutesAgo: 1500, id: 5),
        .sample("rein", "He kept a tight rein on the budget.", place: "TextEdit", minutesAgo: 1600, id: 6),
        .sample("sanction", "The sanctions were lifted.", minutesAgo: 1700, id: 7),
        .sample("table", "They tabled the motion.", place: "TextEdit", minutesAgo: 1800, id: 8),
    ]),
]

@MainActor private func sampleModel() -> HistoryDrawerModel {
    let model = HistoryDrawerModel()
    model.geometry = DrawerGeometry.make(
        DrawerLayout(thickness: 380, edge: .right),
        on: ScreenMetrics(
            frame: UpRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: UpRect(x: 0, y: 0, width: 1440, height: 870)))
    model.days = sampleDays
    model.revealed = true
    return model
}

/// The cards on their own — the fastest loop for their colour, spacing and marked word.
#Preview("Cards") {
    VStack(spacing: 8) {
        ForEach(sampleDays[0].entries + sampleDays[1].entries.prefix(2)) { entry in
            ReadingCardView(entry: entry)
        }
    }
    .padding(12)
    .frame(width: 380)
    .background(.background)
}

/// The same cards dark. The accent carries a second shade for exactly this, and the card's surface
/// is opaque in both — checking one appearance would only ever prove half of it.
#Preview("Cards, dark") {
    VStack(spacing: 8) {
        ForEach(sampleDays[0].entries + sampleDays[1].entries.prefix(2)) { entry in
            ReadingCardView(entry: entry)
        }
    }
    .padding(12)
    .frame(width: 380)
    .background(.background)
    .preferredColorScheme(.dark)
}

/// A day's pile, both ways, since the fanned and piled states look nothing alike.
#Preview("Pile, closed") {
    DayPileView(day: sampleDays[1], expanded: .constant(false))
        .padding(12).frame(width: 380).background(.background)
}

#Preview("Pile, fanned") {
    DayPileView(day: sampleDays[1], expanded: .constant(true))
        .padding(12).frame(width: 380).background(.background)
}

/// The whole drawer, glass and all. The glass reads as grey here — a preview has no wallpaper
/// behind it to refract, so judge the material in the running app, not in the canvas.
#Preview("Drawer") {
    HistoryDrawerSurface(model: sampleModel(), geometry: sampleModel().geometry!)
        .frame(width: 380, height: 700)
}

#Preview("Drawer, nothing read yet") {
    let empty = HistoryDrawerModel()
    empty.geometry = sampleModel().geometry
    return HistoryDrawerSurface(model: empty, geometry: empty.geometry!)
        .frame(width: 380, height: 420)
}
#endif
