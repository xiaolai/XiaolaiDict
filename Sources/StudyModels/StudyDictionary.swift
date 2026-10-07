import StudyKit
import StudyPresentation
import Foundation
import Observation
import DictionaryModel
import XiaolaiDictBase

/// The dictionary the reader studies from, and the list it was chosen out of.
///
/// Decision D7: the reader studies from **one** dictionary. The selector's candidate set is that
/// dictionary's senses alone — across all seven, *hold* offers 100+ near-duplicate candidates and
/// the confidently-wrong rate gets worse the more dictionaries are enabled.
///
/// **Its own type because the delegate's `askForDictionaries` was doing three unrelated jobs**, and
/// nothing about the name said so: it probed the two TCC permissions, re-read the reader's chosen
/// dictionary off disk, *and* asked the service for the enabled list. A caller wanting one got all
/// three. Permissions are not a dictionary concern and have gone back to the delegate, which is the
/// thing that legitimately composes "when the menu opens, refresh these".
///
/// Two rules survive here, both measured:
///
/// - **Assign only when the value changed.** `@Observable` notifies on every assignment, equal or
///   not, and this runs each time the menu opens — so it re-rendered the open menu about 70 ms
///   later, every time, for nothing. Measured on the E2E machine 2026-09-22: a click landing while
///   the menu re-renders is dropped — `menu-click` reported the click, the app never saw it — 2 lost
///   of 6 on a cold start, 0 of 8 once nothing was changing under the menu.
/// - **Re-read the choice from the store, never only write to it.** A lookup takes the primary from
///   disk, so a change made outside this process — a second copy, a `defaults write` — would
///   otherwise leave every window naming a dictionary that is no longer the one marks are recorded
///   against.
@Observable
@MainActor
public final class StudyDictionary {
    /// **The store is the truth for a lookup**, because a lookup can happen while no window is open
    /// to have observed anything. The observable copies below are what the windows draw.
    @ObservationIgnored public let store: PrimaryDictionaryStore
    @ObservationIgnored private let ask: (Bool) async -> [DictionaryCapability]?

    /// The enabled dictionaries, as the service last reported them. Nil until it has been asked: the
    /// menu says it does not know rather than showing a list it made up.
    public private(set) var enabled: [DictionaryCapability]?

    /// Whether the service has been asked and has finished answering. **Set whatever the answer
    /// was, including none** — "asked and got nothing" is a state that does not resolve, and a
    /// surface that cannot tell it from "still asking" waits forever.
    private(set) var hasAsked = false

    /// The chosen dictionary's key, held as **stored** state rather than read from `UserDefaults` on
    /// each access. `@Observable` tracks stored properties; a computed one that reaches into the
    /// defaults registers no dependency, so a view reading it is never invalidated when it changes.
    /// The setup board exposed this: pressing "Use 牛津英汉汉英词典" saved the choice and the row went
    /// on saying the seat was empty, because nothing told the view to look again.
    public private(set) var chosen: String?

    /// The dictionary the reader's language names, derived from `enabled` and remembered under its own
    /// key. **Not the reader's choice** — `chosen` stays nil — so Library and Review, which scope by it,
    /// are untouched, and a lookup, which reads the primary from disk, still sees it.
    private(set) var automatic: String?

    /// The reader's language, asked each time because it is the system's and can change between two
    /// refreshes without the dictionary list changing.
    @ObservationIgnored private let language: () -> String

    /// The dictionaries the reader's study notes belong to, read-only: empty when there is no ledger yet, nil when it could not be read.
    @ObservationIgnored private let studied: () async -> [String]?

    /// **One discovery pass at a time.** Three surfaces ask — the menu on open, the setup board and the
    /// Settings pane — and so does every first lookup of a launch. Overlapping passes were the source of
    /// every race this type had (an overtaken pass counted as an answer, a derivation made while a pin was
    /// suspended), so there are none: a caller queues behind the pass in flight and then runs its own.
    /// The pass lives in its own `Task`, so a waiter giving up at its deadline never abandons it half-done.
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// Incremented by `askAgain`. A pass that began before it must not publish: it would undo the
    /// cleared "asking" state `askAgain` exists to show, and leave the reader looking at the list from
    /// before they enabled a dictionary, marked as a finished answer.
    @ObservationIgnored private var askEpoch = 0

