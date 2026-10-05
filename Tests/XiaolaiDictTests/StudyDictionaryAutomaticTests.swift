import DictionaryModel
import Foundation
import Testing
import XiaolaiDictTestSupport

@testable import XiaolaiDict
@testable import XiaolaiDictCore

/// The reader is not asked which dictionary to study from: their language says, and the answer is
/// remembered beside — never as — the reader's own choice.
@MainActor
struct StudyDictionaryAutomaticTests {
    private static let oxford = DictionaryCapability(
        identity: DictionaryIdentity(name: "牛津英汉汉英词典", identifier: "com.apple.dictionary.zh_CN-en.OCD"),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "zh_CN", explains: "zh_CN"), .init(index: "en", explains: "zh_CN")],
        indexes: [.latin, .han])
    private static let dreye = DictionaryCapability(
        identity: DictionaryIdentity(name: "譯典通英漢雙向字典", identifier: "com.apple.dictionary.zh_TW-en.DrEye"),
        senseKeyKind: .position, probed: true,
        languages: [.init(index: "zh_TW", explains: "zh_TW"), .init(index: "en", explains: "zh_TW")],
        indexes: [.latin, .han])
    private static let noad = DictionaryCapability(
        identity: DictionaryIdentity(name: "New Oxford American Dictionary", identifier: DictionaryIdentity.noad),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "en_US", explains: "en_US")], indexes: [.latin])

    /// What the reader's language is, held where a test can change it between two refreshes.
    private final class Language {
        var value: String
        init(_ value: String) { self.value = value }
    }

    @Test func aRefreshChoosesByLanguageAndRemembersItBesideTheChoice() async {
        let defaults = TemporaryDefaults.suite()
        let dictionary = StudyDictionary(defaults: defaults, language: { "zh-Hans-CN" }) { _ in
            [Self.noad, Self.oxford, Self.dreye]
        }
        await dictionary.refresh()
        #expect(dictionary.automatic == Self.oxford.identity.key)
        #expect(dictionary.chosen == nil, "an automatic dictionary must never read as the reader's own choice")
        #expect(dictionary.choice.automatic == Self.oxford.identity.key)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "zh-Hans-CN" }).load().automatic == Self.oxford.identity.key,
                "a lookup reads the primary from disk, so it must be written there")
        #expect(PrimaryDictionaryStore(defaults: defaults).load().chosen == nil)
    }

    /// The system language can change between two menu openings without the dictionary list changing,
    /// so the derivation is redone on every refresh and not only when a new list arrives.
    @Test func aChangedLanguageIsPickedUpWithoutAskingTheServiceAgain() async {
        let language = Language("zh-Hans-CN")
        var asked = 0
        let dictionary = StudyDictionary(defaults: TemporaryDefaults.suite(), language: { language.value }) { _ in
            asked += 1
            return [Self.noad, Self.oxford, Self.dreye]
        }
        await dictionary.refresh()
        language.value = "zh-Hant-TW"
        await dictionary.refresh()
        #expect(asked == 1)
        #expect(dictionary.automatic == Self.dreye.identity.key)
    }

    /// Nothing suits this reader, so any earlier derivation is withdrawn rather than left to point at a
    /// dictionary for another language.
    @Test func aReaderNothingSuitsHasTheDerivationCleared() async {
        let language = Language("zh-Hans-CN")
        let defaults = TemporaryDefaults.suite()
        let dictionary = StudyDictionary(defaults: defaults, language: { language.value }) { _ in [Self.oxford] }
        await dictionary.refresh()
        #expect(dictionary.automatic != nil)
        language.value = "ko-KR"
        await dictionary.refresh()
        #expect(dictionary.automatic == nil)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "zh-Hans-CN" }).load().automatic == nil)
    }

    /// **A service that did not answer says nothing about which dictionaries exist.** The last good
    /// derivation stands: clearing it would send every lookup back to Dictionary.app's order because a
    /// request timed out.
    @Test func aServiceThatDidNotAnswerLeavesTheLastDerivationAlone() async {
        let defaults = TemporaryDefaults.suite()
        var answer: [DictionaryCapability]? = [Self.oxford]
        let dictionary = StudyDictionary(defaults: defaults, language: { "zh-Hans-CN" }) { _ in answer }
        await dictionary.refresh()
        answer = nil
        await dictionary.askAgain()
        #expect(dictionary.enabled == nil)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "zh-Hans-CN" }).load().automatic == Self.oxford.identity.key)
    }

    @Test func choosingNeitherTouchesNorErasesTheDerivation() async {
        let defaults = TemporaryDefaults.suite()
        let dictionary = StudyDictionary(defaults: defaults, language: { "zh-Hans-CN" }) { _ in [Self.noad, Self.oxford] }
        await dictionary.refresh()
        dictionary.choose(Self.noad.identity.key)
        #expect(dictionary.chosen == Self.noad.identity.key)
        #expect(dictionary.automatic == Self.oxford.identity.key)
        dictionary.choose(nil)
        #expect(dictionary.chosen == nil)
        #expect(dictionary.automatic == Self.oxford.identity.key)
    }

    // MARK: - A reader who never chose but already has progress

    @Test func progressInOneDictionaryIsPinnedSoTheDefaultDoesNotMoveIt() async {
        let defaults = TemporaryDefaults.suite()
        let dictionary = StudyDictionary(
            defaults: defaults, language: { "zh-Hans-CN" }, studied: { [Self.noad.identity.key] }
        ) { _ in [Self.noad, Self.oxford] }
        await dictionary.refresh()
        #expect(dictionary.chosen == Self.noad.identity.key)
        #expect(PrimaryDictionaryStore(defaults: defaults).load().chosen == Self.noad.identity.key)
    }

    @Test func noProgressOrProgressInSeveralPinsNothing() async {
        for studied in [[String](), [Self.noad.identity.key, Self.oxford.identity.key]] {
            let dictionary = StudyDictionary(
                defaults: TemporaryDefaults.suite(), language: { "zh-Hans-CN" }, studied: { studied }
            ) { _ in [Self.noad, Self.oxford] }
            await dictionary.refresh()
            #expect(dictionary.chosen == nil)
        }
    }

    /// Progress in a dictionary that is not enabled cannot be studied from, so pinning it would only
    /// make every lookup fall back; the derivation stands instead.
    @Test func progressInADictionaryNoLongerEnabledPinsNothing() async {
        let dictionary = StudyDictionary(
            defaults: TemporaryDefaults.suite(), language: { "zh-Hans-CN" }, studied: { ["com.apple.dictionary.gone"] }
        ) { _ in [Self.oxford] }
        await dictionary.refresh()
        #expect(dictionary.chosen == nil)
    }

    /// **Once.** Clearing the pin ("my language") must not be undone by the next discovery.
    @Test func clearingThePinIsNotUndoneByTheNextDiscovery() async {
        let defaults = TemporaryDefaults.suite()
        let dictionary = StudyDictionary(
            defaults: defaults, language: { "zh-Hans-CN" }, studied: { [Self.noad.identity.key] }
        ) { _ in [Self.noad, Self.oxford] }
        await dictionary.refresh()
        #expect(dictionary.chosen == Self.noad.identity.key)
        dictionary.choose(nil)
        await dictionary.askAgain()
        #expect(dictionary.chosen == nil)
    }

    /// A reader with no notes yet is assessed too, so notes made later never pin them.
    @Test func aReaderWithNoNotesIsNeverPinnedLater() async {
        var notes: [String] = []
        let dictionary = StudyDictionary(
            defaults: TemporaryDefaults.suite(), language: { "zh-Hans-CN" }, studied: { notes }
        ) { _ in [Self.noad, Self.oxford] }
        await dictionary.refresh()
        notes = [Self.noad.identity.key]
        await dictionary.askAgain()
        #expect(dictionary.chosen == nil)
    }

    /// A derivation made for another language is not read.
    @Test func aDerivationForAnotherLanguageIsNotInForce() async {
        let defaults = TemporaryDefaults.suite()
        let zh = StudyDictionary(defaults: defaults, language: { "zh-Hans-CN" }) { _ in [Self.oxford, Self.dreye] }
        await zh.refresh()
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "zh-Hans-CN" }).load().automatic != nil)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "zh-Hant-TW" }).load().automatic == nil)
        #expect(StudyDictionary(defaults: defaults, language: { "zh-Hant-TW" }) { _ in nil }.isSettled == false)
    }

    /// A ledger that could not be read says nothing, so the assessment is retried, not spent.
    @Test func anUnreadableLedgerDoesNotSpendTheOneTimePin() async {
        var answer: [String]? = nil
        let dictionary = StudyDictionary(
            defaults: TemporaryDefaults.suite(), language: { "zh-Hans-CN" }, studied: { answer }
        ) { _ in [Self.noad, Self.oxford] }
        await dictionary.refresh()
        #expect(dictionary.chosen == nil)
        answer = [Self.noad.identity.key]
        await dictionary.askAgain()
        #expect(dictionary.chosen == Self.noad.identity.key)
    }
}

