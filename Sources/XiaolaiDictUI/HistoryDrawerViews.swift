import Capture
import CaptureModel
import DictionaryModel
import StudyKit
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: HistoryDrawerModel) {
        self.model = model
    }

    public var body: some View {
        // No geometry yet means the drawer has not been laid out for a display. Drawing nothing is
        // right: a guessed size would be a window the reader can see and cannot explain.
        if let geometry = model.geometry {
            let parked = model.revealed ? CGSize.zero : geometry.hiddenOffset
            ZStack(alignment: .topLeading) {
                HistoryDrawerSurface(model: model, geometry: geometry)
                    .frame(width: geometry.contentSize.width, height: geometry.contentSize.height)
                    // With Reduce Motion the panel does not travel: it is already in place, and
                    // only the opacity below changes.
                    .offset(
                        x: geometry.contentOrigin.x + MotionPreference.travel(parked.width, reduceMotion: reduceMotion),
                        y: geometry.contentOrigin.y + MotionPreference.travel(parked.height, reduceMotion: reduceMotion))
                    .opacity(model.revealed ? 1 : 0)
                // **No `.animation` here.** `revealed` is animated by whoever changes it — the
                // controller, with `DrawerMotion` — and an implicit animation on this view would
                // replace that one, which is what it did until 2026-10-02.
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
        contents
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // **A bar, not a header above a rule.** The list scrolls under it and the system's
            // scroll edge effect is what separates the two; the `Divider` that used to sit here
            // was a line drawn by hand where the platform draws its own.
            .safeAreaBar(edge: .top, spacing: 0) { header }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The list now reaches the top of the panel, so it is held to the panel's own shape.
            .clipShape(shape)
            // Liquid Glass, not an `NSVisualEffectView`. The spike this drawer came from targets
            // macOS 14, where vibrancy was the platform's answer; on macOS 26 and later the material
            // is glass, and it brings its own edge treatment and its own shadow — so there is no
            // hand-drawn border, and since 2026-10-02 no `.shadow` stacked on the system's either
            // (a 21.6 pt blur that showed as a grey band across the window beside the panel).
            //
            // **Regular, always.** This was the reader's choice between Frosted and Clear. Clear
            // put secondary text straight onto whatever was behind the panel, with no dimming
            // layer, and macOS 27 has its own control for how clear glass is; Reduce Transparency
            // and Increase Contrast are answered by the system's glass too. One material, and the
            // system's settings decide how it looks.
            .glassEffect(.regular, in: shape)
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

    /// The panel's name and how much it holds — and, under them, the way back from a discard.
    ///
    /// **The platform's own fonts, not the reader's text size.** This is the panel's chrome, the
    /// way a window's title is; the reader's size is for what they read, which is the cards.
    private var header: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            HStack(spacing: scale.space.stack) {
                ActionSymbol.historyPane.image
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Reading History")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: scale.space.stack)
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else if model.totalEntries > 0 {
                    // **Readings, the unit every day's count beside it is in — and a reading is
                    // one lookup**, as the Library's subtitle and a card's own "×N" already count.
                    // It said words once ("4 words · 3 days" over days counting 3, 5 and 1), then
                    // cards under the name readings, which put "10 readings" here over the
                    // Library's "72 readings" for one history. Now the cards add up to their day
                    // and the days to this.
                    Text("^[\(model.totalLookups) reading](inflect: true) · ^[\(model.days.count) day](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let receipt = model.discardedReceipt { undoRow(receipt) }
        }
        .padding(scale.space.pad)
    }

    /// **A row of its own.** Undo was a bordered button laid over the header's bottom padding,
    /// under the title, and it said "Undo discarding 1 readings". The count is beside the action
    /// and both inflect.
    private func undoRow(_ receipt: DispositionResult) -> some View {
        HStack(spacing: scale.space.inline) {
            Text("^[\(receipt.affected) reading](inflect: true) discarded")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: scale.space.inline)
            IconButton(.undo, title: "Undo Discarding ^[\(receipt.affected) Reading](inflect: true)") {
                model.undoLastDiscard()
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contents: some View {
        if let problem = model.problem {
            notice(
                icon: ActionSymbol.warning.image,
                title: String(localized: "Your reading history is unavailable",
                              comment: "Reading History notice when the reading history could not be read"),
                // Not localized on purpose: what follows is the failure the ledger reported, in
                // whatever words it reported it, and inventing a key for a value would leave the
                // translator a sentence nobody can translate.
                detail: problem)
        } else if model.days.isEmpty && !model.isLoading {
            notice(
                icon: ActionSymbol.historyPane.image,
                title: String(localized: "Nothing read yet",
                              comment: "Reading History notice when nothing has been looked up yet"),
                detail: String(localized: "Words you look up appear here, grouped by the day you met them.",
                               comment: "Reading History notice when nothing has been looked up yet"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.space.section) {
                    ForEach(model.days) { day in
                        if model.showsAsPile(day) {
                            DayPileView(
                                day: day, model: model,
                                expanded: Binding(
                                    get: { model.isExpanded(day) },
                                    set: { model.setExpanded($0, for: day) }))
                        } else {
                            DayListView(day: day, model: model)
                        }
                    }
                }
                .padding(scale.space.pad)
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// `title` and `detail` arrive localized — `detail` may be the ledger's own failure — so both
    /// are drawn verbatim rather than looked up a second time.
    private func notice(icon: Image, title: String, detail: String) -> some View {
        VStack(spacing: scale.space.stack) {
            icon
                .font(.system(size: scale.text.icon))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: title).font(.system(size: scale.text.strong, weight: .semibold))
            Text(verbatim: detail)
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension HistoryDrawerModel {
    /// What a card in this panel can do — only what is wired. A model in a preview, with no
    /// ledger behind it, offers nothing it could not carry out.
    func actions(for entry: ReadingEntry) -> ReadingCardActions {
        ReadingCardActions(
            discard: discard == nil ? nil : { [self] in remove(entry) },
            save: keepForLearning.map { save in { save(entry) } },
            showInLibrary: showInLibrary == nil ? nil : { [self] in openInLibrary(entry) })
    }
}

/// A day whose cards are simply listed: today, which is the part the reader came to read, and
/// any day holding a single card — which is not a pile.
struct DayListView: View {
    @Environment(\.scale) private var scale
    let day: ReadingDay
    /// Nil in the previews that show cards alone; an action needs somewhere to report to.
    var model: HistoryDrawerModel?

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            DayHeader(day: day)
            VStack(spacing: scale.space.stack) {
                ForEach(day.entries) { entry in
                    ReadingCardView(entry: entry, actions: model?.actions(for: entry) ?? ReadingCardActions())
                }
            }
        }
    }
}

/// An earlier day: a header and a pile of that day's cards, fanning open on a click.
struct DayPileView: View {
    let day: ReadingDay
    var model: HistoryDrawerModel?
    @Binding var expanded: Bool

    @Environment(\.scale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            // **The one toggle**, for VoiceOver and the keyboard as much as for the pointer. There
            // were two — this and a clear button laid over the whole pile, announcing "Show all 3
            // words" for what were three cards.
            DayHeader(day: day, disclosure: DayHeader.Disclosure(expanded: expanded, toggle: toggle))

            CardStackLayout(progress: expanded ? 1 : 0, pile: pile) {
                // Reversed so the deepest card is drawn first and the newest sits on top.
                ForEach(cards.reversed()) { card in
                    // **The front card of a closed pile is a working card.** It drew its speaker,
                    // eye and Dictionary icons at full strength under a button that covered the
                    // whole pile, so a click on any of them fanned the pile and did nothing else.
                    // A control that looks live is live; the buried plates take no clicks at all.
                    ReadingCardView(
                        entry: card.entry, layer: card.layer,
                        actions: model?.actions(for: card.entry) ?? ReadingCardActions())
                }
            }
            .contentShape(Rectangle())
            // A click anywhere on a closed pile that is not one of its front card's controls
            // opens it. A gesture, so it is the pointer's alone — and that is all it has to be,
            // because the header above is a real button doing the same thing. The cards' own
            // buttons win over it: a child's gesture is recognised before its ancestor's.
            .gesture(expanded ? nil : TapGesture().onEnded { toggle() })
            // A closed pile is one object, so it answers the pointer as one.
            .onHover { hovering = $0 }
            .scaleEffect(
                hovering && !expanded ? MotionPreference.scale(Token.Motion.lift, reduceMotion: reduceMotion) : 1,
                anchor: .top)
            .motionAwareAnimation(.easeOut(duration: Token.Motion.hover), value: hovering)
        }
    }

    private func toggle() {
        // The pointer is about to be over a fanned list rather than a pile, and the lift belongs to
        // the pile. Left set, it would scale the list the next time the pile closed.
        hovering = false
        // A spring, because the cards are objects being dealt — and a fade for the reader who
        // asked for less motion, when they simply change places.
        withAnimation(MotionPreference.animation(
            .spring(response: Token.Motion.fanResponse, dampingFraction: Token.Motion.fanDamping),
            reduceMotion: reduceMotion)) { expanded.toggle() }
    }
}

/// A day's name and how many readings it holds — and, for a pile, the button that opens it.
private struct DayHeader: View {
    /// What makes a header a control: the pile it opens, and which way it will go.
    struct Disclosure {
        let expanded: Bool
        let toggle: () -> Void

        var action: ActionSymbol { expanded ? .showLess : .showAll }
    }

    @Environment(\.scale) private var scale
    let day: ReadingDay
    /// Nil for a day that is listed rather than piled.
    var disclosure: Disclosure?

    private var count: Int { day.lookups }
    private var isToday: Bool { day.label == .today }

    var body: some View {
        if let disclosure {
            // The whole row is the target, 28 pt tall: it was the height of its text, about 16.
            Button(action: disclosure.toggle) { row(disclosure) }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(Text(
                    "\(Text(verbatim: title)), ^[\(count) reading](inflect: true), \(Text(disclosure.action.title))"))
        } else {
            row(nil)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(Text("\(Text(verbatim: title)), ^[\(count) reading](inflect: true)"))
        }
    }

    private func row(_ disclosure: Disclosure?) -> some View {
        HStack(spacing: scale.space.inline) {
            Text(verbatim: title)
                .font(.system(size: scale.text.body, weight: .semibold))
                .foregroundStyle(.secondary)
            // A bare number, so the tooltip says what it counts: readings, the header's unit.
            Text(count, format: .number)
                .font(.system(size: scale.text.small, weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, scale.space.inline)
                .padding(.vertical, scale.space.tight)
                // Today's is told apart by the wash behind it, not by tinted digits: accent blue
                // on glass measured 2.10:1.
                .background(Capsule().fill(isToday
                    ? Color.accentColor.opacity(Token.Opacity.countToday)
                    : Color.primary.opacity(Token.Opacity.count)))
                .foregroundStyle(isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: scale.space.inline)
            if let disclosure {
                // Words and a chevron, in the label colour. It was tint-coloured text with nothing
                // else to say it could be clicked.
                HStack(spacing: scale.space.line) {
                    Text(disclosure.action.title)
                    disclosure.action.image
                }
                .font(.system(size: scale.text.label, weight: .medium))
                .foregroundStyle(.primary)
            }
        }
        .frame(minHeight: Token.Target.minimum)
        .contentShape(Rectangle())
        .help(Text("^[\(count) reading](inflect: true)"))
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

/// **Non-optional, and named, so no preview force-unwraps a model's `geometry`.** Two previews did,
/// and each built the model twice — `HistoryDrawerSurface(model: sampleModel(), geometry:
/// sampleModel().geometry!)` handed a surface the geometry of a *different* instance.
private let sampleGeometry = DrawerGeometry.make(
    DrawerLayout(thickness: Scale.standard.space.drawerWidth, edge: .right),
    on: ScreenMetrics(
        frame: UpRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: UpRect(x: 0, y: 0, width: 1440, height: 870)))

@MainActor private func sampleModel() -> HistoryDrawerModel {
    let model = HistoryDrawerModel()
    model.geometry = sampleGeometry
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
    HistoryDrawerSurface(model: sampleModel(), geometry: sampleGeometry)
        .frame(width: 380, height: 700)
}

#Preview("Drawer, nothing read yet") {
    let empty = HistoryDrawerModel()
    empty.geometry = sampleGeometry
    return HistoryDrawerSurface(model: empty, geometry: sampleGeometry)
        .frame(width: 380, height: 420)
}
#endif