    public init(defaults: UserDefaults, language: @escaping () -> String = { ReaderLanguage.preferred },
         studied: @escaping () async -> [String]? = { [] },
         ask: @escaping (Bool) async -> [DictionaryCapability]?) {
        let store = PrimaryDictionaryStore(defaults: defaults, language: language)
        self.store = store
        self.ask = ask
        self.language = language
        self.studied = studied
        let stored = store.load()
        chosen = stored.chosen
        automatic = stored.automatic
    }

    /// Asks the service once, and re-reads the reader's choice every time.
    ///
    /// Probing parses real entries — Longman's *hold* alone is 625 KB — so it happens when a surface
    /// is opened rather than at launch, and only once unless `refreshing`.
    ///
    /// `revalidate` asks the service again without discarding its cache, for a caller that must have an
    /// answer *from this process* rather than one a menu opening happened to leave behind.
    public func refresh(refreshing: Bool = false, revalidate: Bool = false) async {
        _ = await pass(refreshing: refreshing, revalidate: revalidate)
    }

    /// Queues behind the pass in flight, then runs one of its own to completion.
    ///
    /// **Answers whether this very pass was stopped by `askAgain`** — a fact about the pass, carried in its
    /// result, because any flag shared between passes is rewritten by the next one before a waiter reads it.
    private func pass(refreshing: Bool, revalidate: Bool) async -> Bool {
        while let running = inFlight { await running.value }
        // A caller whose deadline passed while it waited does not start a pass nobody is waiting for.
        guard !Task.isCancelled else { return false }
        let task = Task { @MainActor [self] () -> Bool in
            let overtaken = await runPass(refreshing: refreshing, revalidate: revalidate)
            inFlight = nil
            return overtaken
        }
        inFlight = Task { _ = await task.value }
        return await task.value
    }

    private func runPass(refreshing: Bool, revalidate: Bool) async -> Bool {
        let language = self.language()
        let epoch = askEpoch
        let onDisk = store.load().chosen
        if onDisk != chosen { chosen = onDisk }
        if refreshing || revalidate || enabled == nil {
            let found = await ask(refreshing)
            // `askAgain` ran while this was in flight: its answer is the one the reader is waiting for.
            guard epoch == askEpoch else { return true }
            if found != enabled { enabled = found }
            hasAsked = true
        }
        // **The derivation always follows the pin, in this pass**, so nothing that reads the primary after a
        // pass can see the one without the other. A pin that could not be assessed (unreadable ledger) is
        // retried by every later pass, and means this process is not yet settled.
        let assessed = await pinImplicitPrimary()
        // `askAgain` ran while the ledger was being read: `enabled` is cleared and its pass will answer.
        guard epoch == askEpoch else { return true }
        deriveAutomatic(for: language)
        if enabled != nil, assessed { settledFor = language }
        return false
    }

    /// The language this process last completed a derivation for, from a list the service answered.
    /// **In memory only**, so every launch revalidates: a stored derivation is a cache for a lookup that
    /// cannot wait, never proof that it is still right (a dictionary enabled or disabled since).
    @ObservationIgnored private var settledFor: String?

    /// Whether this process has a derivation it can vouch for under the current language.
    var isSettled: Bool { settledFor == language() }

