/// **How long each kind of question may take — one table, whichever source answers it** (ADR-0053, plan §7).
///
/// It was `ModelClient`'s, beside the XPC session it bounded. The providers ask the same questions of the reader's
/// own CLI or endpoint, and a deadline that differed by source would make a slow provider and a slow local model fall
/// to Apple's rung at different moments for one question — so the table moved here, where both clients can read it.
///
/// A sense answer measured 0.24–0.44 s warm and 1.6–2.5 s cold on an M4 Max, and a base chip is estimated at a
/// quarter of its GPU; resident `claude` answered in 0.9–1.1 s and a kept endpoint connection in about 1.3 s. Every
/// bound is set well past a cold answer on a slow Mac, because the mark fills in when it arrives and giving up early
/// only hands the sentence to a weaker rung.
public enum ModelDeadline {
    public static func of(_ request: ModelRequest) -> Duration {
        switch request {
        case .pickSense: .seconds(12)
        case .translate: .seconds(30)
        // Prose rather than a number, and a slow Mac writes it a token at a time.
        case .explain: .seconds(45)
        case .prewarm: .seconds(60)
        case .status: .seconds(10)
        // Longer than the service's own drain, because unloading *is* that wait: bounded shorter,
        // a service doing exactly what it was asked times out and reads as one that failed.
        case .unload: ModelShutdown.ask
        }
    }
}
