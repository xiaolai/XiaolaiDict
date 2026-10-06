@testable import DictionaryModel
import Foundation
import Testing
import XiaolaiDictTestSupport

/// **The table's judgement, with the tagger's answer given rather than asked for** — so each rule is a
/// case here and no test depends on what `NLTagger` happens to say on this macOS.
struct FormTableJudgementTests {
    typealias Reading = FormTable.Reading

    static func table() -> FormTable {
        FormTable(
            sources: ["fixture"],
            forms: [
                "swore": [Reading(lemma: "swear", partOfSpeech: "verb")],
                "broke": [Reading(lemma: "break", partOfSpeech: "verb")],
                "found": [Reading(lemma: "find", partOfSpeech: "verb")],
                "leaves": [Reading(lemma: "leaf", partOfSpeech: "noun")],
                "mice": [Reading(lemma: "mouse", partOfSpeech: "noun")],
                "lay": [Reading(lemma: "lie", partOfSpeech: "verb")],
                "axes": [Reading(lemma: "axe", partOfSpeech: "noun"), Reading(lemma: "axis", partOfSpeech: "noun")],
                "rose": [Reading(lemma: "rise", partOfSpeech: "verb"), Reading(lemma: "rose", partOfSpeech: "noun")],
                "dresses": [Reading(lemma: "dress", partOfSpeech: "noun")],
            ],
            ownHeadwords: ["found", "lay", "rose"])
    }

    /// 1. The tagger agrees with a printed reading.
    @Test func aTaggerAnswerThePrintedReadingAgreesWithStands() {
        #expect(Self.table().judge("mice", tagged: "mouse", partOfSpeech: "noun") == .keep)
    }

    /// 2. Oxford prints what is awkward, not what is regular: silence about `leave` is no contradiction.
    @Test func aRegularReadingTheDictionaryDoesNotPrintIsNotContradicted() {
        #expect(Self.table().judge("leaves", tagged: "leave", partOfSpeech: "verb") == .keep)
    }

    /// 3. A different word that is neither printed nor regular — `broke` → `brake`.
    @Test func aWordNothingLeadsToIsRefusedInFavourOfThePrintedOne() {
        #expect(Self.table().judge("broke", tagged: "brake", partOfSpeech: "verb") == .lemma("break"))
        #expect(Self.table().judge("dresses", tagged: "dresser", partOfSpeech: "noun") == .lemma("dress"))
    }

    @Test func whereTheDictionaryPrintedSeveralHeadwordsTheContradictionIsUnresolvedNotGuessed() {
        #expect(Self.table().judge("axes", tagged: "axet", partOfSpeech: "noun") == .unresolved)
    }

    /// 4. The tagger gave nothing, or left the form unchanged.
    @Test(arguments: [String?.none, "swore"])
    func aGapIsFilledWhereTheFormIsNotAWordInItsOwnRight(tagged: String?) {
        #expect(Self.table().judge("swore", tagged: tagged, partOfSpeech: "verb") == .lemma("swear"))
    }

    /// **The invariant the own-headword flag exists for**: `found` is the past of *find* and a verb that
    /// means to establish, and only the sentence says which.
    @Test(arguments: ["found", "lay", "rose"])
    func aFormThatIsAlsoAHeadwordIsNeverFilled(form: String) {
        #expect(Self.table().judge(form, tagged: form, partOfSpeech: "verb") == .keep)
        #expect(Self.table().judge(form, tagged: nil, partOfSpeech: nil) == .keep)
    }

    /// The tagger's word class for a word it does not know is poor — measured, it called `swore` a noun —
    /// so a class that fits nothing is ignored where the dictionary printed one headword.
    @Test func aClassThatFitsNothingDoesNotRemoveTheOnlyReading() {
        #expect(Self.table().judge("swore", tagged: nil, partOfSpeech: "noun") == .lemma("swear"))
    }

