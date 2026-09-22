import FoundationModels

/// Why the on-device model cannot run here.
///
/// Apple's own reasons, kept as a closed set of our own rather than passed through: the framework's
/// enum is not `Codable`, not `CaseIterable`, and can gain a case in a point release that this
/// would then have to render. `unknown` is the honest answer to a case nobody here has seen.
public enum SenseEngineUnavailability: String, Sendable, Equatable, Codable, CaseIterable {
    /// This Mac cannot run it at all — the reason measured on the development machine.
    case deviceNotEligible
    /// The Mac could, but the reader has not turned Apple Intelligence on.
    case appleIntelligenceNotEnabled
    /// Turned on, still downloading or preparing.
    case modelNotReady
    /// A reason this build does not know about.
    case unknown
}

/// **Whether Apple's on-device model can back sense selection** — not which engine is in use. The
/// top rung is the local model wherever it is downloaded, and this says nothing about it: what it
/// answers is what the setup board's model row names as the fallback while no model is there, and
/// what rung 2 asks before it runs.
public enum SenseEngineStatus: Sendable, Equatable {
    /// Apple's on-device model is available.
    case onDevice
    /// It is not, so with no local model downloaded the ladder falls to `NLEmbedding`.
    case unavailable(SenseEngineUnavailability)

    public var isOnDevice: Bool { self == .onDevice }

    public var reason: SenseEngineUnavailability? {
        switch self {
        case .onDevice: nil
        case .unavailable(let reason): reason
        }
    }
}

/// The one place that asks whether Apple's on-device model can run.
///
/// **Asked here and nowhere else, for the same reason the Screen Recording grant is.**
/// `FoundationModelsSenseSelector` used to pattern-match `.available` itself and throw the
/// `.unavailable(reason)` payload away, so nothing could report *why* a reader was on the fallback
/// rung — while `OnDeviceSentenceExplainer` kept the reason and rendered it. Two readings of one
/// question, disagreeing about how much of it to keep. Now the selector asks this, and so does the
/// setup board, and they cannot drift.
///
/// **A status is not a capability.** This says what Apple reports, which is the same kind of claim
/// as `LanguageAvailability` reporting `.supported` for a translation pair that then fails with
/// `.notInstalled`, and as `PrivateCloudComputeLanguageModel` reporting `available` and refusing
/// every request in ~10 ms. Treat it as what to *tell* the reader, never as proof a request will
/// succeed — the selector still handles a refusal by abstaining.
///
/// No display text here: `XiaolaiDictCore` has no view layer, so a sentence in it could be shown and
/// never extracted for a translator. What the reader is told lives in `XiaolaiDictUI`.
public enum SenseEngine {
    public static func status() -> SenseEngineStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .onDevice
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        @unknown default:
            return .unavailable(.unknown)
        }
    }
}
