/// How long the model service stays up with nothing to do — after which it ends, and the model's
/// memory goes with it.
///
/// Read by two processes, so it lives here: the service decides when to end, and `--model-report`
/// watches it do so. They must agree on the key, the default and the bounds, or the instrument waits
/// for an unload the service was never going to perform.
public enum ModelIdle {
    /// In the app's own defaults domain. launchd starts the service with no arguments, so this is how
    /// the end-to-end stage shortens it for a run — and puts it back after.
    public static let defaultsKey = "ModelIdleSeconds"
    public static let defaultSeconds = 600
    /// Bounded, so a stray value can neither unload between two questions of one lookup nor keep
    /// gigabytes resident for an afternoon.
    public static let secondsRange = 10...3_600

    /// The interval a configured value means: the default where none is set, clamped otherwise.
    public static func seconds(configured: Int?) -> Int {
        guard let configured else { return defaultSeconds }
        return min(max(configured, secondsRange.lowerBound), secondsRange.upperBound)
    }
}