    @Test func theClassChoosesBetweenReadingsAndNeverAddsOne() {
        let table = FormTable(sources: [], forms: [
            "rises": [Reading(lemma: "rise", partOfSpeech: "verb"), Reading(lemma: "rises", partOfSpeech: "noun")],
            "saws": [Reading(lemma: "saw", partOfSpeech: "verb"), Reading(lemma: "sawe", partOfSpeech: "noun")],
        ], ownHeadwords: [])
        #expect(table.judge("saws", tagged: nil, partOfSpeech: "verb") == .lemma("saw"))
        #expect(table.judge("saws", tagged: nil, partOfSpeech: "noun") == .lemma("sawe"))
        #expect(table.judge("saws", tagged: nil, partOfSpeech: nil) == .keep, "two readings and no class decides nothing")
    }

    @Test func aFormTheTableDoesNotListIsTheTaggersAlone() {
        #expect(Self.table().judge("walked", tagged: "walk", partOfSpeech: "verb") == .keep)
        #expect(Self.table().judge("walked", tagged: nil, partOfSpeech: "verb") == .keep)
    }

    @Test func anEntryThatSaysNothingIsDroppedAtConstruction() {
        let table = FormTable(sources: [], forms: [
            "same": [Reading(lemma: "same", partOfSpeech: "verb")], "none": [], "": [Reading(lemma: "x", partOfSpeech: "")],
            "blank": [Reading(lemma: "", partOfSpeech: "")],
        ], ownHeadwords: [])
        #expect(table.count == 0)
    }

    @Test func lookupIsCanonical() {
        #expect(Self.table().entry(for: "SWORE") != nil)
    }
}

struct RegularInflectionTests {
    @Test(arguments: [
        ("walked", "walk"), ("walks", "walk"), ("walking", "walk"), ("faster", "fast"), ("fastest", "fast"),
        ("makes", "make"), ("making", "make"), ("liked", "like"), ("carries", "carry"), ("carried", "carry"),
        ("happier", "happy"), ("abetted", "abet"), ("abetting", "abet"), ("travelled", "travel"),
        ("busses", "bus"), ("picnicking", "picnic"), ("boxes", "box"), ("leaves", "leave"),
    ])
    func aRegularFormIsRecognised(form: String, lemma: String) {
        #expect(RegularInflection.isInflection(form, of: lemma))
    }

    @Test(arguments: [("broke", "brake"), ("dresses", "dresser"), ("mice", "mouse"), ("went", "go"), ("walk", "walk"), ("x", "")])
    func anIrregularOrUnrelatedFormIsNot(form: String, lemma: String) {
        #expect(!RegularInflection.isInflection(form, of: lemma))
    }
}

struct FormTableCodecTests {
    typealias Reading = FormTable.Reading

    static func sample() -> FormTable {
        FormTable(sources: ["a\t1", "inflections/2"], forms: [
            "swore": [Reading(lemma: "swear", partOfSpeech: "verb")],
            "lay": [Reading(lemma: "lie", partOfSpeech: "verb"), Reading(lemma: "lay", partOfSpeech: "noun")],
            "chassés": [Reading(lemma: "chassé", partOfSpeech: "")],
        ], ownHeadwords: ["lay"])
    }

    @Test func aTableSurvivesTheRoundTripWithItsSourcesAndFlags() throws {
        let table = Self.sample()
        let decoded = try #require(FormTable(decoding: table.encoded()))
        #expect(decoded == table)
        #expect(decoded.entry(for: "lay")?.isOwnHeadword == true)
        #expect(decoded.entry(for: "swore")?.isOwnHeadword == false)
        #expect(decoded.sources == ["a\t1", "inflections/2"])
    }

    @Test func theSameTableEncodesToTheSameBytes() {
        #expect(Self.sample().encoded() == Self.sample().encoded())
    }

    @Test func aTableOfAnotherVersionOrCutShortIsRefusedNotGuessedAt() {
        let text = Self.sample().encoded()
        #expect(FormTable(decoding: text.replacingOccurrences(of: FormTable.formatVersion, with: "forms/0")) == nil)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(FormTable(decoding: lines.dropLast().joined(separator: "\n")) == nil, "a cut file was read as current")
        #expect(FormTable(decoding: "") == nil)
        #expect(FormTable(decoding: "forms/2\tx\ty\tz") == nil)
    }

