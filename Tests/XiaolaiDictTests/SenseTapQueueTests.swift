import Testing
@testable import XiaolaiDict
import XiaolaiDictCore

/// **Which lookup a reader's tap belongs to.** The entry is interactive as soon as it is drawn, and
/// its ledger row is written only once the selector has decided — seconds later on the local model's
/// rung. Hanging a tap off whatever was recorded last files a study item under the previous word,
/// with nothing to say it happened.
struct SenseTapQueueTests {
    private static func encounter(_ key: String) -> SenseEncounter {
        SenseEncounter(
            dictionary: DictionaryIdentity(name: "NOAD", identifier: "com.apple.dictionary.NOAD"),
            entryID: "m_en_gbus0123456", senseKey: key, senseKeyKind: .publisher,
            sensePath: SensePath(block: 1, ordinal: 4), entrySenseCount: 12,
            senseHash: key, gloss: "a meaning", chosenBy: .reader, chosenAt: .now)
    }

    /// A tap before its own row exists is held, and written the moment that row lands.
    @Test func aTapBeforeItsRowIsHeldUntilTheRowArrives() {
        var taps = SenseTapQueue()
        #expect(taps.tapped(Self.encounter("s1"), request: 7) == nil, "a tap was written to a row that did not exist")
        #expect(taps.heldCount == 1)
        #expect(taps.recorded(request: 7, id: 42).count == 1)
        #expect(taps.heldCount == 0)
        // Once the row is there, the next tap goes straight to it.
        #expect(taps.tapped(Self.encounter("s2"), request: 7) == 42)
    }

    /// **A tap never attaches to another lookup's row.** The previous word's row is recorded and the
    /// reader taps a sense in the panel that is up now: held, not written to the old one.
    @Test func aTapIsNeverWrittenToAnotherLookupsRow() {
        var taps = SenseTapQueue()
        _ = taps.recorded(request: 1, id: 10)
        #expect(taps.tapped(Self.encounter("s1"), request: 2) == nil)
        #expect(taps.recorded(request: 2, id: 11).count == 1)
    }

    /// A superseded lookup is still recorded — its entry was on screen — but its row landing late
    /// must not become what the next tap attaches to.
    @Test func aLateRowDoesNotBecomeWhatTheNextTapAttachesTo() {
        var taps = SenseTapQueue()
        _ = taps.recorded(request: 5, id: 50)
        _ = taps.recorded(request: 4, id: 40)  // the older lookup's row, arriving afterwards
        #expect(taps.lastLookup?.id == 50, "an older row became the newest lookup")
        #expect(taps.tapped(Self.encounter("s1"), request: 5) == 50)
    }

    /// A lookup that is never recorded cannot grow the list for ever.
    @Test func whatIsHeldIsBounded() {
        var taps = SenseTapQueue()
        for i in 0..<(SenseTapQueue.mostHeld + 10) {
            #expect(taps.tapped(Self.encounter("s\(i)"), request: 99) == nil)
        }
        #expect(taps.heldCount == SenseTapQueue.mostHeld)
    }
}
