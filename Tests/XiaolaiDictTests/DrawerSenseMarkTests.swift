import XiaolaiDictCore
import Testing

@testable import XiaolaiDictUI

/// What the drawer's sense badge claims.
///
/// **Three states, and the drawer knew two.** It marked with `?` every sense that was not
/// confirmed — so an entry where no sense was settled at all read "牛津英汉汉英词典 9 senses?",
/// and its tooltip said "The sense XiaolaiDict guessed". Nothing was guessed. The lookup card already told
/// the three apart through `SenseStanding`; the drawer had its own two-state rule, and the two
/// surfaces disagreed about the same lookup. The `?` is the selector's proposal and nothing else.
struct DrawerSenseMarkTests {
    private func note(ordinal: Int?, chosenBy: SenseChoice?) -> SenseNote {
        SenseNote(dictionary: "NOAD", ordinal: ordinal, outOf: 12, gloss: nil, chosenBy: chosenBy)
    }

    @Test func aSenseTheReaderTappedIsConfirmed() {
        #expect(note(ordinal: 4, chosenBy: .reader).standing == .confirmed(.reader))
    }

    @Test func theOnlySenseIsConfirmed() {
        #expect(note(ordinal: 1, chosenBy: .onlySense).standing == .confirmed(.onlySense))
    }

    @Test func aSenseTheSelectorProposedIsAProposal() {
        #expect(note(ordinal: 4, chosenBy: .model).standing == .proposed)
    }

    /// The case that was drawn wrong: no sense was settled, so nothing is claimed.
    @Test func anEntryWithNoSenseSettledClaimsNothing() {
        #expect(note(ordinal: nil, chosenBy: nil).standing == .unclaimed)
    }

    /// A sense recorded without saying who chose it is not promoted to a guess. The weakest
    /// standing is the default, as `SenseStanding` says.
    @Test func aSenseWithNoProvenanceClaimsNothing() {
        #expect(note(ordinal: 4, chosenBy: nil).standing == .unclaimed)
    }

    /// Only a proposal is marked as one.
    @Test func onlyAProposalCarriesTheQuestionMark() {
        #expect(note(ordinal: 4, chosenBy: .model).badge == "NOAD 4/12?")
        #expect(note(ordinal: 4, chosenBy: .reader).badge == "NOAD 4/12")
        #expect(note(ordinal: 1, chosenBy: .onlySense).badge == "NOAD 1/12")
        #expect(note(ordinal: nil, chosenBy: nil).badge == "NOAD 12 senses",
                "an unsettled entry was drawn as a guess")
    }

    /// And the words on hover are the lookup card's words for the same standing, so one lookup is
    /// never described two ways.
    @Test func theTooltipIsTheSharedDescription() {
        for standing: SenseStanding in [.confirmed(.reader), .confirmed(.onlySense), .proposed, .unclaimed] {
            #expect(!standing.explanation.isEmpty)
        }
        #expect(SenseStanding.unclaimed.explanation != SenseStanding.proposed.explanation)
    }
}
