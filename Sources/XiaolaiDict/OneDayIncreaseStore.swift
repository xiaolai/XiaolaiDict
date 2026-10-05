import Foundation
import ReviewKit

/// **Where today's one-day increase of the new-meaning allowance is kept** — the suite the app was
/// given, never `UserDefaults.standard` reached for here (review-module-plan WI-5).
///
/// One key, holding one `OneDayIncrease`: the study day it was granted on and how many it adds. A value
/// kept from an earlier study day is ignored by reading it, and replaced by the next raise, so nothing
/// has to remember to clear it at the cutoff. Read every time a sitting is planned or the queue is
/// counted, so the sitting, the Library's badge and the instrument agree without being told.
struct OneDayIncreaseStore {
    /// **A persistent contract**: renaming it drops whatever a reader raised today, silently.
    static let key = "reviewNewCardIncrease"

    let defaults: UserDefaults

    /// What today's allowance is raised by on the study day containing `instant`: nothing where no
    /// increase is kept, where the kept one is another day's, or where it cannot be read.
    func extra(in studyDay: StudyDay, at instant: Date) -> Int {
        kept?.extra(in: studyDay, at: instant) ?? 0
    }

    /// Raises the allowance of the study day containing `instant` by `count`, on top of what that day
    /// already has; another day's increase is dropped rather than carried.
    func raise(by count: Int, in studyDay: StudyDay, at instant: Date) {
        let raised = (kept ?? OneDayIncrease.granted(0, in: studyDay, at: instant))
            .raised(by: count, in: studyDay, at: instant)
        // Encoding a struct of a date and an integer cannot fail; a failure here is a broken
        // Foundation, and keeping the old value is the answer that raises nothing by accident.
        guard let data = try? JSONEncoder().encode(raised) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// **Unreadable is none.** A preference that cannot be decoded raises nothing — the base allowance
    /// is what the reader had before they ever pressed the button — rather than stopping Review.
    private var kept: OneDayIncrease? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(OneDayIncrease.self, from: $0) }
    }
}
