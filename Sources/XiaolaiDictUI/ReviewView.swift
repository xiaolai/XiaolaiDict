import AppKit
import Foundation
import ReviewKit
import StudyKit
import SwiftUI
import XiaolaiDictCore

/// **The review surface: the reader's own sentence, and a question about it.**
///
/// C2, which is the whole design: *a review surface never answers the question unasked*. Here that is
/// structural rather than remembered — `answer` is nil until the reader asks, so before the reveal the
/// answer is not in the view, not in the layout, and not in the accessibility tree. There is nothing to
/// hide because there is nothing here.
///
/// Nothing reserves space for it either. A gap the size of a definition is the definition's shape, and
/// a reader who can see how long the answer is has been told something about it.
public struct ReviewView: View {
    @Environment(\.scale) private var scale
    @Environment(\.cardOptions) private var options
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// Whether the asked card holds the keyboard. See `body`.
    @FocusState private var holdsTheKeys: Bool
    /// The event that pressed a control. See `EnvironmentValues.pressingEvent`.
    @Environment(\.pressingEvent) private var pressingEvent
    public let state: ReviewPresentation
    /// What the reader did, and **the showing it was done to**: the question this view drew when the
    /// control was pressed, or nil for an action about the sitting rather than a card. The view decides
    /// nothing: it reports, and the model commits — against the card named here, never against
    /// whichever card the sitting has moved to while this one was still on screen (WI-8).
    public let act: @MainActor (ReviewAction, UUID?) -> Void
    /// Goes to the saved meanings that are waiting to be confirmed. Nil where this view is shown
    /// outside the Library, which has nowhere to go.
    private let findUnconfirmed: (@MainActor () -> Void)?
    /// Goes to the first saved meaning that needs an answer of the reader's own, open in Saved's
    /// inspector, whose editor is the remedy. Nil outside the Library, as above.
    private let findUnanswered: (@MainActor () -> Void)?

    public init(state: ReviewPresentation, findUnconfirmed: (@MainActor () -> Void)? = nil,
                findUnanswered: (@MainActor () -> Void)? = nil,
                act: @escaping @MainActor (ReviewAction, UUID?) -> Void) {
        self.state = state
        self.findUnconfirmed = findUnconfirmed
        self.findUnanswered = findUnanswered
        self.act = act
    }

