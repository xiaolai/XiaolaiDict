/// The process that owns an on-screen window, as the window server reports it.
public struct WindowOwner: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Finds the real process behind an app. On macOS 27 `NSWorkspace` reports Safari — which launches
/// from a system cryptex — with process ID -1, and an Accessibility element built from that is
/// invalid (every attribute answers kAXErrorInvalidUIElement). Its windows belong to the real one.
public enum ProcessResolver {
    /// `reported` when it is valid; otherwise the owner of the app's frontmost window, matched by
    /// bundle identifier. `windowOwners` are front to back, and asked for only when `reported` is
    /// invalid — listing every window is work a valid ID does not need. Nil rather than a guess:
    /// reading the wrong process would look up another app's selection.
    public static func pid(
        reported: Int32, bundleID: String?, windowOwners: @autoclosure () -> [WindowOwner]
    ) -> Int32? {
        if reported > 0 { return reported }
        guard let bundleID else { return nil }
        return windowOwners().first { $0.bundleID == bundleID && $0.pid > 0 }?.pid
    }
}