    /// A header claiming `Int.max` lines must be refused, not trap on the sum in a process lookups run in.
    @Test(arguments: ["forms/2\t9223372036854775807\t0\t0", "forms/2\t0\t9223372036854775807\t1", "forms/2\t1\t1\t9223372036854775807"])
    func aHeaderClaimingMoreLinesThanExistIsRefusedWithoutTrapping(header: String) {
        #expect(FormTable(decoding: header + "\nx") == nil)
    }

    @Test func aMalformedFormLineIsRefused() {
        #expect(FormTable(decoding: "forms/2\t0\t1\t0\nswore\t1") == nil)
        #expect(FormTable(decoding: "forms/2\t0\t1\t0\nswore\t2\tverb:swear") == nil)
        #expect(FormTable(decoding: "forms/2\t0\t1\t0\nswore\t0\tverbswear") == nil)
    }

    @Test func aFormCarryingATabIsSkippedNotEscaped() throws {
        let table = FormTable(sources: [], forms: [
            "bad\tform": [Reading(lemma: "x", partOfSpeech: "")], "ok": [Reading(lemma: "y", partOfSpeech: "")],
        ], ownHeadwords: [])
        let decoded = try #require(FormTable(decoding: table.encoded()))
        #expect(decoded.count == 1 && decoded.entry(for: "ok") != nil)
    }
}

struct FormAuthorityTests {
    private func table(_ lemma: String) -> FormTable {
        FormTable(sources: [lemma], forms: ["swore": [.init(lemma: lemma, partOfSpeech: "verb")]], ownHeadwords: [])
    }

    @Test func aProcessThatNeverInstallsASourceHasNoTable() {
        #expect(FormAuthority().table == nil)
    }

