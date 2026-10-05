import Foundation
import ReviewKit
import XiaolaiDictBase
import os

/// **What the reader chose about reminders, in the suite the app was given** — never `.standard`
/// reached for here, so a test cannot turn a reader's reminders on.
///
/// JSON in one key, read through `ReminderSettings`' own decoder: every absent field is R3's
/// recommendation and every value clamped, so a value written by another version — or by the
/// `reminder` end-to-end stage — is still read. Unreadable is the recommendation, which is off.
struct ReminderSettingsStore {
    /// **A persistent contract**: renaming it turns every reader's reminders off, silently.
    static let key = "reviewReminderSettings"

    let defaults: UserDefaults

    func load() -> ReminderSettings {
        defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: $0) } ?? .recommended
    }

    func save(_ settings: ReminderSettings) {
        // Encoding a struct of numbers and flags cannot fail; a failure here is a broken Foundation,
        // and keeping the old value is the answer that changes nothing by accident.
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

extension ReminderSettings {
    /// The same choices, on or off.
    func turned(on isEnabled: Bool) -> ReminderSettings {
        ReminderSettings(isEnabled: isEnabled, hour: hour, minute: minute,
                         showsPredictedCount: showsPredictedCount, laterDelay: laterDelay, horizon: horizon)
    }

    func at(hour: Int, minute: Int) -> ReminderSettings {
        ReminderSettings(isEnabled: isEnabled, hour: hour, minute: minute,
                         showsPredictedCount: showsPredictedCount, laterDelay: laterDelay, horizon: horizon)
    }

    func showing(count: Bool) -> ReminderSettings {
        ReminderSettings(isEnabled: isEnabled, hour: hour, minute: minute,
                         showsPredictedCount: count, laterDelay: laterDelay, horizon: horizon)
    }

    func waiting(later delay: TimeInterval) -> ReminderSettings {
        ReminderSettings(isEnabled: isEnabled, hour: hour, minute: minute,
                         showsPredictedCount: showsPredictedCount, laterDelay: delay, horizon: horizon)
    }
}

/// **What this app has asked the system to deliver** — `ReminderLog`, kept between launches
/// (review-module-plan §5.2).
///
/// Two closures rather than a defaults suite, so a test can make the write fail — the case the whole
/// intent → add → added protocol is about: **a log that cannot be written schedules nothing.**
struct ReminderLogStore {
    /// **A persistent contract**, like the settings' key.
    static let key = "reviewReminderLog"

    /// **What is kept under the key** — a log, nothing, or something that is not a log. Three answers,
    /// because "no log" and "a log that was lost" plan differently: the coordinator decides which one
    /// "nothing" is, from whether reminders are on (`ReminderCoordinator.keptLog`).
    enum Kept: Equatable {
        case log(ReminderLog)
        /// Nothing was ever written here — or what was has been deleted.
        case absent
        /// Something is here and it does not read as a log.
        case unreadable

        /// The log, where one was read.
        var log: ReminderLog? {
            guard case .log(let kept) = self else { return nil }
            return kept
        }
    }

    let read: @MainActor () -> Kept
    let save: @MainActor (ReminderLog) throws -> Void

    init(read: @escaping @MainActor () -> Kept, save: @escaping @MainActor (ReminderLog) throws -> Void) {
        self.read = read
        self.save = save
    }

    /// Thrown when what was written does not read back.
    struct NotWritten: Error, CustomStringConvertible {
        var description: String { "the reminder log did not read back as written" }
    }

    /// **The app's suite, and a write that is read back.** `UserDefaults.set` cannot report a failure,
    /// so the only evidence a write took is reading it: a value that does not come back is a write that
    /// failed, and the caller schedules nothing on it.
    ///
    /// **What is guaranteed when the log is lost** — deleted, or unreadable — **is that today gets no
    /// second unrequested banner**: while reminders are on, a lost log is planned as
    /// `ReminderLog.lost(today:)`, which spends today's reminders, and the days ahead are planned again.
    /// It costs at most today's reminders. A log lost while reminders are *off* cannot be told from a
    /// reader who never turned them on, and turning them on then may plan today.
    @MainActor
    static func suite(_ defaults: UserDefaults) -> ReminderLogStore {
        let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "reminders")
        return ReminderLogStore(
            read: {
                guard let data = defaults.data(forKey: key) else {
                    // A value of another type under the key is not a log either, and not an absence.
                    return defaults.object(forKey: key) == nil ? .absent : .unreadable
                }
                do {
                    return .log(try JSONDecoder().decode(ReminderLog.self, from: data))
                } catch {
                    log.error("reminders: the log could not be read")
                    return .unreadable
                }
            },
            save: { kept in
                let data = try JSONEncoder().encode(kept)
                defaults.set(data, forKey: key)
                guard defaults.data(forKey: key) == data else { throw NotWritten() }
            })
    }
}