/// A lookup must not freeze its primary before the reader's language has been derived.
@MainActor
struct StudyDictionarySettlingTests {
    private static let oxford = DictionaryCapability(
        identity: DictionaryIdentity(name: "牛津英汉汉英词典", identifier: "com.apple.dictionary.zh_CN-en.OCD"),
        senseKeyKind: .publisher, probed: true,
        languages: [.init(index: "zh_CN", explains: "zh_CN"), .init(index: "en", explains: "zh_CN")],
        indexes: [.latin, .han])

    @Test func settlingDerivesWhenNoneIsInForceAndTheStoreThenHoldsIt() async {
        let defaults = TemporaryDefaults.suite()
        let dictionary = StudyDictionary(defaults: defaults, language: { "zh-Hans-CN" }) { _ in [Self.oxford] }
        #expect(!dictionary.isSettled)
        await dictionary.settled(bound: .seconds(60))
        #expect(dictionary.isSettled)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "zh-Hans-CN" }).load().automatic
            == Self.oxford.identity.key, "the lookup reads the primary from disk right after settling")
    }

    @Test func settlingIsImmediateOnceDerived() async {
        var asked = 0
        let dictionary = StudyDictionary(defaults: TemporaryDefaults.suite(), language: { "zh-Hans-CN" }) { _ in
            asked += 1
            return [Self.oxford]
        }
        await dictionary.settled(bound: .seconds(60))
        await dictionary.settled(bound: .seconds(60))
        #expect(asked == 1)
    }

    /// A service that never answers must not hold a lookup beyond the bound: `settled` returns while
    /// the service's answer is still outstanding. Structure, not elapsed time.
    @Test func settlingGivesUpWhileTheServiceIsStillPending() async {
        let answered = Flag()
        let dictionary = StudyDictionary(defaults: TemporaryDefaults.suite(), language: { "zh-Hans-CN" }) { _ in
            try? await Task.sleep(for: .seconds(120))
            answered.set()
            return nil
        }
        await dictionary.settled(bound: .milliseconds(50))
        #expect(!answered.value)
        #expect(!dictionary.isSettled)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.lock(); raised = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }
}