    @Test func theStoredTableIsReadWhenASourceIsInstalled() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(table("swear"))
        let authority = FormAuthority()
        authority.use(store)
        #expect(authority.table?.entry(for: "swore")?.readings.first?.lemma == "swear")
    }

    /// **How the app, in another process, comes to see what the service built** — without being restarted.
    @Test func aFileWrittenAfterwardsIsFoundByRefresh() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let authority = FormAuthority()
        authority.use(store)
        #expect(authority.table == nil, "nothing is stored yet")
        try store.write(table("swear"))
        authority.refresh()
        #expect(authority.table != nil)
        try store.write(FormTable(sources: ["second"], forms: [
            "swore": [.init(lemma: "swearing", partOfSpeech: "verb")], "x": [.init(lemma: "y", partOfSpeech: "")],
        ], ownHeadwords: []))
        authority.refresh()
        #expect(authority.table?.sources == ["second"])
    }

    /// Losing a lemma source mid-session would move a word's ledger key for no reason the reader can see.
    @Test func aFileThatGoesAwayOrIsGarbageLeavesTheTableInForce() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(table("swear"))
        let authority = FormAuthority()
        authority.use(store)
        try Data("not a table".utf8).write(to: store.file)
        authority.refresh()
        #expect(authority.table?.sources == ["swear"])
        try FileManager.default.removeItem(at: store.file)
        authority.refresh()
        #expect(authority.table?.sources == ["swear"])
    }

    /// **A lookup must not wait for the read**, so the background refresh answers later and the foreground one
    /// is a `stat`. The wait here is for the work, not the call, with a deadline only so a hang fails: a utility queue behind a saturated suite on a loaded Mac took over 30 s once.
    @Test func aBackgroundRefreshFindsTheFileWithoutBlocking() async throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let authority = FormAuthority()
        authority.use(store)
        try store.write(table("swear"))
        authority.refreshInBackground()
        let deadline = ContinuousClock.now + .seconds(180)
        while authority.table == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(authority.table?.sources == ["swear"])
    }

    /// **A file that could not be read is tried again**; permissions recover where a bad table does not.
    @Test func anUnreadableFileIsRetriedAndAnInvalidOneIsNot() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(table("swear"))
        let authority = FormAuthority()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.file.path)
        authority.use(store)
        #expect(authority.table == nil, "premise: unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        authority.refresh()
        #expect(authority.table?.sources == ["swear"], "the stamp was acknowledged although nothing was read")
    }

    /// **A lookup waits for the first read, bounded**, and not at all where nothing was installed.
    @Test func settledWaitsForTheInitialReadAndIsImmediateOtherwise() async throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(table("swear"))
        let authority = FormAuthority()
        #expect(await authority.settled(within: .seconds(5)) == .idle)
        #expect(authority.table == nil, "nothing installed, nothing waited for")
        authority.useInBackground(store)
        let ended = await authority.settled(within: .seconds(180))
        #expect(ended == .finished || ended == .idle, "the wait timed out: \(ended)")
        #expect(authority.table?.sources == ["swear"])
    }

    /// **Only the latest load clears the wait**, and the older one's result is not put over the newer's.
    @Test func twoOverlappingBackgroundLoadsEndWithTheLaterOne() async throws {
        let first = TemporaryDirectory(), second = TemporaryDirectory()
        let storeA = FormTableStore(directory: first.url), storeB = FormTableStore(directory: second.url)
        try storeA.write(table("a"))
        try storeB.write(table("b"))
        let authority = FormAuthority()
        authority.useInBackground(storeA)
        authority.useInBackground(storeB)
        let ended = await authority.settled(within: .seconds(180))
        #expect(ended != .timedOut)
        #expect(authority.table?.sources == ["b"], "got \(String(describing: authority.table?.sources))")
    }

    /// **A read overtaken by `publish` or `use` is dropped, not put over what replaced it.**
    @Test func aReadOvertakenByPublishOrUseIsDropped() async throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let authority = FormAuthority()
        authority.use(store)
        try store.write(table("from-file"))
        authority.refresh { authority.publish(self.table("published")) }
        #expect(authority.table?.sources == ["published"], "the older read overwrote the newer table")

        let other = TemporaryDirectory()
        let elsewhere = FormTableStore(directory: other.url)
        try store.write(FormTable(sources: ["second-file"], forms: ["x": [.init(lemma: "y", partOfSpeech: "")]], ownHeadwords: []))
        // `useInBackground`, not `use`: the seam runs inside the read lock, which `use` would wait on for ever.
        authority.refresh { authority.useInBackground(elsewhere) }
        _ = await authority.settled(within: .seconds(180))
        #expect(authority.table?.sources == ["published"], "a read from a superseded store was committed")
    }

    /// **A table put in force while a load is running releases the wait**; otherwise the load's completion no
    /// longer matches and every later wait runs to its limit.
    @Test(arguments: [0, 1, 2]) func aSupersedingPublishOrUseReleasesTheWait(kind: Int) async throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(table("loading"))
        let authority = FormAuthority()
        authority.useInBackground(store)
        switch kind {
        case 0: authority.publish(table("published"))
        case 1: authority.use(store)
        default: authority.useInBackground(store)
        }
        let ended = await authority.settled(within: .seconds(180))
        #expect(ended != .timedOut)
    }

    @Test func theRevisionMovesWhenTheTableInForceDoes() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let authority = FormAuthority()
        let start = authority.revision
        authority.publish(table("a"))
        #expect(authority.revision > start)
        let afterPublish = authority.revision
        authority.refresh()
        #expect(authority.revision == afterPublish, "nothing installed, nothing read")
        authority.use(store)
        try store.write(table("b"))
        authority.refresh()
        #expect(authority.revision > afterPublish)
        let afterRead = authority.revision
        authority.refresh()
        #expect(authority.revision == afterRead, "a file that has not moved is not read again")
    }

    @Test func aPublishedTableIsInForceWithoutAFile() {
        let authority = FormAuthority()
        authority.publish(table("swear"))
        #expect(authority.table?.count == 1)
    }

    @Test func nothingIsLeftBesideTheTableAfterAWrite() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(table("a"))
        try store.write(table("b"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path) == ["forms.table"])
    }
}

