import DictionaryModel
import Foundation
import ReviewKit
import Testing
import XiaolaiDictCore
@testable import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The Selected sitting, from Saved's selection to the ledger's rows** (review-module-plan §8.2, R4,
/// WI-3b). `SelectedSittingTests` and `SelectedCandidatesTests` prove the rules and the read; these
/// prove the wire: that the Library's action reaches the model that draws the sitting and the app
/// connects the two, that each card's mode is said on the card and reaches the call it names, and
/// that the end of the sitting counts what it left out.
@MainActor
struct SelectedSittingWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sentence(_ word: String) -> String { "He met the \(word) today." }

    /// A meaning saved for `word`: the reader's choice, or a proposal still waiting to be confirmed.
    @discardableResult
    private func save(_ ledger: Ledger, _ word: String, dictionary: String = "noad",
                      proposal: Bool = false) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: sentence(word), lemmaBasis: .tagger, language: "en",
            contextRange: (sentence(word) as NSString).range(of: word),
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari", document: nil,
                                page: nil, title: "A page", rawTitle: "A page"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextMarkers, context: .complete)))
        return try ledger.enroll(
            .sense(dictionary: dictionary, entryID: "e-\(word)", senseKey: "e-\(word).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: proposal ? .model : .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"), lookupID: lookup, at: now)
    }

    private func card(_ ledger: Ledger, _ note: StudyNote) throws -> StudyCard {
        try #require(try ledger.existingCard(of: note.id))
    }

    /// Due now and not new: answered Forgot a day ago, so it is learning and long due — and its
    /// introduction was yesterday's, which leaves today's allowance whole.
    private func makeDue(_ ledger: Ledger, _ note: StudyNote) throws {
        let card = try card(ledger, note)
        _ = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: card.revision,
                             at: now.addingTimeInterval(-86_400 - 3_600), using: try MemoryScheduler())
    }

    /// Reviewed and not due: answered Remembered a day ago, so it comes back about a day from now.
    private func makeAhead(_ ledger: Ledger, _ note: StudyNote) throws -> StudyCard {
        let card = try card(ledger, note)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                             at: now.addingTimeInterval(-86_400), using: try MemoryScheduler())
        let after = try self.card(ledger, note)
        try #require((after.scheduled.due ?? .distantPast) > now, "the fixture's card is due already")
        return after
    }

    private func review(_ store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
                        clock: MovableClock? = nil) -> ReviewModel {
        ReviewModel(store: store, primary: { PrimaryDictionary(chosen: "noad") },
                    clock: { clock?.now ?? self.now }, defaults: TemporaryDefaults.suite())
    }

    private func library(_ store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
                         handed: Handed, review: ReviewModel?) -> LibraryModel {
        LibraryModel(store: store, clock: { self.now },
                     exportDirectory: { ScratchFile.unmade("export", file: "exports") },
                     reviewSelected: { ids, order in
                         handed.calls.append(ids)
                         review?.startSelected(noteIDs: ids, order: order)
                     },
                     defaults: TemporaryDefaults.suite(), primary: { PrimaryDictionary(chosen: "noad") })
    }

    /// The study dictionary, changeable after a model has captured where to read it.
    @MainActor private final class Chosen {
        var key: String
        init(_ key: String) { self.key = key }
    }

    /// How often a model reached for its store, and a gate the first reach waits at.
    @MainActor private final class Asked {
        var stores = 0
        var open = false
        func gate() async {
            while !open { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }
    /// What the Library handed over, in order.
    @MainActor private final class Handed { var calls: [[UUID]] = [] }
    /// A clock a test can move.
    @MainActor private final class MovableClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func question(_ model: ReviewModel) -> ReviewPresentation.Question? {
        guard case .asking(let question) = model.presentation.stage else { return nil }
        return question
    }

    private func summary(_ model: ReviewModel) -> ReviewSession.Summary? {
        guard case .finished(let end) = model.presentation.stage else { return nil }
        return end.summary
    }

    /// Answers every card with `grade`, waiting for each to land, and returns what each card said.
    private func answerAll(_ model: ReviewModel, _ grade: Grade) async throws -> [(word: String, isPractice: Bool)] {
        var said: [(word: String, isPractice: Bool)] = []
        while let question = question(model) {
            said.append((question.word, question.isPractice))
            model.act(.grade(grade))
            let next = question.position + 1
            try await Wiring.settle("the grade never landed") {
                self.summary(model) != nil || self.question(model)?.position == next
            }
            if let problem = self.question(model)?.problem { Issue.record("refused: \(problem)"); break }
        }
        return said
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path), encoding: .utf8)
    }

    // MARK: - The wire from Saved to Review

    /// **Review Selected hands the Library's whole selection, as listed, to the model that draws the
    /// sitting, and shows Review** — which then asks exactly the askable ones in that order and says
    /// at its end why the other was left out. Two of the six are not selected; a sitting over the
    /// whole queue would ask them too.
    @Test func reviewSelectedStartsASittingOverExactlyTheSelection() async throws {
        let (path, clean) = Wiring.scratch("selected-library")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for word in ["alpha", "bravo", "charlie", "delta", "echo"] { try makeDue(ledger, try save(ledger, word)) }
        let paused = try save(ledger, "paused")
        try makeDue(ledger, paused)
        try ledger.setPaused(true, ofCard: try card(ledger, paused).id)
        let store = Wiring.store(path)
        let review = review(store)
        let handed = Handed()
        let library = library(store, handed: handed, review: review)
        await library.reload()
        let rows = library.presentation.rows
        try #require(rows.count == 6)
        let askable = rows.filter { $0.id != paused.id }
        let chosen = [askable[1], askable[3], askable[4]]
        let selection = Set(chosen.map(\.id) + [paused.id])
        library.act(.select(selection))
        try await Wiring.settle { library.presentation.selection.count == 4 }
        #expect(library.presentation.reviewable == Set(chosen.map(\.id)), "three ready meanings, three reviewable")

        library.act(.reviewSelected(.asListed))
        #expect(handed.calls == [rows.map(\.id).filter(selection.contains)],
                "the whole selection was not handed over, as listed")
        #expect(library.pane == .review, "Review was not shown")
        try await Wiring.settle("no sitting was drawn") { self.question(review) != nil }
        #expect(question(review)?.batchSize == 3)
        var asked: [String] = []
        while let question = question(review) {
            asked.append(question.word)
            review.act(.skip)
            let next = question.position + 1
            try await Wiring.settle { self.summary(review) != nil || self.question(review)?.position == next }
        }
        #expect(asked == chosen.map(\.word), "asked \(asked)")
        #expect(summary(review)?.excluded == SittingExclusions(pausedOrHidden: 1), "the paused one was not said")
    }

    /// **The app connects the two**, and nothing else starts a Selected sitting. The test above hands
    /// the Library a closure of its own; this is the one the app passes — a model nothing calls is not
    /// a feature.
    @Test func theAppHandsReviewSelectedToTheReviewModel() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        let start = try #require(app.range(of: "lazy var libraryModel = LibraryModel("))
        let end = try #require(app.range(of: "lazy var eraseModel", range: start.upperBound..<app.endIndex))
        let construction = app[start.upperBound..<end.lowerBound]
        #expect(construction.contains("reviewSelected:"), "the Library is built without the action's wire")
        #expect(construction.contains("reviewModel.startSelected(noteIDs:"), "and it does not reach the review model")
        let model = try source("Sources/XiaolaiDict/LibraryModel.swift")
        #expect(model.contains("reviewSelected(listed, order)"), "the Library's action does not call it")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var callers: [String] = []
        let walk = FileManager.default.enumerator(at: root.appending(path: "Sources"), includingPropertiesForKeys: nil)
        while let file = walk?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            if try String(contentsOf: file, encoding: .utf8).contains(".startSelected(") {
                callers.append(file.lastPathComponent)
            }
        }
        #expect(callers == ["XiaolaiDictApp.swift"], "started from \(callers)")
    }

    /// **Disabled, with a reason, when nothing selected can be asked** — paused, put off, waiting to be
    /// confirmed, or another dictionary's — and pressing it anyway starts nothing and goes nowhere.
    /// The control: one ready meaning makes it reviewable.
    @Test func nothingStartsWhenNothingSelectedCanBeAsked() async throws {
        let (path, clean) = Wiring.scratch("selected-none")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let paused = try save(ledger, "paused")
        try makeDue(ledger, paused)
        try ledger.setPaused(true, ofCard: try card(ledger, paused).id)
        let putOff = try save(ledger, "putoff")
        try ledger.postpone(cardID: try card(ledger, putOff).id, until: now.addingTimeInterval(86_400))
        let proposal = try save(ledger, "proposal", proposal: true)
        let elsewhere = try save(ledger, "elsewhere", dictionary: "oxford")
        let ready = try save(ledger, "ready")
        let handed = Handed()
        let library = library(Wiring.store(path), handed: handed, review: nil)
        await library.reload()
        let before = library.pane

        let blocked: Set<UUID> = [paused.id, putOff.id, proposal.id, elsewhere.id]
        library.act(.select(blocked))
        try await Wiring.settle { library.presentation.selection == blocked }
        #expect(library.presentation.reviewable.isEmpty)
        #expect(library.presentation.rows.filter(\.isReviewable).map(\.id) == [ready.id])
        library.act(.reviewSelected(.asListed))
        #expect(handed.calls.isEmpty, "a sitting was started over nothing it could ask")
        #expect(library.pane == before)

        library.act(.select(blocked.union([ready.id])))
        try await Wiring.settle { library.presentation.selection.count == 5 }
        #expect(library.presentation.reviewable == [ready.id], "positive control")
        #expect(library.presentation.selectionTarget.reviewable == [ready.id])
    }

    /// **Today's allowance spent, a new meaning is held back — and the control says so instead of
    /// opening a sitting that asks nothing** (WI-8). Five new meanings introduced today, the sixth
    /// selected: the sitting would draw no card and hold one back, so Review Selected must count none
    /// and be disabled. Counted by the planner the sitting is drawn with, not by a second rule that
    /// knows nothing of introductions.
    @Test func aNewMeaningPastTodaysAllowanceIsNotReviewable() async throws {
        let (path, clean) = Wiring.scratch("selected-allowance")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for word in ["alpha", "bravo", "charlie", "delta", "echo"] {
            let card = try card(ledger, try save(ledger, word))
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                                 at: now, using: try MemoryScheduler())
        }
        try #require(try ledger.introductions(since: StudyDay.standard.start(containing: now), dictionary: "noad")
                     == ReviewModel.newCardsPerDay, "the fixture did not spend today's allowance")
        let sixth = try save(ledger, "foxtrot")
        let reviewed = try save(ledger, "golf")
        try makeDue(ledger, reviewed)
        let handed = Handed()
        let library = library(Wiring.store(path), handed: handed, review: nil)
        await library.reload()
        let before = library.pane

        library.act(.select([sixth.id]))
        try await Wiring.settle { library.presentation.selection == [sixth.id] }
        #expect(library.presentation.reviewable.isEmpty, "a new meaning past today's allowance was offered")
        #expect(library.presentation.rows.first { $0.id == sixth.id }?.review == .heldBack)
        // **Disabled, and why**: it waits for tomorrow — the sitting's own count, not a guess.
        #expect(library.presentation.selectionTarget.heldBack == 1)
        library.act(.reviewSelected(.asListed))
        #expect(handed.calls.isEmpty, "a sitting that asks nothing was started")
        #expect(library.pane == before)

        // The control: a card already in progress is not rationed, so beside it the control counts one.
        library.act(.select([sixth.id, reviewed.id]))
        try await Wiring.settle { library.presentation.selection.count == 2 }
        #expect(library.presentation.reviewable == [reviewed.id])
        #expect(library.presentation.reviewHeldBack == 1)

        // And today's one-day increase raises the allowance the control counts against, as the sitting's.
        let defaults = TemporaryDefaults.suite()
        OneDayIncreaseStore(defaults: defaults).raise(by: 1, in: .standard, at: now)
        let raised = LibraryModel(store: Wiring.store(path), clock: { self.now },
                                  exportDirectory: { ScratchFile.unmade("export", file: "exports") },
                                  defaults: defaults, primary: { PrimaryDictionary(chosen: "noad") })
        await raised.reload()
        raised.act(.select([sixth.id]))
        try await Wiring.settle { raised.presentation.selection == [sixth.id] }
        #expect(raised.presentation.reviewable == [sixth.id], "the increase did not reach Review Selected")
    }

    /// **The allowance a selection is planned against is the study dictionary's own** (audit-fix round
    /// 2). The page read counted today's introductions under the dictionary chosen then; a selection
    /// after switching planned the new dictionary's cards against the old one's spent allowance, so a
    /// new meaning in a dictionary nothing had been introduced from today was held back until tomorrow.
    @Test func switchingTheStudyDictionaryPlansTheSelectionAgainstItsOwnAllowance() async throws {
        let (path, clean) = Wiring.scratch("selected-switch")
        defer { clean() }
        let ledger = try Ledger(path: path)
        for word in ["alpha", "bravo", "charlie", "delta", "echo"] {
            let card = try card(ledger, try save(ledger, word))
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                                 at: now, using: try MemoryScheduler())
        }
        let elsewhere = try save(ledger, "foxtrot", dictionary: "oald")
        try #require(try ledger.introductions(since: StudyDay.standard.start(containing: now), dictionary: "oald") == 0)
        let chosen = Chosen("noad")
        let library = LibraryModel(store: Wiring.store(path), clock: { self.now },
                                   exportDirectory: { ScratchFile.unmade("export", file: "exports") },
                                   defaults: TemporaryDefaults.suite(),
                                   primary: { PrimaryDictionary(chosen: chosen.key) })
        await library.reload()

        chosen.key = "oald"
        library.act(.select([elsewhere.id]))
        try await Wiring.settle { library.presentation.selection == [elsewhere.id] }
        #expect(library.presentation.reviewable == [elsewhere.id],
                "a new meaning was held back by another dictionary's allowance")
        #expect(library.presentation.reviewHeldBack == 0)
    }

    // MARK: - The mode, card by card

    /// **A practice answer never reaches `grade`**, and a due card's always does — in one sitting.
    /// Each card says which it is, on the card, and the ledger agrees with what it said: a scheduled
    /// event and a moved card for the due ones, a practice event and an untouched card for the one
    /// reviewed already and not due.
    @Test func aPracticeGradeNeverReachesGrade() async throws {
        let (path, clean) = Wiring.scratch("selected-modes")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let due = try save(ledger, "due")
        try makeDue(ledger, due)
        let ahead = try save(ledger, "ahead")
        let aheadBefore = try makeAhead(ledger, ahead)
        let fresh = try save(ledger, "fresh")
        let review = review(Wiring.store(path))
        await review.startSelected(noteIDs: [due.id, ahead.id, fresh.id], order: .asListed).value

        let said = try await answerAll(review, .good)
        #expect(said.map(\.word) == ["due", "ahead", "fresh"])
        #expect(said.map(\.isPractice) == [false, true, false], "the card did not say which mode it was in")
        let reopened = try Ledger(path: path)
        #expect(try reopened.reviews(ofCard: try card(reopened, due).id).map(\.kind) == [.graded, .graded])
        #expect(try reopened.reviews(ofCard: aheadBefore.id).map(\.kind) == [.graded, .practice],
                "a practice answer reached the scheduler")
        #expect(try card(reopened, ahead) == aheadBefore, "practice moved the card")
        #expect(try reopened.reviews(ofCard: try card(reopened, fresh).id).map(\.kind) == [.graded])
        let end = try #require(summary(review))
        #expect(end.graded == 3 && end.practised == 1 && !end.wasPractice, "\(end)")
    }

    /// **The mode is frozen when the card is drawn** (R4). A card drawn as practice that comes due
    /// while the reader is looking at it is still practice when they answer: the surface told them
    /// nothing would be scheduled, and the commit keeps that promise.
    @Test func theModeIsFrozenWhenTheCardIsDrawn() async throws {
        let (path, clean) = Wiring.scratch("selected-frozen")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let ahead = try save(ledger, "ahead")
        let drawn = try makeAhead(ledger, ahead)
        let clock = MovableClock(now)
        let review = review(Wiring.store(path), clock: clock)
        await review.startSelected(noteIDs: [ahead.id], order: .asListed).value
        #expect(question(review)?.isPractice == true)

        clock.now = try #require(drawn.scheduled.due).addingTimeInterval(3_600)
        review.act(.grade(.again))
        try await Wiring.settle("the answer never landed") { self.summary(review) != nil }
        let reopened = try Ledger(path: path)
        #expect(try reopened.reviews(ofCard: drawn.id).map(\.kind) == [.graded, .practice],
                "a card drawn as practice was graded once it came due")
        #expect(try card(reopened, ahead) == drawn)
        #expect(summary(review)?.wasPractice == true)
    }

    // MARK: - The end of the sitting

    /// **The end of a Selected sitting counts what it left out, by reason, and what of the queue is
    /// still due** — never "all done" over the two due cards nobody selected.
    @Test func theEndOfASelectedSittingSaysWhatItLeftOutAndWhatIsStillDue() async throws {
        let (path, clean) = Wiring.scratch("selected-summary")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let chosen = try save(ledger, "chosen")
        try makeDue(ledger, chosen)
        let paused = try save(ledger, "paused")
        try makeDue(ledger, paused)
        try ledger.setPaused(true, ofCard: try card(ledger, paused).id)
        let proposal = try save(ledger, "proposal", proposal: true)
        let elsewhere = try save(ledger, "elsewhere", dictionary: "oxford")
        for word in ["other", "another"] { try makeDue(ledger, try save(ledger, word)) }
        let review = review(Wiring.store(path))
        await review.startSelected(noteIDs: [chosen.id, paused.id, proposal.id, elsewhere.id], order: .asListed).value

        #expect(question(review)?.batchSize == 1)
        _ = try await answerAll(review, .good)
        let end = try #require(summary(review))
        #expect(end.graded == 1)
        #expect(end.stillDue == 2, "the two due cards nobody selected were not said: \(end)")
        #expect(end.excluded == SittingExclusions(notAskable: 1, otherDictionary: 1, pausedOrHidden: 1), "\(end.excluded)")
    }

    /// **The Review pane opening does not replace a Selected sitting being drawn.** Showing Review is
    /// what the action does, and the pane resumes a sitting — or draws the queue's — when it appears;
    /// whichever finished last used to win. A queue draw already in flight loses to the selection too.
    @Test func aSelectedSittingInFlightIsNotReplacedByTheQueue() async throws {
        let (path, clean) = Wiring.scratch("selected-race")
        defer { clean() }
        let ledger = try Ledger(path: path)
        let notes = try ["alpha", "bravo", "charlie", "delta"].map { try save(ledger, $0) }
        for note in notes { try makeDue(ledger, note) }
        let chosen = [notes[0].id, notes[2].id]

        let review = review(Wiring.store(path))
        let drawing = review.startSelected(noteIDs: chosen, order: .asListed)
        await review.resume()
        await drawing.value
        try await Wiring.settle { self.question(review) != nil }
        #expect(question(review)?.batchSize == 2, "the pane's resume drew the queue over the selection")

        // **In flight, and finishing last**: the queue's draw reaches for the store first and is held
        // there until the selection has been drawn and shown, so it resumes over a newer sitting.
        let opening = Wiring.store(path)
        let asked = Asked()
        let second = ReviewModel(store: {
            asked.stores += 1
            guard asked.stores == 1, let held = opening() else { return opening() }
            return Task { await asked.gate(); return try await held.value }
        }, primary: { PrimaryDictionary(chosen: "noad") }, clock: { self.now }, defaults: TemporaryDefaults.suite())
        let queue = Task { await second.start() }
        try await Wiring.settle { asked.stores > 0 }
        await second.startSelected(noteIDs: chosen, order: .asListed).value
        try await Wiring.settle { self.question(second)?.batchSize == 2 }
        asked.open = true
        await queue.value
        #expect(question(second)?.batchSize == 2, "a queue draw already in flight landed over the selection")
    }

    // MARK: - The surface

    /// **Two controls in the selection's builder — as listed on ⌘R, in a random order on ⇧⌘R — and one
    /// disabled with its reason when nothing can be asked.** The toolbar and the right-click menu are
    /// that one builder, and ⌘R is bound nowhere else in the view layer.
    @Test func theSavedPaneOffersReviewSelectedWithItsKeys() throws {
        let view = try source("Sources/XiaolaiDictUI/LibraryView.swift")
        let start = try #require(view.range(of: "private func selectionActions"))
        let end = try #require(view.range(of: "struct PendingRemoval", range: start.upperBound..<view.endIndex))
        let builder = String(view[start.upperBound..<end.lowerBound])
        #expect(builder.contains("IconButton(.reviewSelected, title: \"Review ^[\\(reviewing) Meaning](inflect: true)\""))
        #expect(builder.contains("shortcut: KeyboardShortcut(\"r\", modifiers: .command)"))
        #expect(builder.contains("perform(.reviewSelected(.asListed), on: target.ids)"))
        #expect(builder.contains("IconButton(.reviewShuffled,"))
        #expect(builder.contains("shortcut: KeyboardShortcut(\"r\", modifiers: [.command, .shift])"))
        #expect(builder.contains("perform(.reviewSelected(.shuffled), on: target.ids)"))
        #expect(builder.contains("isEnabled: false"), "the control refuses a click instead of being disabled")
        #expect(builder.contains("help: Text("), "disabled without saying why")

        var bound = 0
        let walk = FileManager.default.enumerator(
            at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/XiaolaiDictUI"),
            includingPropertiesForKeys: nil)
        while let file = walk?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            bound += text.components(separatedBy: "KeyboardShortcut(\"r\"").count - 1
            bound += text.components(separatedBy: ".keyboardShortcut(\"r\"").count - 1
        }
        #expect(bound == 2, "R is bound \(bound) times in the view layer")
    }

    /// **A right-clicked card outside the selection is reviewable only if it is**, described from
    /// itself, as Confirm is.
    @Test func aRightClickedCardCountsItselfReviewableOnlyIfItIs() {
        func row(_ review: LibraryPresentation.Row.Review) -> LibraryPresentation.Row {
            LibraryPresentation.Row(id: UUID(), word: "fine", excerpt: "", marks: [], answer: "", status: nil,
                                    due: nil, review: review)
        }
        let yes = row(.askable), no = row(.notAskable), waiting = row(.heldBack), selected = row(.askable)
        let state = LibraryPresentation(rows: [yes, no, waiting, selected], total: 4, selection: [selected.id],
                                        reviewable: [selected.id])
        #expect(state.target(of: yes).reviewable == [yes.id])
        #expect(state.target(of: no).reviewable.isEmpty && state.target(of: no).heldBack == 0)
        #expect(state.target(of: waiting).reviewable.isEmpty && state.target(of: waiting).heldBack == 1,
                "a held-back card is described as waiting, not as blocked")
        #expect(state.target(of: selected) == state.selectionTarget)
        #expect(state.selectionTarget.reviewable == [selected.id])
    }

    /// **The end of a sitting draws every count the summary carries** — the reasons a Selected sitting
    /// left a meaning out, its practice answers, and its skips by mode — and the card says practice per
    /// card. A render cannot check a glass surface (AGENTS.md), so the source is read.
    @Test func theFinishedStateDrawsEveryCount() throws {
        let view = try source("Sources/XiaolaiDictUI/ReviewView.swift")
        let start = try #require(view.range(of: "private func finishedState"))
        let end = try #require(view.range(of: "public enum ReviewAction", range: start.upperBound..<view.endIndex))
        let finished = view[start.upperBound..<end.lowerBound]
        for count in ["excluded(summary.excluded)", "left.pausedOrHidden", "left.notAskable",
                      "left.otherDictionary", "left.siblings", "summary.practised",
                      "summary.skippedStillDue", "summary.skippedPractice", "summary.heldBack", "summary.stillDue"] {
            #expect(finished.contains(count), "the end of a sitting does not draw \(count)")
        }
        #expect(!finished.contains("summary.wasPractice ? "), "skips are worded by the sitting, not by the card")
        #expect(view.contains("if question.isPractice {"))
        let model = try source("Sources/XiaolaiDict/ReviewModel.swift")
        #expect(model.contains("isPractice: current.mode == .practice"), "the card is not told its own mode")
        #expect(!model.contains("private var isPractice"), "a sitting-wide flag decides the call")
    }
}
