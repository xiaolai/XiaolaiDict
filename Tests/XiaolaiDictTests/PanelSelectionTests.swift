import Testing
import XiaolaiDictCore

@testable import XiaolaiDictUI

/// **The panel's own decision, which nothing used to test.**
///
/// `LookupPanelContent` held the reader's tap as view `@State` and answered three questions about
/// it inside its body: which entry a tap belongs to, what the card draws, and whether the
/// selector's late proposal still changes anything. No test file mentioned the view, so all three
/// could regress green — and two of them were defects found by hand in the pass before this one: a
/// tap filed under the wrong lookup, and a tap in an auxiliary entry overriding the primary mark.
///
/// The fixtures collide on purpose. Two entries carrying the **same** sense key is the shape the
/// bug had: a key alone says nothing about which dictionary issued it, so a selection held as one
/// value confirms a sense the reader never looked at.
struct PanelSelectionTests {
    /// One entry, keyed by **position** — `1.1`, which is what a dictionary that numbers nothing
    /// issues, and which therefore collides across dictionaries as a publisher's id never would.
    private static func entry(
        _ name: String, identifier: String, entryID: String, key: String = "1.1"
    ) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: DictionaryIdentity(name: name, identifier: identifier),
            headword: "fine", lookedUp: "fine", html: "<p/>",
            document: EntryDocument(
                isStyled: true, entryID: entryID, homograph: nil,
                blocks: [SenseBlock(number: 1, partOfSpeech: "adjective", senses: [
                    DictionarySense(
                        path: SensePath(block: 1, ordinal: 1), key: key, keyKind: .position,
                        definition: "of high quality", text: "of high quality"),
                ])]))
    }

    private static let primary = entry("NOAD", identifier: DictionaryIdentity.noad, entryID: "e1")
    private static let auxiliary = entry("譯典通", identifier: "com.apple.dictionary.DrEye", entryID: "e1")
    /// The other half of the identity: one dictionary answers a word with several entries, and
    /// *fine* the penalty is not *fine* the adjective.
    private static let homograph = entry("NOAD", identifier: DictionaryIdentity.noad, entryID: "e2")

    /// Computed, not stored: `SenseMark` is not `Sendable`, so a static constant of one is a
    /// shared-mutable-state error rather than a fixture.
    private static var proposal: SenseMark { .chosen(key: "1.1", by: .model) }

    /// The fixture has to actually collide, or the test below cannot catch what it is for.
    @Test func thetwoEntriesCarryTheSameSenseKey() {
        #expect(Self.primary.senses.first?.key == "1.1")
        #expect(Self.auxiliary.senses.first?.key == "1.1")
        #expect(Self.primary.entryKey == Self.auxiliary.entryKey,
                "even the entry ids collide, which is what leaves the dictionary doing the separating")
    }

    /// **A tap belongs to the entry it was made in.** Held as one value, tapping a sense in the
    /// auxiliary dictionary redrew the primary card's guess as a fact the reader had confirmed —
    /// and copy, pin, translation and explanation would all then carry it.
    @Test func atapInOneEntryLeavesAnotherShowingTheSelectorsProposal() {
        var selection = PanelSelection()
        selection.choose("1.1", in: Self.auxiliary)

        let owner = PanelSelection.identity(of: Self.primary)
        #expect(
            selection.mark(for: Self.auxiliary, proposing: Self.proposal, ownedBy: owner)
                == .chosen(key: "1.1", by: .reader),
            "the reader's own tap must outrank a proposal, even one made elsewhere")
        #expect(
            selection.mark(for: Self.primary, proposing: Self.proposal, ownedBy: owner) == Self.proposal,
            "the tap in the auxiliary entry became the primary entry's mark")
        // **Changed with the contract.** This used to expect the proposal here as well, which was
        // the defect written down as behaviour: a positional key is `block.ordinal`, so every
        // entry has a `"1.1"`, and the primary's answer drawn on a homograph is the right sense of
        // the wrong word — shown, and offered for study.
        #expect(
            selection.mark(for: Self.homograph, proposing: Self.proposal, ownedBy: owner) == nil,
            "the primary entry's proposal was drawn on another entry of the same dictionary")
    }

    /// A proposal with no owner reaches nothing. Nil means the resolver marked nothing — there is
    /// no entry it could be about.
    @Test func anUnownedProposalIsShownNowhere() {
        let selection = PanelSelection()
        for entry in [Self.primary, Self.auxiliary, Self.homograph] {
            #expect(selection.mark(for: entry, proposing: Self.proposal, ownedBy: nil) == nil)
        }
    }

    /// Both halves of the identity do work, so neither can be dropped.
    @Test func anidentityIsTheDictionaryAndTheEntryTogether() {
        #expect(PanelSelection.identity(of: Self.primary) != PanelSelection.identity(of: Self.auxiliary),
                "two dictionaries' entries share an identity, so a key from one confirms a sense in the other")
        #expect(PanelSelection.identity(of: Self.primary) != PanelSelection.identity(of: Self.homograph),
                "two entries of one dictionary share an identity")
        #expect(PanelSelection.identity(of: Self.primary) == PanelSelection.identity(of: Self.primary))
    }

    /// **The selector answers late, and the card is already on screen.** Where the reader has
    /// chosen, that answer must not reach the card: clearing on it threw away a translation they
    /// had asked for *after* choosing, and redrew their own fact as XiaolaiDict's guess.
    @Test func alateProposalDoesNotDisplaceTheReadersOwnChoice() {
        var selection = PanelSelection()
        selection.choose("1.1", in: Self.primary)

        #expect(selection.hasChosen(in: Self.primary))
        #expect(selection.mark(for: Self.primary, proposing: .chosen(key: "1.2", by: .model), ownedBy: PanelSelection.identity(of: Self.primary))
            == .chosen(key: "1.1", by: .reader))
        #expect(selection.mark(for: Self.primary, proposing: .couldNot(.tooClose), ownedBy: PanelSelection.identity(of: Self.primary))
            == .chosen(key: "1.1", by: .reader))
    }

    /// And where they have not, it does — otherwise the card would sit on "could not be identified"
    /// for the whole of a lookup the selector went on to answer.
    @Test func withNoTapTheLateProposalIsWhatTheCardDraws() {
        var selection = PanelSelection()
        #expect(!PanelSelection().hasChosen(in: Self.primary))
        #expect(PanelSelection().mark(for: Self.primary, proposing: Self.proposal, ownedBy: PanelSelection.identity(of: Self.primary)) == Self.proposal)
        #expect(PanelSelection().mark(for: Self.primary, proposing: nil, ownedBy: PanelSelection.identity(of: Self.primary)) == nil,
                "a mark appeared where neither the reader nor the selector had chosen one")

        // A tap somewhere else is not a tap here.
        selection.choose("1.1", in: Self.auxiliary)
        #expect(!selection.hasChosen(in: Self.primary))
        #expect(selection.mark(for: Self.primary, proposing: Self.proposal, ownedBy: PanelSelection.identity(of: Self.primary)) == Self.proposal)
    }
}