    public var body: some View {
        switch state.stage {
        case .empty(let reason):
            // **Centred in the pane, like every other pane's nothing.** It sat in a
            // leading-aligned stack, so the message hugged the upper left of an empty window.
            LibraryEmptyState { emptyState(reason) }
        case .asking(let asking):
            sitting { card(asking) }
                // **The keyboard is the card's while one is asked.** The Library's sidebar is a list
                // that selects a row by its first letter, and the keys on this card are bare letters:
                // with focus left in the sidebar after Review was chosen, `S` selected Saved — measured
                // on the E2E Mac 2026-10-04, the window left Review and nothing was skipped. Digits,
                // Space and `E` reached the card only because no pane's name starts with them. The
                // ring is off for the reason `LibraryCollection` gives: it would go round the pane.
                .focusable()
                .focused($holdsTheKeys)
                .focusEffectDisabled()
                .onAppear { holdsTheKeys = true }
        case .finished(let end):
            sitting {
                VStack(alignment: .leading, spacing: scale.space.stack) { finishedState(end) }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// **Scrollable, because the content is the reader's own writing.** A long sentence and a
    /// long answer shared a fixed stack with the controls, so past a certain length neither
    /// could be read to the end and the buttons went off the bottom of the window.
    private func sitting(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, scale.space.padAcross)
                .padding(.vertical, scale.space.padDown)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// **The word's colour comes from the curated palette**, chosen here rather than carried in from
    /// the model: a colour is a design value, and a model that held one would be deciding how the
    /// card looks. Hashed the same way the drawer hashes it, so one word is one colour everywhere.
    private func accent(for question: ReviewPresentation.Question) -> Color {
        // **The lemma, which is what the lookup and the drawer hash.** Hashing the captured
        // surface gave *ran* and *run* different colours on different surfaces, which is exactly
        // the consistency the comment above claims.
        ReadingPalette.color(forLemma: question.accentKey, in: scheme, contrast: contrast)
    }

    // MARK: - Asking

    /// **The question is a card, like every other reading in this window.** Review was a window of
    /// its own once, and the window was the card; as a pane of the Library its content sat bare on
    /// the background beside panes full of cards. The same paper, edge and lift as theirs, in the
    /// word's own colour, and edge to edge as a History card in a list is.
    ///
    /// Nothing here reserves room for the answer: the card is as tall as what it shows, and grows
    /// when the reader asks.
    private func card(_ question: ReviewPresentation.Question) -> some View {
        VStack(alignment: .leading, spacing: scale.space.stack) { asking(question) }
            .padding(scale.space.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ReadingCardChrome(accent: CardSurface.border(accent: accent(for: question), contrast: contrast)))
    }

    /// **The front of a card, and its back only once asked for** — laid out as every other card in
    /// this window is: the word and a small detail beside it, the reader's sentence with the word
    /// marked, where it was met, and a last row with the voice on the left and what can be done on
    /// the right. The same components draw them, so a reading looks the same whether it is being
    /// browsed or asked.
    @ViewBuilder
    private func asking(_ question: ReviewPresentation.Question) -> some View {
        VStack(alignment: .leading, spacing: scale.space.tight) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: question.word)
                    .font(.system(size: scale.text.strong, weight: .semibold))
                    .foregroundStyle(accent(for: question))
                Spacer(minLength: 0)
                // Where in the batch this is — the place the other cards give their date.
                Text("\(question.position) of \(question.batchSize)")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
            }
            // **The reader's own sentence, with the word marked** — the cue, and the only thing on
            // the front that is prose. A capture that produced no real sentence shows none rather
            // than the word echoed back and dressed as context. **The reader's emphasis setting**
            // goes through, as it does on the lookup card and the drawer.
            if let sentence = question.sentence {
                ReadingSentence(sentence: sentence.text, ranges: sentence.range.map { [$0] } ?? [],
                                accent: accent(for: question), emphasis: options.emphasis)
            }
            Text(verbatim: question.source)
                .font(.system(size: scale.text.micro))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // One line, so the whole of it is a pointer away.
                .help(Text(verbatim: question.source))
            if question.isPractice {
                StatusLabel(.practice, "Practice. Nothing is scheduled", size: scale.text.micro, prominence: .secondary)
            }
        }

        switch question.prompt {
        case .meaningHere:
            Text("What does this mean here?")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }

        // Present only after the reveal. Not hidden, not zero-height, not `.opacity(0)`: absent.
        if let answer = question.answer {
            revealed(answer)
        }

        controls(question)
    }