    /// **A reader who never chose but has study notes keeps the dictionary those notes are in.**
    /// Until now their primary was implicit — the first keyable dictionary in Dictionary.app's order — and
    /// their progress is keyed to it. Changing the default under them would start review over without
    /// asking, which `StudyDictionaryProposal` promises never to do. Pinned only when the notes belong to
    /// exactly one dictionary and the list is known and still holds it; otherwise nothing is written.
    ///
    /// **Once.** Assessed a single time and then recorded, whatever it found, so clearing the pin later
    /// ("my language") is not undone and a new reader is never pinned after their first notes. If the
    /// reader chooses while the ledger is being read, nothing is written.
    ///
    /// Answers whether the question is closed: false only for a ledger that could not be read, which says
    /// nothing and is asked again.
    private func pinImplicitPrimary() async -> Bool {
        guard enabled != nil else { return true }
        guard !store.pinAssessed else { return true }
        guard chosen == nil else { return true }
        guard let dictionaries = await studied() else { return false }
        guard chosen == nil, store.load().chosen == nil, !store.pinAssessed, let enabled else { return true }
        store.markPinAssessed()
        guard dictionaries.count == 1, let key = dictionaries.first,
              enabled.contains(where: { $0.identity.key == key }) else { return true }
        choose(key)
        return true
    }

    /// Returns once this process has a derivation for the current language, or after `bound`.
    /// Immediate when it has, which is every lookup but the first of a launch. **Bounded** because the
    /// probe parses real entries and a slow service must not hold a lookup; the pass itself carries on.
    public func settled(bound: Duration = .seconds(2)) async {
        guard !isSettled else { return }
        _ = try? await withDeadline(bound) { @MainActor [self] in
            // A pass stopped by `askAgain` answered nothing: the replacement it made way for is waited
            // for, not taken as this one's answer.
            for _ in 0..<3 {
                let overtaken = await self.pass(refreshing: false, revalidate: true)
                if self.isSettled || !overtaken { return }
            }
        }
    }

    /// Works out which dictionary the reader's language names and writes it where a lookup will read it.
    ///
    /// **Silent when the list is unknown.** A service that did not answer says nothing about which
    /// dictionaries exist, so the last derivation stands: clearing it would send every lookup back to
    /// Dictionary.app's order because a request timed out. Where the list *is* known and nothing suits the
    /// reader, the derivation is withdrawn, not left pointing at a dictionary for another language.
    private func deriveAutomatic(for language: String) {
        guard let enabled else { return }
        let derived = StudyDictionaryProposal.automatic(for: language, among: enabled)?.identity.key
        if derived != automatic { automatic = derived }
        // Always written: the stored copy may be for another language, which `load()` reports as absent.
        store.saveAutomatic(derived, language: language)
    }

    /// Asks again, discarding the last answer first.
    ///
    /// The setup board tells a reader with no suitable dictionary to enable one in Dictionary.app,
    /// and then has to **notice when they come back** — which the once-only ask above could never
    /// do. Cleared first so the row says "asking" rather than showing yesterday's list while the
    /// question is in flight.
    ///
    /// **It reaches the service's cache too.** The probe runs once per service process, which is
    /// right for a menu opening and wrong here: this is the path that has to see a dictionary the
    /// reader has just enabled, so the request carries `reprobing` and the service discards its
    /// answer before re-probing.
    public func askAgain() async {
        askEpoch += 1
        enabled = nil
        hasAsked = false
        await refresh(refreshing: true)
    }

    /// What `SettingsView` and `SetupView` are handed. **One adapter, because two identical copies
    /// of it stood in the two scenes**, closures and all — so a change to what discovery exposes, or
    /// to how a retry is wired, had to be made twice and would compile either way if it were made
    /// once.
    @MainActor
    public var choice: DictionaryChoice {
        DictionaryChoice(
            available: enabled,
            chosen: chosen,
            automatic: automatic,
            hasAsked: hasAsked,
            choose: { [weak self] in self?.choose($0) },
            reask: { [weak self] in Task { await self?.askAgain() } })
    }

    func choose(_ key: String?) {
        // Any choice, including "my language", ends the one-time pin.
        store.markPinAssessed()
        store.save(key)
        // Written to the observable copy too, or every view reading it goes on showing the old
        // choice until something else happens to invalidate it.
        chosen = key
    }
}
