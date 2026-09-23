import Foundation
import Translation
import XiaolaiDictCore
import os

/// Apple's Translation framework, as the translation pane's fallback engine.
///
/// **Only `.installed` counts as able.** Measured on both Macs, every pair reports `.supported` and
/// then fails `translate` with `.notInstalled` until its language pack is added — so `.supported`
/// describes Apple's catalogue, not this Mac, and it is answered here as "needs its pack".
enum AppleTranslation {
    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "translation")

    /// **On the main actor**, so the session is made, awaited and cancelled in one isolation
    /// domain. `TranslationSession` is a plain class that states no thread safety, and `cancel()`
    /// is only of use while a translation is in flight — so the domain has to be one the
    /// cancellation can be sent back to, rather than whichever thread it happens to land on.
    @MainActor
    static func translate(_ sentence: String, from source: String, to target: String) async -> AppleTranslationResult {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed: break
        case .supported: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .failed
        }
        // Asking whether the pair is installed is itself an await, and the reader may have closed
        // the panel during it. Nothing below is worth starting for an answer nobody will read.
        guard !Task.isCancelled else { return .failed }
        // **Held, not temporary.** `cancel()` is the framework's way of stopping a translation, and
        // a session built inline into the call has no name to call it on — so the work ran on past
        // the panel it was for. The handler gives cancellation somewhere to land.
        //
        // The marking is what lets the handler's closure — which must be `Sendable` — hold a class
        // that is not. It is carried across and **immediately hopped back** to the main actor,
        // where the session was made and where its translation is being awaited, so the reference
        // travels through the handler without ever being used outside the domain it belongs to.
        nonisolated(unsafe) let session = TranslationSession(installedSource: from, target: to)
        do {
            let response = try await withTaskCancellationHandler {
                try await session.translate(sentence)
            } onCancel: {
                Task { @MainActor in session.cancel() }
            }
            return .translated(response.targetText)
        } catch TranslationError.notInstalled {
            return .notInstalled
        } catch {
            // A translation the reader walked away from is not a failure of Apple's, and logging it
            // as one fills the log with the app's own doing.
            guard !Task.isCancelled else { return .failed }
            // The pane says only that it could not; why is kept where it can be read afterwards.
            log.error("translation \(source, privacy: .public)→\(target, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }

}
