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

case .success(.app):
    let app = NSApplication.shared
    let delegate = XiaolaiDictApp()
    app.delegate = delegate
    // LSUIElement in Info.plist makes XiaolaiDict a menu-bar app; set here too, so `swift run` outside the
    // bundle behaves the same.
    app.setActivationPolicy(.accessory)
    app.run()
}