/// Which entry the card opens on.
@MainActor
struct OpeningEntryTests {
    private func presentation(primaryIsSecond: Bool) -> LookupPresentation {
        let first = sampleEntry("Oxford Thesaurus")
        let second = sampleEntry("New Oxford American Dictionary")
        var presentation = LookupPresentation(
            request: 1, term: "fine", lemma: Lemma(text: "fine", basis: .tagger), source: nil,
            capture: .accessibility(.accessibilityTextRange, context: .complete), outcome: nil)
        presentation.outcome = .entries(NonEmpty([first, second])!, unreadable: [])
        if primaryIsSecond { presentation.primaryEntry = PanelSelection.identity(of: second) }
        return presentation
    }

    /// **The defect's exact shape.** The service returns the thesaurus first; the reader's primary
    /// is NOAD. The card used to open on index 0 under a comment promising the primary came first,
    /// so the dictionary on screen and the dictionary whose sense was resolved and written to the
    /// ledger were different ones.
    @Test func theCardOpensOnThePrimaryEvenWhenTheServiceReturnsItSecond() {
        let view = LookupPanelContent(presentation: presentation(primaryIsSecond: true))
        #expect(view.opening == 1, "the card opened on the service's first entry, not the primary's")
    }

    /// With no primary named — the primary answered with nothing — service order is the only order
    /// there is, and the card says so by opening at the front rather than guessing.
    @Test func withNoPrimaryTheCardOpensAtTheFront() {
        let view = LookupPanelContent(presentation: presentation(primaryIsSecond: false))
        #expect(view.opening == 0)
    }
}

