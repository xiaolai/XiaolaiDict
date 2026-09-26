import XiaolaiDictUI
import Foundation
import Observation
import DictionaryModel
import XiaolaiDictCore

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
final class StudyDictionary {
    /// **The store is the truth for a lookup**, because a lookup can happen while no window is open
    /// to have observed anything. The observable copies below are what the windows draw.
    @ObservationIgnored let store: PrimaryDictionaryStore
    @ObservationIgnored private let ask: (Bool) async -> [DictionaryCapability]?

    /// The enabled dictionaries, as the service last reported them. Nil until it has been asked: the
    /// menu says it does not know rather than showing a list it made up.
    private(set) var enabled: [DictionaryCapability]?

    /// Whether the service has been asked and has finished answering. **Set whatever the answer
    /// was, including none** — "asked and got nothing" is a state that does not resolve, and a
    /// surface that cannot tell it from "still asking" waits forever.
    private(set) var hasAsked = false

    /// The chosen dictionary's key, held as **stored** state rather than read from `UserDefaults` on
    /// each access. `@Observable` tracks stored properties; a computed one that reaches into the
    /// defaults registers no dependency, so a view reading it is never invalidated when it changes.
    /// The setup board exposed this: pressing "Use 牛津英汉汉英词典" saved the choice and the row went
    /// on saying the seat was empty, because nothing told the view to look again.
    private(set) var chosen: String?

    /// Which request's answer may be published. **Incremented by every call**, because three
    /// surfaces ask — the menu on open, the setup board, and the Settings pane — and their requests
    /// overlap freely across the `await`.
    ///
    /// Without it, an older discovery completing *during* a newer `askAgain()` publishes its list
    /// and sets `hasAsked`, which undoes exactly the cleared "asking" state `askAgain` exists to
    /// show — and can leave the reader looking at the list from before they enabled a dictionary,
    /// marked as a finished answer. Only the current generation writes.
    @ObservationIgnored private var generation = 0

    init(defaults: UserDefaults, ask: @escaping (Bool) async -> [DictionaryCapability]?) {
        let store = PrimaryDictionaryStore(defaults: defaults)
        self.store = store
        self.ask = ask
        chosen = store.load().chosen
    }

    /// Asks the service once, and re-reads the reader's choice every time.
    ///
    /// Probing parses real entries — Longman's *hold* alone is 625 KB — so it happens when a surface
    /// is opened rather than at launch, and only once unless `refreshing`.
    func refresh(refreshing: Bool = false) async {
        let onDisk = store.load().chosen
        if onDisk != chosen { chosen = onDisk }
        guard refreshing || enabled == nil else { return }
        generation += 1
        let mine = generation
        let found = await ask(refreshing)
        // A newer request started while this one was in flight: its cleared state and its answer
        // are the ones the reader is waiting for, so this one is dropped rather than published.
        guard mine == generation else { return }
        if found != enabled { enabled = found }
        hasAsked = true
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
    func askAgain() async {
        enabled = nil
        hasAsked = false
        await refresh(refreshing: true)
    }

    /// What `SettingsView` and `SetupView` are handed. **One adapter, because two identical copies
    /// of it stood in the two scenes**, closures and all — so a change to what discovery exposes, or
    /// to how a retry is wired, had to be made twice and would compile either way if it were made
    /// once.
    @MainActor
    var choice: DictionaryChoice {
        DictionaryChoice(
            available: enabled,
            chosen: chosen,
            hasAsked: hasAsked,
            choose: { [weak self] in self?.choose($0) },
            reask: { [weak self] in Task { await self?.askAgain() } })
    }

    func choose(_ key: String?) {
        store.save(key)
        // Written to the observable copy too, or every view reading it goes on showing the old
        // choice until something else happens to invalidate it.
        chosen = key
    }
}
