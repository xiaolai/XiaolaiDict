import Synchronization

/// **Which instrument, if any, this process is.**
///
/// One value, set once by `main.swift` before the scene starts, replacing a
/// `nonisolated(unsafe) static var isWanted` on each of the three reports that show a window.
///
/// The comment on `XiaolaiDictApp.isInstrumented` already explained why that was wrong — the list
/// "was repeated at each site and each new instrument had to remember to join every one of them" —
/// and then consolidated only the *reading* of it. Three flags remained, three assignments in
/// `main.swift`, three lines in `applicationDidFinishLaunching` and three terms in `isInstrumented`:
/// four places to edit for a fourth windowed report, and the one that gets forgotten is the one that
/// decides whether hover fires during a capture. Two simultaneous captures deadlock, measured six
/// trials of six.
///
/// The three that show no window are absent on purpose. `--lookup`, `--read-point`,
/// `--speech-report`, `--model-report` and the rest never build a `XiaolaiDictApp` at all, so there
/// is nothing for them to suppress — and listing them here would be a claim this type cannot keep.
enum Instruments {
    /// The windowed instruments: the ones that run *inside* the app and must suppress the surfaces
    /// a reader would get.
    enum Windowed: String, CaseIterable, Sendable {
        case history
        case settings
        case panel
    }

    private static let chosen = Mutex<Windowed?>(nil)

    /// Set once, from `main.swift`, before `XiaolaiDictScene.main()`.
    static func run(_ instrument: Windowed) {
        chosen.withLock { $0 = instrument }
    }

    /// Which instrument this process is, or nil for the reader's app.
    static var wanted: Windowed? { chosen.withLock { $0 } }

    /// **Whether this process is an instrument rather than the reader's app.**
    ///
    /// An instrument measures the app; it has no reader whose pointer needs watching, and a setup
    /// board opening unasked is a window in front of whatever it was about to capture.
    static var isInstrumented: Bool { wanted != nil }
}