/// **The regular inflection the dictionary does not print** — `abuelas`, `unravelled` — found by stripping a
/// suffix and asking whether the dictionary lists what is left.
struct FormTableDetachmentTests {
    static let table = FormTable(sources: [], forms: [:], ownHeadwords: [],
                                 words: ["abuela", "abet", "carry", "make", "walk", "bus", "barn", "ax", "axe", "bemire"])

    private func verdict(_ word: String, tagged: String? = nil, isName: Bool = false) -> FormTable.Verdict {
        Self.table.judge(word, tagged: tagged, partOfSpeech: nil, isName: isName)
    }

    @Test(arguments: [("abuelas", "abuela"), ("abetted", "abet"), ("abetting", "abet"), ("carries", "carry"),
                      ("carried", "carry"), ("making", "make"), ("walked", "walk"), ("bemires", "bemire")])
    func aRegularFormOfAListedWordIsDetached(form: String, base: String) {
        #expect(verdict(form) == .lemma(base))
        #expect(verdict(form, tagged: form) == .lemma(base), "the tagger leaving it unchanged is the same gap")
    }

    @Test func aWordTheDictionaryListsIsNeverDetached() {
        #expect(verdict("buses") == .lemma("bus"), "premise: a form is detached")
        #expect(FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["lens", "len"]).judge("lens", tagged: nil, partOfSpeech: nil) == .keep)
    }

    @Test func twoListedBasesAreAmbiguousAndLeftAlone() {
        #expect(verdict("axed") == .keep, "ax and axe both fit")
    }

