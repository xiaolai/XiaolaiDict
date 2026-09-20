import AppKit

switch LaunchArguments.parse(Array(CommandLine.arguments.dropFirst())) {
case .failure(let error):
    LookupCommand.writeError("\(error)\n\(LaunchArguments.usage)")
    exit(CommandStatus.usage.rawValue)

case .success(.lookup(let term, let repeats, let interval)):
    Task {
        let client = DictionaryClient()
        let status = await LookupCommand.run(term: term, repeats: repeats, interval: interval) { term throws(CancellationError) in
            try await client.lookup(term)
        }
        exit(status.rawValue)
    }
    dispatchMain()

// Works on an app that is not frontmost — it keeps its focused element — so selection support can
// be checked per app without switching to it.
case .success(.readSelection(let bundleID)):
    Task { @MainActor in exit(await LookupCommand.readSelection(bundleID: bundleID).rawValue) }
    dispatchMain()

// The hover paths, at a point, without moving anyone's pointer.
//
// Under AppKit's runloop, not `dispatchMain()`. ScreenCaptureKit's window-scoped capture needs a
// window-server connection and a serviced main runloop; `dispatchMain()` gives neither, and the
// capture never returns at all — measured here as 27 s blocked on a 30 s deadline against 5 s of
// CPU, while the identical capture under AppKit takes 127 ms. The Accessibility dialects never
// noticed, because they touch none of this: that is why both hover stages passed for months while
// the recogniser this instrument exists to exercise could not run once.
case .success(.readPoint(let x, let y)):
    let pointReader = NSApplication.shared
    pointReader.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await LookupCommand.readPoint(x: x, y: y).rawValue) }
    pointReader.run()

// Spike S1's instrument. It must run inside the signed bundle: a bare CLI binary reported voices
// that could not be resolved and a voice that synthesised zero frames.
case .success(.speechReport):
    Task { exit(await SpeechReport.run().rawValue) }
    dispatchMain()

// Whether the signed bundle can actually translate. Measured, because an availability API
// already reported `available` here for a model that then refused Developer ID signatures.
case .success(.translationReport):
    Task { exit(await TranslationReport.run().rawValue) }
    dispatchMain()

// Unlike the other reports this one shows a window, so it needs AppKit's runloop rather than
// dispatchMain(). `.accessory` for the same reason the app uses it: no Dock icon, and nothing
// here may activate XiaolaiDict.
case .success(.historyReport):
    let reporter = NSApplication.shared
    reporter.setActivationPolicy(.accessory)
    Task { @MainActor in exit(await HistoryReport.run().rawValue) }
    reporter.run()

case .success(.app):
    let app = NSApplication.shared
    let delegate = XiaolaiDictApp()
    app.delegate = delegate
    // LSUIElement in Info.plist makes XiaolaiDict a menu-bar app; set here too, so `swift run` outside the
    // bundle behaves the same.
    app.setActivationPolicy(.accessory)
    app.run()
}
