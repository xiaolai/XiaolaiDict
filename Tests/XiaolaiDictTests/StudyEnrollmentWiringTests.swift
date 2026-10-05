import DictionaryModel
import Foundation
import Synchronization
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDict

/// **Assert the wire.** An enrollment API nothing calls is not a feature, and every test in
/// `StudyEnrollmentTests` would pass over a card whose button reaches nothing.
///
/// What is checked here is the path from the reader's action to a row: the recorder resolves which
/// lookup the action belongs to, the store builds the target from the encounter, and the ledger ends up
/// holding a note. The race is the interesting part — the panel is interactive seconds before the
/// lookup's row is written — and it is the same race the sense tap already lost once.
struct StudyEnrollmentWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")

    private func scratch() -> (String, () -> Void) {
        let path = ScratchFile.path("enrol")
        return (path, { ScratchFile.remove(path) })
    }

    private func recording(_ lemma: String = "fine") -> LookupRecording {
        LookupRecording(record: LookupRecord(
            surface: lemma, lemma: lemma, context: "He paid the \(lemma).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil),
            encounter: nil)
    }

    private func encounter(_ key: String? = "e1.001", chosenBy: SenseChoice? = .reader) -> SenseEncounter {
        SenseEncounter(
            dictionary: noad, entryID: "e1", senseKey: key,
            senseKeyKind: key == nil ? SenseKeyKind.none : .publisher,
            sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 4, senseHash: "h1",
            gloss: "a sum of money exacted as a penalty", chosenBy: chosenBy, chosenAt: now)
    }

    /// The store's own half: an encounter becomes a keyed target with the dictionary's answer behind it.
    /// **Through `keep`, the path the panel's enrol action takes** — the store's separate `enroll`
    /// had no caller but these two tests (audit-fix round 1), and went.
    @Test func thestoreBuildsAkeyedTargetFromAnEncounter() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let store = try LedgerStore(path: path)
        let lookup = try await store.record(recording())
        let note = try #require(try await store.keep(encounter(), for: lookup, language: "en", source: .manual))

        #expect(note.target == .sense(dictionary: "com.apple.dictionary.NOAD", entryID: "e1",
                                      senseKey: "e1.001", senseKeyKind: .publisher))
        #expect(note.issuer == .live, "the live path issued this key, and the note says so")
        let reopened = try Ledger(path: path)
        #expect(try reopened.notes().count == 1)
        #expect(try reopened.answer(of: note.id)?.origin == .dictionary)
        #expect(try reopened.readiness(of: note.id) == .ready)
    }

    /// A dictionary that marks no senses is studied at the entry rung rather than not at all.
    @Test func anUnkeyableSenseEnrolsAtTheEntryRung() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let store = try LedgerStore(path: path)
        let lookup = try await store.record(recording())
        let note = try #require(try await store.keep(encounter(nil, chosenBy: nil), for: lookup, language: "en",
                                                     source: .manual))
        #expect(note.target == .entry(dictionary: "com.apple.dictionary.NOAD", entryID: "e1"))
        // And it is not askable yet: the dictionary's own text is not a sense-specific answer.
        let reopened = try Ledger(path: path)
        #expect(try reopened.readiness(of: note.id) == .needsConfirmation)
    }

    /// **The race, which the sense tap already lost once.** The panel is interactive before the
    /// lookup's row exists, so an enrollment arriving first must wait for *its own* lookup rather than
    /// attaching to whatever was recorded last — that would file the reader's card under the previous
    /// word, silently.
    @Test func anEnrollmentMadeBeforeTheRowExistsWaitsForItsOwnLookup() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let recorder = await LookupRecorder()
        await recorder.start { try LedgerStore(path: path) }
        _ = try await #require(recorder.store).value

        // Request 7's row does not exist yet.
        await recorder.enrol(encounter(), request: 7, language: "en")
        #expect(await recorder.heldTaps == 1, "an enrollment with no row must be held, not dropped")
        // An unrelated lookup lands first. Nothing may attach to it.
        await recorder.record(recording("hold"), request: 6)
        let afterStranger = try Ledger(path: path)
        #expect(try afterStranger.notes().isEmpty, "the enrollment attached itself to another word")

        await recorder.record(recording("fine"), request: 7)
        let ledger = try await Self.waiting(at: path) { try $0.notes().count == 1 }
        let note = try #require(try ledger.notes().first)
        #expect(try ledger.lookupIDs(evidencing: note.id).count == 1)
    }

    /// **A held enrolment keeps the language it was made under** (audit round 3, #21). The row's
    /// drain wrote it under the lookup's language instead — and a note's language is part of its
    /// identity, so the card the reader made was not the card that was written.
    @Test func aHeldEnrolmentIsWrittenUnderItsOwnLanguage() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let recorder = await LookupRecorder()
        await recorder.start { try LedgerStore(path: path) }
        _ = try await #require(recorder.store).value
        await recorder.enrol(encounter(), request: 7, language: "zh-Hans")
        await recorder.record(recording("fine"), request: 7)
        let ledger = try await Self.waiting(at: path) { try $0.notes().count == 1 }
        #expect(try ledger.notes().first?.language == "zh-Hans", "the held enrolment took the lookup's language")
    }

    /// **Save keys its note by the lookup's language, through the app's own wire** (audit-fix round 3,
    /// #5). A note's language is part of its identity (ADR-0029). The panel's Save handed the recorder no
    /// language, so the note was written under `unknown` — while a tap on the same meaning, and automatic
    /// keeping, write it under the language the lookup recorded. One meaning became two notes, and the
    /// reader's progress was split between them.
    @MainActor
    @Test func savingFromThePanelKeysTheNoteByTheLookupsLanguage() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite))
        app.recorder.start { try LedgerStore(path: path) }
        _ = try await #require(app.recorder.store).value
        await app.recorder.record(recording(), request: 1)
        let save = try #require(app.panelController.onEnrolSense, "the panel's Save reaches nothing")
        save(encounter(), 1)
        await app.recorder.settled(request: 1)
        // The same meaning tapped afterwards: one note, under one language.
        let tap = try #require(app.panelController.onStudySense, "the panel's tap reaches nothing")
        tap(encounter(), 1)
        await app.recorder.settled(request: 1)
        let notes = try Ledger(path: path).notes()
        #expect(notes.map(\.language) == ["en"], "Save keyed the note by \(notes.map(\.language)), not the lookup's language")
    }

    /// **How a lookup ended, three ways** (audit round 3, #39): its row is in the ledger, its row was
    /// handed over and failed, or nothing was ever handed over. The second used to read as the third.
    @Test func aLookupsEndingIsRecordedNotRecordedOrDropped() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let attempts = Mutex(0)
        let recorder = await LookupRecorder()
        await recorder.start {
            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw CocoaError(.fileLocking) }
            return try LedgerStore(path: path)
        }
        #expect(await recorder.ending(request: 9) == nil, "a lookup never handed over was given a ledger ending")
        await recorder.record(recording(), request: 3)
        #expect(await recorder.ending(request: 3) == .notRecorded, "a failed write read as never attempted")
        await recorder.retry(request: 3)
        await recorder.settled(request: 3)
        #expect(await recorder.ending(request: 3) == .recorded)
    }

    /// Enrolling writes the encounter **as well as** the note: the reader met the sense and asked to
    /// study it, and the ledger keeps those apart rather than inferring one from the other.
    @Test func enrollingAlsoRecordsThatTheSenseWasMet() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let recorder = await LookupRecorder()
        await recorder.start { try LedgerStore(path: path) }
        _ = try await #require(recorder.store).value
        await recorder.record(recording(), request: 1)
        await recorder.enrol(encounter(), request: 1, language: "en")
        // The enrolment's write, awaited — not the ledger polled against a clock.
        await recorder.settled(request: 1)
        let ledger = try Ledger(path: path)
        #expect(try ledger.notes().count == 1, "the enrolment was not written")
        #expect(try ledger.encounters(ofLookup: 1).count == 1, "the meeting is evidence in its own right")
    }

    /// **Retry writes a held tap whose row was never written.** The reader enrolled before the row
    /// existed; the ledger then failed to open. Retry used to re-hold the tap and stop, and neither
    /// the row nor the note was ever written. Red if Retry only re-enqueues the tap.
    @Test func retryWritesAHeldTapWhoseRowWasNeverWritten() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let attempts = Mutex(0)
        let recorder = await LookupRecorder()
        await recorder.start {
            if attempts.withLock({ $0 += 1; return $0 }) == 1 { throw CocoaError(.fileLocking) }
            return try LedgerStore(path: path)
        }
        await recorder.enrol(encounter(), request: 3, language: "en")
        await recorder.record(recording(), request: 3)
        #expect(await recorder.states[3] == .failed, "the failed opening was not reported")
        await recorder.retry(request: 3)
        await recorder.settled(request: 3)
        let ledger = try Ledger(path: path)
        #expect(try ledger.notes().count == 1, "Retry did not write the enrolment held for the row")
    }

    /// **Waits for the row, never for a duration.** The recorder starts its write in a task of its
    /// own, so the caller's `await` returns before anything is on disk. A sleep long enough to pass
    /// here is a sleep that asserts this machine's load; the condition is what is actually meant, and
    /// a bound on the attempts is what stops a failure hanging instead of failing.
    private static func waiting(at path: String,
                               for condition: (Ledger) throws -> Bool) async throws -> Ledger {
        let ledger = try Ledger(path: path)
        for _ in 0..<400 {
            if try condition(ledger) { return ledger }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the write never landed")
        return ledger
    }
}
