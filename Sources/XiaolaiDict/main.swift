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
case .success(.readPoint(let x, let y)):
    Task { @MainActor in exit(await LookupCommand.readPoint(x: x, y: y).rawValue) }
    dispatchMain()

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

case .success(.app):
    let app = NSApplication.shared
    let delegate = XiaolaiDictApp()
    app.delegate = delegate
    // LSUIElement in Info.plist makes XiaolaiDict a menu-bar app; set here too, so `swift run` outside the
    // bundle behaves the same.
    app.setActivationPolicy(.accessory)
    app.run()
}