    /// **Never over what the tagger said**, and never a name.
    @Test func aTaggerAnswerAndAProperNameAreBothLeftAlone() {
        #expect(verdict("walked", tagged: "walk") == .keep)
        #expect(verdict("walked", tagged: "stroll") == .lemma("walk"), "a word nothing lists loses to a listed base")
        let listed = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["walk", "stroll"])
        #expect(listed.judge("walked", tagged: "stroll", partOfSpeech: nil) == .keep, "a listed word stands")
        #expect(verdict("barnes", isName: true) == .keep)
        #expect(verdict("barnes") == .lemma("barn"), "premise: without the name guard it would detach")
    }

    /// **A short base is allowed, and ambiguity is what guards it**: `oked` is `ok` + `ed` and `oke` + `d`, and when
    /// the dictionary lists both nothing is decided; when it lists only the short one that is the answer.
    @Test func aShortBaseIsDetachedUnlessALongerOneAlsoFits() {
        let both = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["ok", "oke", "okay"])
        #expect(both.judge("oked", tagged: nil, partOfSpeech: nil) == .keep)
        let short = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["oh", "okay"])
        #expect(short.judge("ohs", tagged: nil, partOfSpeech: nil) == .lemma("oh"))
        #expect(short.judge("ox", tagged: nil, partOfSpeech: nil) == .keep, "two letters is not a form of anything")
    }

    @Test(arguments: [("cacti", "cactus"), ("calves", "calf"), ("wolves", "wolf"), ("bondmen", "bondman"),
                      ("ritenuti", "ritenuto"), ("cabalette", "cabaletta"), ("gummata", "gumma"),
                      ("larvae", "larva"), ("indices", "index"), ("analyses", "analysis"), ("bacteria", "bacterium")])
    func aPatternedIrregularFormIsDetachedWhereTheDictionaryListsTheBase(form: String, base: String) {
        let table = FormTable(sources: [], forms: [:], ownHeadwords: [], words: [base])
        #expect(table.judge(form, tagged: nil, partOfSpeech: nil) == .lemma(base))
        let empty = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["unrelated"])
        #expect(empty.judge(form, tagged: nil, partOfSpeech: nil) == .keep, "the listing is the whole check")
    }

    @Test(arguments: [("cruellest", "cruel"), ("mingiest", "mingy"), ("nicest", "nice"), ("mingier", "mingy"),
                      ("biggest", "big"), ("demurest", "demure")])
    func aSuperlativeAndAYierComparativeAreDetached(form: String, base: String) {
        let table = FormTable(sources: [], forms: [:], ownHeadwords: [], words: [base])
        #expect(table.judge(form, tagged: nil, partOfSpeech: nil) == .lemma(base))
    }

    /// `-er` is as often an agent — `enjoyer` is a word, not an inflection — so a plain comparative is never guessed.
    @Test func aPlainErFormIsNotDetached() {
        let table = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["enjoy", "opaque"])
        #expect(table.judge("enjoyer", tagged: nil, partOfSpeech: nil) == .keep)
        #expect(table.judge("opaquer", tagged: nil, partOfSpeech: nil) == .keep)
    }

    /// **The tagger's word is checked against the listing** where it is one no dictionary lists.
    @Test func aTaggerWordNothingListsLosesToAListedBaseAndAListedOneStands() {
        let table = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["cancel", "tax"])
        #expect(table.judge("cancelling", tagged: "canceling", partOfSpeech: "verb") == .lemma("cancel"))
        #expect(table.judge("cancelling", tagged: "cancel", partOfSpeech: "verb") == .keep)
        #expect(table.judge("cancelling", tagged: "cancelled", partOfSpeech: "verb") == .lemma("cancel"))
    }

    /// **A prefix on an irregular form the dictionary prints, where the compound is itself listed.**
    @Test func aPrefixedIrregularFormIsDetachedOnlyIfTheCompoundIsListed() {
        let forms: [String: Set<FormTable.Reading>] = [
            "ran": [.init(lemma: "run", partOfSpeech: "verb")], "fed": [.init(lemma: "feed", partOfSpeech: "verb")],
            "bound": [.init(lemma: "bind", partOfSpeech: "verb")],
        ]
        let table = FormTable(sources: [], forms: forms, ownHeadwords: ["bound"], words: ["overrun", "rebind"])
        #expect(table.judge("overran", tagged: nil, partOfSpeech: nil) == .lemma("overrun"))
        #expect(table.judge("unfed", tagged: nil, partOfSpeech: nil) == .keep, "`unfeed` is not a word")
        #expect(table.judge("rebound", tagged: nil, partOfSpeech: nil) == .keep, "bound is a word of its own")
    }

    /// `Boötes` is a title, and `bootes` — as a recogniser or a reader writes it — must find it.
    @Test func aTitleWithADiacriticIsAlsoFoundWithout() {
        let table = FormTable(sources: [], forms: [:], ownHeadwords: [], words: ["boötes", "boot"])
        #expect(table.judge("bootes", tagged: nil, partOfSpeech: nil) == .keep)
        #expect(table.judge("café", tagged: nil, partOfSpeech: nil) == .keep)
        #expect(FormTable(decoding: table.encoded()) == table)
    }

    /// The `k` a hard `c` takes is taken out again.
    @Test(arguments: [("picnicking", "picnic"), ("picnicked", "picnic"), ("trafficking", "traffic")])
    func aCKFormIsDetachedToItsC(form: String, base: String) {
        let table = FormTable(sources: [], forms: [:], ownHeadwords: [], words: [base])
        #expect(table.judge(form, tagged: nil, partOfSpeech: nil) == .lemma(base))
    }

    @Test func aTableWithNoWordListDetachesNothing() {
        #expect(FormTable(sources: [], forms: [:], ownHeadwords: []).judge("walked", tagged: nil, partOfSpeech: nil) == .keep)
    }

    @Test func theWordListSurvivesTheRoundTrip() throws {
        let decoded = try #require(FormTable(decoding: Self.table.encoded()))
        #expect(decoded == Self.table)
        #expect(decoded.judge("abuelas", tagged: nil, partOfSpeech: nil) == .lemma("abuela"))
        #expect(FormTable(decoding: Self.table.encoded().split(separator: "\n", omittingEmptySubsequences: false).dropLast().joined(separator: "\n")) == nil)
    }
}