    @ViewBuilder
    private func revealed(_ answer: ReviewPresentation.Answer) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text(verbatim: answer.text)
                .font(.system(size: scale.text.body))
                .textSelection(.enabled)
            if let dictionary = answer.dictionary {
                // A card attributes its answer. The reader's own words are attributed to nobody,
                // which is why this is absent rather than saying "you".
                Text(verbatim: dictionary)
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **Icons, each with its key in its tooltip.** Space, 1, 2, S and T were bound and written
    /// down nowhere a reader could find; `shortcut:` binds the key and names it from one value.
    /// The grades are thumbs because `xmark` beside `checkmark` reads as Cancel and OK.
    @ViewBuilder
    private func controls(_ question: ReviewPresentation.Question) -> some View {
        // **Disabled while a grade is committing**, every one of them: a reveal started then could
        // finish after the sitting had advanced and put this card's answer on the next one.
        let ready = !question.isCommitting
        HStack(spacing: scale.space.inline) {
            // The word aloud is not its meaning, so the voice is on the front like any other card's.
            ReadingPronunciation(word: question.word, sentence: question.sentence?.text ?? "")
            if question.answer == nil {
                IconButton(.showMeaning, shortcut: KeyboardShortcut(.space, modifiers: []), size: scale.text.strong,
                           isEnabled: ready) { answer(.reveal, on: question) }
            }
            // **Absent until the meaning is showing**, like the meaning: asking the dictionary about
            // the word while the question is open is looking the answer up, and it would make
            // "Remembered" a claim nobody could check. It opens the word and grades nothing.
            if question.answer != nil {
                IconButton(.openInDictionary, shortcut: KeyboardShortcut("e", modifiers: []),
                           isEnabled: ready) { answer(.explore, on: question) }
            }
            Spacer(minLength: 0)
            // **Forgot first, always.** The order is the same on every card, so a reader answering
            // quickly is answering the question and not hunting for the button.
            //
            // **The size of the word, because they are its answer.** Still icons — the reader asked
            // for every button to be one — but these three are what the surface is for, and at a
            // card's incidental size they were four grey glyphs in a corner.
            IconButton(.forgot, shortcut: KeyboardShortcut("1", modifiers: []), size: scale.text.strong,
                       isEnabled: ready) { answer(.grade(.again), on: question) }
            IconButton(.remembered, hint: "you recalled it before showing the meaning",
                       shortcut: KeyboardShortcut("2", modifiers: []), size: scale.text.strong,
                       isEnabled: ready) { answer(.grade(.good), on: question) }
            // A verdict on memory on one side, putting the card off on the other: different kinds
            // of answer, and only the first is recorded about the reader.
            Divider().frame(height: scale.text.strong)
            IconButton(.skip, hint: "still due today; the next batch can have it",
                       shortcut: KeyboardShortcut("s", modifiers: []), isEnabled: ready) { answer(.skip, on: question) }
            // **"Not Today" is not "Skip".** A skipped card comes back in this evening's next
            // batch; this one is gone until tomorrow, and the reader has to be able to say which
            // they mean.
            IconButton(.notToday, hint: "hidden until tomorrow; nothing about your memory is recorded",
                       shortcut: KeyboardShortcut("t", modifiers: []), isEnabled: ready) {
                answer(.postpone, on: question)
            }
        }
        if let problem = question.problem {
            // **A failed write stays on screen.** The reader answered; if the ledger did not take it,
            // saying nothing would leave them believing it did.
            StatusLabel(.error, text: Text(verbatim: problem))
        }
    }

    /// **One press is one answer.** A SwiftUI shortcut presses its button for every keyDown it is
    /// handed, and a held key is a stream of them. Measured on the E2E Mac 2026-10-04: holding `2` for
    /// 1.5 s graded six cards — the one on screen and every card after it in the batch — because the
    /// buttons are disabled only while a write is in flight, and the next card is drawn and enabled
    /// long before the next repeat. Every control on the card goes through here: a held `S` or `T`
    /// would skip or put off a whole batch the same way — ADR-0032.
    ///
    /// **And one answer is about the card it was given on**: `question` is the one this view drew,
    /// and its showing goes with the action, so the model can refuse an answer whose card the sitting
    /// has already left (WI-8). `question` is nil only for the end of a sitting's own offer.
    private func answer(_ action: ReviewAction, on question: ReviewPresentation.Question? = nil) {
        Self.press(action, on: question?.showing, event: pressingEvent(), act: act)
    }

    /// **What every control on this surface does when pressed**, with the event that pressed it: the
    /// autorepeat of a held key is refused, and anything else reaches `act` with the showing it was
    /// made on. The one place the guard lives, so the test that holds it holds the controls.
    static func press(_ action: ReviewAction, on showing: UUID?, event: NSEvent?,
                      act: @MainActor (ReviewAction, UUID?) -> Void) {
        guard !isHeldKeyRepeat(event) else { return }
        act(action, showing)
    }

    /// Whether `event` is the autorepeat of a key held down. Only the press that started the hold is an
    /// answer; a click, an action with no event behind it and a fresh press all are.
    ///
    /// The type is asked first because `isARepeat` raises for anything that is not a key event.
    static func isHeldKeyRepeat(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    // MARK: - The ends

    /// **One message, the pane's own symbol, and the next step as a button where there is one.**
    /// "Choose or confirm their meanings in Saved" was a sentence with no way to do it: the route
    /// was an unlabelled warning triangle in the far corner, there whether or not anything needed
    /// confirming.
    @ViewBuilder
    private func emptyState(_ reason: ReviewPresentation.Empty) -> some View {
        switch reason {
        case .nothingDue:
            ContentUnavailableView {
                Label("Nothing Due", systemImage: ActionSymbol.reviewPane.symbol)
            } description: {
                Text("Saved meanings come back here when they are due.")
            }
        case .needsAttention(let waiting):
            // **One sentence per reason, each naming its own remedy.** One count said all of them
            // "cannot be reviewed until you choose or confirm", and for most of them confirming
            // changes nothing: an answerless note confirmed is exactly as unreviewable as before.
            ContentUnavailableView {
                Label("Nothing Can Be Reviewed Yet", systemImage: ActionSymbol.findUnconfirmed.symbol)
            } description: {
                VStack(spacing: scale.space.tight) {
                    if waiting.toConfirm > 0 {
                        Text("""
                             ^[\(waiting.toConfirm) saved meaning](inflect: true) cannot be reviewed until you \
                             confirm what was meant.
                             """)
                    }
                    if waiting.toAnswer > 0 {
                        Text("""
                             ^[\(waiting.toAnswer) saved meaning](inflect: true) cannot be reviewed until you \
                             write an answer in your own words. Confirming does not change that.
                             """)
                    }
                    if waiting.readingDeleted > 0 {
                        Text("""
                             ^[\(waiting.readingDeleted) saved meaning](inflect: true) cannot be reviewed, \
                             because there is no reading left to ask in.
                             """)
                    }
                }
            } actions: {
                HStack(spacing: scale.space.inline) {
                    if waiting.toConfirm > 0, let findUnconfirmed {
                        Button("Show in Saved") { findUnconfirmed() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("review-show-in-saved")
                    }
                    if waiting.toAnswer > 0, let findUnanswered {
                        IconButton(.writeAnswer, title: "Write ^[\(waiting.toAnswer) Answer](inflect: true)",
                                   hint: "opens the first one in Saved",
                                   action: findUnanswered)
                            .accessibilityIdentifier("review-write-answers")
                    }
                }
            }
        case .nothingEnrolled:
            ContentUnavailableView {
                Label("Nothing Saved Yet", systemImage: ActionSymbol.reviewPane.symbol)
            } description: {
                Text("Save a meaning while reading, and it comes back here when it is due.")
            }
        case .couldNotBeRead(let problem):
            ContentUnavailableView {
                Label("Saved Meanings Could Not Be Read", systemImage: ActionSymbol.failure.symbol)
            } description: {
                Text(verbatim: problem).textSelection(.enabled)
            } actions: {
                Button { act(.anotherBatch, nil) } label: { Text(ActionSymbol.retry.title) }
            }
        case .heldBackUntilTomorrow(let count):
            ContentUnavailableView {
                Label("Nothing Due", systemImage: ActionSymbol.reviewPane.symbol)
            } description: {
                // **The specific sentence instead of the general one**, never both: "they come back
                // when they are due" is a vaguer restatement of exactly this.
                Text("^[\(count) new meaning](inflect: true) will be introduced tomorrow.")
            }
        }
    }

    @ViewBuilder
    private func finishedState(_ end: ReviewPresentation.Finished) -> some View {
        let summary = end.summary
        Text("\(summary.graded) reviewed")
            .font(.system(size: scale.text.heading, weight: .medium))
        // **Which of them moved nothing**, where a sitting held both modes (R4): each card said
        // "Practice" as it was asked, and the count says it again rather than folding practice into
        // reviews the scheduler took.
        if summary.practised > 0, !summary.wasPractice {
            Text("\(summary.practised) of them practice, nothing scheduled")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        forgotten(summary)
        // **Never "all done".** A batch bounds a sitting, not the reader's debt, and a surface that
        // hides the remainder teaches them it is smaller than it is.
        if summary.stillDue > 0 {
            Text("\(summary.stillDue) more due")
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
        }
        // **Skips by the mode each card was drawn in**, not by the sitting: a practice card was not
        // due, so "still due" is a claim about the schedule it cannot carry — and a Selected sitting
        // holds both kinds.
        if summary.skippedStillDue > 0 {
            Text("\(summary.skippedStillDue) skipped, still due")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        if summary.skippedPractice > 0 {
            Text("\(summary.skippedPractice) skipped")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        // **A different sentence from "skipped".** One is still due this evening and the other is
        // not, and a reader who cannot tell them apart cannot plan the rest of the sitting.
        if summary.postponed > 0 {
            Text("\(summary.postponed) hidden until tomorrow")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        // **Said, and said differently from "more due".** New words the day's allowance is holding
        // are not late; without this line a reader who saved thirty and answered five sees twenty-
        // five words go quiet with no explanation.
        if summary.heldBack > 0 {
            Text("^[\(summary.heldBack) new meaning](inflect: true) will be introduced tomorrow")
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
        // **What a Selected sitting left out of the reader's choice, by reason** — never dropped
        // silently, and each reason its own line because each has its own remedy.
        excluded(summary.excluded)
        // **And what left the sitting because it can no longer be asked**, by reason — counted, never
        // dropped silently, and never "skipped, still due": nothing done in Review brings it back.
        departed(summary.left)
        slipping(end.slipping)
        if let forecast = end.forecast { coming(forecast) }
        if let problem = end.problem {
            // The sitting's own counts above are true; what could not be read is said, not left blank.
            StatusLabel(.error, text: Text(verbatim: problem))
        }
        HStack(spacing: scale.space.inline) {
            // **Skipped cards that were due are still due**, and were left out of `stillDue` — so
            // skipping the last batch ended the sitting with work outstanding and no way to go on.
            if summary.stillDue > 0 || summary.skippedStillDue > 0 {
                IconButton(.anotherBatch) { act(.anotherBatch, nil) }
            }
            // **Offered when there is nothing due**, which is when a reader who wants to keep
            // going would otherwise have nothing to do but wait.
            if summary.stillDue == 0 && summary.skippedStillDue == 0 {
                IconButton(.practise, hint: "nothing is scheduled by it") { act(.practise, nil) }
            }
            // **Only where new meanings are held back, and for exactly how many** (WI-5). Through
            // `answer`, so a held key is one press: the second would find the offer already spent.
            if end.moreNewToday > 0 {
                IconButton(.introduceMoreToday,
                           title: "Introduce ^[\(end.moreNewToday) More New Meaning](inflect: true) Today",
                           hint: "for today only; tomorrow's allowance is unchanged",
                           shortcut: KeyboardShortcut("m", modifiers: [])) { answer(.introduceMoreToday) }
            }
            IconButton(.done, shortcut: .defaultAction) { act(.done, nil) }
        }
    }
}

extension ReviewView {
    /// **"Forgot k of N", over the scheduled answers alone** (ADR-0036). Practice moved nothing, so its
    /// Forgot answers are counted on a line of their own and never enter the figure. A sitting with no
    /// scheduled answer has no figure: a count over zero attempts is a number nobody has.
    @ViewBuilder
    private func forgotten(_ summary: ReviewSession.Summary) -> some View {
        Group {
            if summary.scheduled > 0 {
                Text("Forgot \(summary.forgot) of \(summary.scheduled)")
            }
            if summary.forgotInPractice > 0 {
                Text("Forgot \(summary.forgotInPractice) in practice, which schedules nothing")
            }
        }
        .font(.system(size: scale.text.small))
        .foregroundStyle(.secondary)
    }

    /// **The words that keep slipping, named and nothing more** — never suspended, paused or put off.
    /// Saved's Struggling filter lists the same cards by the same rule, and is where to act on them.
    @ViewBuilder
    private func slipping(_ words: [String]) -> some View {
        if !words.isEmpty {
            VStack(alignment: .leading, spacing: scale.space.line) {
                Text("Keeps slipping: \(words.formatted(.list(type: .and)))")
                    .font(.system(size: scale.text.small))
                Text("Saved lists them under Struggling")
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// **What the coming study days will ask, as text** — never a chart, never a percentage. Today
    /// first, overdue work included; each day a count of meanings, new ones only up to that day's
    /// allowance. A week with nothing in it says so in words rather than as a row of zeros.
    @ViewBuilder
    private func coming(_ forecast: Forecast) -> some View {
        Group {
            if forecast.days.allSatisfy({ $0.due == 0 }) {
                Text("Nothing comes due in the next ^[\(forecast.days.count) day](inflect: true)")
            } else {
                Text("What's coming: \(Self.days(of: forecast))")
            }
        }
        .font(.system(size: scale.text.small))
        .foregroundStyle(.secondary)
    }

    /// "Today 3 · Tomorrow 12 · Wed 7 …": each day named on the reader's calendar, in the zone the
    /// forecast was counted in, so a day's name and its count are about the same day.
    static func days(of forecast: Forecast) -> String {
        let weekday = Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated)
        return forecast.days.map { day in
            switch day.offset {
            case 0:
                String(localized: "Today \(day.due)", comment: "One day of the review forecast: today and its count")
            case 1:
                String(localized: "Tomorrow \(day.due)", comment: "One day of the review forecast: tomorrow and its count")
            default:
                String(localized: "\(day.start.formatted(weekday)) \(day.due)",
                       comment: "One day of the review forecast: an abbreviated weekday and its count")
            }
        }.formatted(.list(type: .and, width: .narrow))
    }
}

extension ReviewView {
    /// The lines for what a Selected sitting left out. Counts of meanings, but for the last: the
    /// cards a sitting does not ask because it asks one per meaning (R08).
    @ViewBuilder
    private func excluded(_ left: SittingExclusions) -> some View {
        Group {
            if left.pausedOrHidden > 0 { Text("\(left.pausedOrHidden) paused or put off, not asked") }
            if left.notAskable > 0 { Text("\(left.notAskable) not ready to review, not asked") }
            if left.otherDictionary > 0 { Text("\(left.otherDictionary) from another study dictionary, not asked") }
            if left.siblings > 0 { Text("^[\(left.siblings) card](inflect: true) left for another sitting: one per meaning") }
        }
        .font(.system(size: scale.text.small))
        .foregroundStyle(.secondary)
    }

    /// The lines for cards that left the sitting because they can no longer be asked, one per reason, in
    /// the order of the remedy — each changed in Saved since the sitting was drawn.
    @ViewBuilder
    private func departed(_ left: [Departure: Int]) -> some View {
        Group {
            ForEach(Departure.allCases.filter { (left[$0] ?? 0) > 0 }, id: \.self) { reason in
                let count = left[reason] ?? 0
                switch reason {
                case .noLongerInStudy: Text("\(count) no longer in study, left the sitting")
                case .paused: Text("\(count) paused, left the sitting")
                case .putOff: Text("\(count) put off until later, left the sitting")
                case .notReady: Text("\(count) no longer ready to review, left the sitting")
                }
            }
        }
        .font(.system(size: scale.text.small))
        .foregroundStyle(.secondary)
    }
}

extension EnvironmentValues {
    /// **The event that pressed a review control**: the application's current event, which is the
    /// autorepeat itself while a key is held. Read by `ReviewView.press`'s caller, and set by nothing in
    /// the app. It is an environment value so a test can hand a card it hosts the key it delivers: a
    /// test process has no event loop to make that key current, and asking AppKit for one there starts
    /// it pulling window-server events, whose wake-up then stops the test runner's own run loop — the
    /// process exited 0 mid-suite with no result line (measured 2026-10-05, WI-8 follow-up).
    var pressingEvent: @MainActor @Sendable () -> NSEvent? {
        get { self[PressingEventKey.self] }
        set { self[PressingEventKey.self] = newValue }
    }
}

/// A key, not `@Entry`, because the macro refuses a closure: a closure cannot be compared, so setting
/// one invalidates whatever reads it on every update. Nothing in the app sets this one, so every read is
/// of the one default below.
private struct PressingEventKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> NSEvent? = { NSApplication.shared.currentEvent }
}

/// What the reader can do to a card. **The view reports; the model commits** — a view that wrote to the
/// ledger would be one that advanced before the write landed.
public enum ReviewAction: Sendable, Equatable {
    case reveal
    case grade(Grade)
    case skip
    /// Out of the way until the next study day (R05). **Not `skip`**, which leaves it due now.
    case postpone
    case undo
    /// Opens the card's word in Apple's Dictionary. **Offered only once the meaning is showing**, and
    /// not a grade: it moves no schedule, writes no event and leaves the card where it is.
    case explore
    case anotherBatch
    /// An unscheduled sitting. **Recorded and inert**: no schedule moves and no retention figure
    /// counts it, which is why it is a separate action and a separate label rather than a mode
    /// the reader might not notice they are in.
    case practise
    /// Raises today's new-meaning allowance by what the end of the sitting offered, for this study day
    /// only, and draws a batch (WI-5). **It spends nothing**: introductions spend the allowance
    /// (ADR-0037), and this moves only the ceiling they are counted against. How many is the model's.
    case introduceMoreToday
    case done
}

/// Everything the review surface draws, and nothing it does not.
///
/// **The answer is `nil` before the reveal, at this boundary.** Not a flag beside it, not a string the
/// view is trusted to skip — absent, so the rule holds by construction rather than by everyone
/// remembering it on every future change.
public struct ReviewPresentation: Sendable, Equatable {
    public let stage: Stage

    public init(stage: Stage) { self.stage = stage }

    public enum Stage: Sendable, Equatable {
        case empty(Empty)
        case asking(Question)
        case finished(Finished)
    }

    /// **The end of a sitting** (review-module-plan §8.4, WI-5): what the sitting did, what the coming
    /// study days hold, which words keep slipping, and whether more new meanings can be introduced
    /// today.
    ///
    /// **Counts and words, never a meaning** (C2). A word is what the card's front showed; nothing here
    /// can hold what a card's back says, so the end of a sitting cannot answer a question either.
    public struct Finished: Sendable, Equatable {
        public let summary: ReviewSession.Summary
        /// What each of the coming study days will ask, today first. **Nil where it could not be
        /// read**, which `problem` then says — never an empty week standing in for an unread one.
        public let forecast: Forecast?
        /// The words of the meanings this sitting forgot that keep slipping — the Struggling filter's
        /// rule (R09). **Named and nothing else**: nothing is paused, put off or rescheduled for it.
        public let slipping: [String]
        /// How many more new meanings "Introduce More Today" would add to today's allowance. Zero is
        /// not offered: nothing is held back, or the count could not be read.
        public let moreNewToday: Int
        /// Why the forecast and the rest could not be read, in the reader's words. The sitting's own
        /// counts are still true and still shown.
        public let problem: String?

        public init(summary: ReviewSession.Summary, forecast: Forecast? = nil, slipping: [String] = [],
                    moreNewToday: Int = 0, problem: String? = nil) {
            self.summary = summary
            self.forecast = forecast
            self.slipping = slipping
            self.moreNewToday = moreNewToday
            self.problem = problem
        }
    }

    /// Whether what is on screen already offers the way to the unconfirmed meanings — the empty
    /// state that says they are what is holding review up has the button itself.
    public var offersFindUnconfirmed: Bool {
        if case .empty(.needsAttention) = stage { return true }
        return false
    }

    public enum Empty: Sendable, Equatable {
        /// Cards exist; none is due.
        case nothingDue
        /// Saved meanings exist and none can be asked, **counted by what is in the way** — each reason
        /// has its own remedy, and a sentence naming one must count only what it fixes.
        case needsAttention(StudyAttention)
        /// The reader has not saved anything yet. A different sentence, because "nothing is due" to
        /// someone with no cards reads as a broken feature.
        case nothingEnrolled
        /// Nothing is askable, but new words are waiting on today's allowance. **A third sentence**,
        /// because a reader who saved thirty words this afternoon and is told "nothing is due" has
        /// no way to tell a working cap from a broken save.
        case heldBackUntilTomorrow(Int)
        /// **A fourth nothing: the cards could not be read at all.** The other three are answers;
        /// this is a failure, and it drew as "nothing is due" — telling a reader with a full
        /// collection that they were up to date. `problem` was assigned on that path and then
        /// thrown away, because an empty stage had nowhere to put it.
        case couldNotBeRead(String)
    }

    public struct Question: Sendable, Equatable {
        /// **Which showing this is** — the sitting's presentation, whose id is also the grade's
        /// idempotency key. Every control on the card hands it back with its action, so an answer is
        /// about the card that was drawn when it was given and never about one the sitting has moved
        /// to since (WI-8).
        public let showing: UUID
        public let word: String
        /// What the word's colour is hashed from. **The lemma, not the captured surface**, so
        /// *ran* and *run* are one word here as they are in the lookup card and the drawer.
        public let accentKey: String
        /// The word to open in the dictionary: the card's own spelling, not the form it was met in.
        /// Defaults to the word, so a caller with nothing better is unchanged.
        public let exploreTerm: String
        public let sentence: Sentence?
        public let source: String
        public let position: Int
        public let batchSize: Int
        /// Whether this is practice. **Said on the card**, not inferred from how the reader got
        /// here: an attempt that changes nothing must not look like one that does.
        public let isPractice: Bool
        /// The question itself. **A fixed sentence, not a stored string** — it is reader-facing text
        /// and belongs in the catalog, so the view holds it and the model chooses nothing.
        public let prompt: Prompt
        /// Nil until the reader asks. See the type's own note.
        public let answer: Answer?
        /// A write in flight. The grade buttons refuse while one is, so a second press cannot become
        /// a second attempt at the same presentation.
        public let isCommitting: Bool
        /// A write that failed, in the reader's words. Stays until they act again.
        public let problem: String?

        public init(showing: UUID, word: String, accentKey: String? = nil, exploreTerm: String? = nil,
                    sentence: Sentence?, source: String, position: Int,
                    batchSize: Int, isPractice: Bool = false, prompt: Prompt = .meaningHere,
                    answer: Answer? = nil, isCommitting: Bool = false, problem: String? = nil) {
            self.showing = showing
            self.word = word
            // Defaults to the word, so a caller with no lemma is unchanged.
            self.accentKey = accentKey ?? word
            self.exploreTerm = exploreTerm ?? word
            self.sentence = sentence
            self.source = source
            self.position = position
            self.batchSize = batchSize
            self.isPractice = isPractice
            self.prompt = prompt
            self.answer = answer
            self.isCommitting = isCommitting
            self.problem = problem
        }
    }

    /// Which question the card asks. One case today; a production card asks a different one, and it
    /// will be a case here rather than a string the model assembles.
    public enum Prompt: Sendable, Equatable {
        case meaningHere
    }

    public struct Sentence: Sendable, Equatable {
        public let text: String
        public let range: NSRange?

        public init(text: String, range: NSRange?) {
            self.text = text
            self.range = range
        }
    }

    public struct Answer: Sendable, Equatable {
        public let text: String
        public let dictionary: String?

        public init(text: String, dictionary: String?) {
            self.text = text
            self.dictionary = dictionary
        }
    }
}
