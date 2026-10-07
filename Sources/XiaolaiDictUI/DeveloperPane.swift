import Capture
import SwiftUI
import XiaolaiDictCore

/// What the developer pane can do, handed in by the app: `XiaolaiDictUI` reaches neither the ledger's file
/// nor the preferences. Compiled in every build and nil in a release, which draws no such pane.
public struct DeveloperChoice: Sendable {
    public var counts: @Sendable () async -> DeveloperCounts?
    public var clear: @Sendable () async -> DeveloperOutcome
    public var deploy: @Sendable () async -> DeveloperOutcome
    /// Where the copy taken before a clear is kept, named so the pane can say so.
    public var backupName: String

    public init(counts: @escaping @Sendable () async -> DeveloperCounts?,
                clear: @escaping @Sendable () async -> DeveloperOutcome,
                deploy: @escaping @Sendable () async -> DeveloperOutcome, backupName: String) {
        self.counts = counts
        self.clear = clear
        self.deploy = deploy
        self.backupName = backupName
    }
}

public struct DeveloperCounts: Equatable, Sendable {
    public let lookups: Int
    public let notes: Int
    public init(lookups: Int, notes: Int) {
        self.lookups = lookups
        self.notes = notes
    }
    public var isEmpty: Bool { lookups == 0 && notes == 0 }
}

public enum DeveloperOutcome: Equatable, Sendable {
    case done(String)
    case failed(String)
}

#if XIAOLAIDICT_CAPTURE_INSTRUMENTS
/// **Development builds only.** Strings are verbatim, not localized: this is a developer's instrument, and
/// no reader ever sees it (`XIAOLAIDICT_CAPTURE_INSTRUMENTS` is not defined in a release).
struct DeveloperPane: View {
    var choice: DeveloperChoice?

    @State private var counts: DeveloperCounts?
    @State private var status: DeveloperOutcome?
    @State private var busy = false
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                if let choice {
                    LabeledContent {
                        Text(verbatim: counts.map { "\($0.lookups) readings, \($0.notes) study notes" } ?? "…")
                            .foregroundStyle(.secondary)
                    } label: { Text(verbatim: "In the ledger") }
                    Button(role: .destructive) { confirmingClear = true } label: { Text(verbatim: "Clear All Data…") }
                        .disabled(busy)
                    Button { run { await choice.deploy() } } label: { Text(verbatim: "Deploy Test Data") }
                        .disabled(busy || counts?.isEmpty != true)
                    if counts?.isEmpty == false {
                        Text(verbatim: "Deploy needs an empty ledger, so test data is never mixed with real data. Clear first.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let status {
                        switch status {
                        case .done(let text): Text(verbatim: text).foregroundStyle(.secondary)
                        case .failed(let text): Text(verbatim: text).foregroundStyle(.red)
                        }
                    }
                } else {
                    Text(verbatim: "Not wired.").foregroundStyle(.secondary)
                }
            } header: {
                Text(verbatim: "Developer")
            } footer: {
                Text(verbatim: "Development builds only, and hidden: Shift+Up three times in Settings shows it, and again hides it. Closing the window hides it too.")
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog(
            Text(verbatim: "Clear all data?"), isPresented: $confirmingClear, titleVisibility: .visible
        ) {
            Button(role: .destructive) { if let choice { run { await choice.clear() } } } label: {
                Text(verbatim: "Clear All Data")
            }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: """
                 Deletes every reading and study note in the ledger, and resets the study-dictionary \
                 preferences. A copy is saved first as \(choice?.backupName ?? "a backup"), replacing the previous one.
                 """)
        }
    }

    private func refresh() async { counts = await choice?.counts() }

    private func run(_ operation: @escaping @Sendable () async -> DeveloperOutcome) {
        busy = true
        status = nil
        Task {
            status = await operation()
            await refresh()
            busy = false
        }
    }
}

/// Listens for Shift+Up three times while this window is key, and toggles the pane.
private struct DeveloperReveal: ViewModifier {
    let model: SettingsModel
    @State private var monitor: Any?
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onAppear(perform: install)
            .onDisappear {
                remove()
                model.hideDeveloper()
            }
    }

    private func install() {
        guard monitor == nil else { return }
        var sequence = RevealSequence()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window === window else { return event }
            // Arrow keys carry .numericPad and .function; Shift+Up is Shift and nothing else.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function])
            let shiftUp = event.specialKey == .upArrow && flags == .shift
            if sequence.note(shiftUp: shiftUp, at: event.timestamp) {
                Task { @MainActor in model.toggleDeveloper() }
            }
            // Passed on, never swallowed: Shift+Up still does what it does in a list.
            return event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
#endif

extension View {
    /// Wires the reveal gesture in a development build; a release gets the view back unchanged.
    @ViewBuilder func developerReveal(_ model: SettingsModel) -> some View {
        #if XIAOLAIDICT_CAPTURE_INSTRUMENTS
        modifier(DeveloperReveal(model: model))
        #else
        self
        #endif
    }
}