/// Readiness is a fact about this process, not an inference from what is stored.
@MainActor
struct StudyDictionaryReadinessTests {
    private static func capability(_ name: String, _ id: String) -> DictionaryCapability {
        DictionaryCapability(
            identity: DictionaryIdentity(name: name, identifier: id), senseKeyKind: .publisher, probed: true,
            languages: [.init(index: "en_US", explains: "en_US")], indexes: [.latin])
    }
    private static let noad = capability("NOAD", DictionaryIdentity.noad)
    private static let other = capability("Other", "com.example.other")

    /// A derivation stored by an earlier launch is revalidated against the live list before a lookup
    /// trusts it: NOAD was disabled then and is enabled now.
    @Test func aStoredDerivationForTheSameLanguageIsRevalidatedOncePerLaunch() async {
        let defaults = TemporaryDefaults.suite()
        PrimaryDictionaryStore(defaults: defaults, language: { "en-US" }).saveAutomatic(Self.other.identity.key)
        let dictionary = StudyDictionary(defaults: defaults, language: { "en-US" }) { _ in [Self.other, Self.noad] }
        #expect(!dictionary.isSettled, "a stored derivation is not readiness")
        await dictionary.settled(bound: .seconds(60))
        #expect(dictionary.isSettled)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "en-US" }).load().automatic
            == Self.noad.identity.key)
    }

    /// A service that gave no list says nothing: not settled, the stored derivation stands.
    @Test func aServiceWithNoListIsNotSettledAndLeavesTheStoredDerivation() async {
        let defaults = TemporaryDefaults.suite()
        PrimaryDictionaryStore(defaults: defaults, language: { "en-US" }).saveAutomatic(Self.noad.identity.key)
        let dictionary = StudyDictionary(defaults: defaults, language: { "en-US" }) { _ in nil }
        await dictionary.settled(bound: .seconds(60))
        #expect(!dictionary.isSettled)
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "en-US" }).load().automatic
            == Self.noad.identity.key)
    }

    /// **Passes never overlap.** A lookup's settle, the launch settle and a Settings refresh queue behind
    /// one another, so none can publish a stale answer or derive while another's pin is suspended.
    @Test func discoveryPassesNeverOverlap() async {
        let running = Counter()
        let dictionary = StudyDictionary(defaults: TemporaryDefaults.suite(), language: { "en-US" }) { _ in
            running.enter()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
            running.leave()
            return [Self.noad]
        }
        async let a: Void = dictionary.settled(bound: .seconds(60))
        async let b: Void = dictionary.refresh(revalidate: true)
        async let c: Void = dictionary.askAgain()
        _ = await (a, b, c)
        #expect(running.peak == 1)
        #expect(dictionary.enabled == [Self.noad])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0, high = 0
        func enter() { lock.lock(); now += 1; high = max(high, now); lock.unlock() }
        func leave() { lock.lock(); now -= 1; lock.unlock() }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return high }
    }

    /// A settled process stays settled when a later request gets no list: the service said nothing.
    @Test func aLaterRequestWithNoListDoesNotUnsettleOrWithdraw() async {
        let defaults = TemporaryDefaults.suite()
        var answer: [DictionaryCapability]? = [Self.noad]
        let dictionary = StudyDictionary(defaults: defaults, language: { "en-US" }) { _ in answer }
        await dictionary.settled(bound: .seconds(60))
        #expect(dictionary.isSettled)
        answer = nil
        await dictionary.askAgain()
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "en-US" }).load().automatic
            == Self.noad.identity.key)
    }

    /// The derivation and the readiness it grants name the language the pass began under: a language
    /// change while the service is answering must not leave them disagreeing.
    @Test func aLanguageChangedMidPassIsNotSettledForTheNewLanguage() async {
        let defaults = TemporaryDefaults.suite()
        var language = "en-US"
        let dictionary = StudyDictionary(defaults: defaults, language: { language }) { _ in
            language = "zh-Hans-CN"      // the system language changes while the service is answering
            return [Self.noad]
        }
        await dictionary.settled(bound: .seconds(60))
        language = "en-US"
        #expect(PrimaryDictionaryStore(defaults: defaults, language: { "en-US" }).load().automatic
            == Self.noad.identity.key, "derived and stamped for the language the pass began under")
        #expect(dictionary.isSettled)
        language = "zh-Hans-CN"
        #expect(!dictionary.isSettled)
    }

    /// A pass stopped by `askAgain` is waited past, not mistaken for an answer.
    @Test func aPassStoppedByAskAgainIsRetriedByTheSettlingCaller() async {
        var calls = 0
        let release = Gate()
        let dictionary = StudyDictionary(defaults: TemporaryDefaults.suite(), language: { "en-US" }) { _ in
            calls += 1
            if calls == 1 { await release.wait() }
            return [Self.noad]
        }
        async let settling: Void = dictionary.settled(bound: .seconds(60))
        await Task.yield(); await Task.yield()
        async let again: Void = dictionary.askAgain()
        await Task.yield(); await Task.yield()
        release.open()
        await settling
        #expect(dictionary.isSettled, "settling returned before the pass that replaced the overtaken one answered")
        await again
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true; let all = waiters; waiters = []; lock.unlock()
            all.forEach { $0.resume() }
        }
    }

    /// A pin that could not be assessed (ledger unreadable) is retried by an ordinary refresh, not only
    /// by a forced reprobe.
    @Test func aFailedPinAssessmentIsRetriedByTheNextOrdinaryRefresh() async {
        var answer: [String]? = nil
        let dictionary = StudyDictionary(
            defaults: TemporaryDefaults.suite(), language: { "en-US" }, studied: { answer }
        ) { _ in [Self.noad, Self.other] }
        await dictionary.refresh()
        #expect(dictionary.chosen == nil)
        answer = [Self.other.identity.key]
        await dictionary.refresh()   // list already held: no new probe
        #expect(dictionary.chosen == Self.other.identity.key)
    }
}