/// The signals the card holds and used to keep to itself.
struct PanelCaveatTests {
    /// **A miss and an unanswered question are not the same result.** Both drew "No entry … in
    /// your dictionaries" — a confirmed absence — so a crashed service with the public fallback
    /// also finding nothing told the reader their dictionaries do not have the word.
    @Test func aServiceFailureIsNotAConfirmedMiss() {
        #expect(PanelCaveats.serviceUnanswered(.notFound(serviceFailure: "the service crashed")))
        #expect(!PanelCaveats.serviceUnanswered(.notFound(serviceFailure: nil)),
                "a genuine miss must not be dressed up as a failure either")
        #expect(PanelCaveats.serviceUnanswered(.plainText("fine", serviceFailure: "crashed")))
        #expect(!PanelCaveats.serviceUnanswered(.plainText("fine", serviceFailure: "")))
        #expect(!PanelCaveats.serviceUnanswered(nil))
    }

    /// **A doubted optical read is marked; a confident one is not.**
    ///
    /// The first version of this keyed on source alone, so three quarters of optical reads — every
    /// one of them correct in the measured sample — got a full-width orange banner above the
    /// answer. Warning about those is how a reader learns to ignore the warning that matters.
    ///
    /// The measured pair: `xiaolai` misread as "xaiolai" at 0.5, and *Agentic* read correctly at
    /// 1.0. Both are asserted, because a predicate that fired on neither would also pass a test
    /// that only checked the first.
    @Test func onlyADoubtedOpticalCaptureIsMarked() {
        let misread = CaptureQuality(source: .opticalRecognition, confidence: 0.5, context: .complete)
        let clean = CaptureQuality(source: .opticalRecognition, confidence: 1, context: .complete)
        #expect(PanelCaveats.readOffTheScreen(misread))
        #expect(!PanelCaveats.readOffTheScreen(clean), "a confident optical read was warned about")

        for source in CaptureQuality.Source.allCases where source != .opticalRecognition {
            #expect(
                !PanelCaveats.readOffTheScreen(
                    CaptureQuality(source: source, confidence: 0.5, context: .complete)),
                "\(source) was marked as read off the screen")
        }
        #expect(!PanelCaveats.readOffTheScreen(nil))
    }

    /// The reader can turn it off, and then nothing is marked however doubtful.
    @Test func theReaderCanSilenceIt() {
        let misread = CaptureQuality(source: .opticalRecognition, confidence: 0.3, context: .complete)
        #expect(PanelCaveats.readOffTheScreen(misread, warning: true))
        #expect(!PanelCaveats.readOffTheScreen(misread, warning: false))
    }

    /// The threshold sits in an empty gap, which is what lets it be stated from twenty readings.
    /// If a future distribution puts values between 0.5 and 1.0, this is the assumption to re-read.
    @Test func theThresholdSitsBetweenTheTwoMeasuredClusters() {
        #expect(CaptureQuality.doubtful > 0.5, "0.5 reads, where both misreads were, must be marked")
        #expect(CaptureQuality.doubtful < 1.0, "1.0 reads, all correct in the sample, must not be")
    }
}
