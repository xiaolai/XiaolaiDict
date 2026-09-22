import AppKit
import SwiftUI
import XiaolaiDictCore

/// The permission half of the setup board's live state.
///
/// Separate from the view for the same reason `SettingsModel` is: an instrument has to be able to
/// drive it and read it back from outside a rendered hierarchy.
@Observable @MainActor public final class SetupModel {
    public private(set) var permissions = PermissionsReport(states: [])
    /// False until the first probe answers. `SCShareableContent` costs a round trip, so there is a
    /// real moment before the board can say anything — and an empty report must not be drawn as
    /// "nothing is granted".
    public private(set) var hasAsked = false

    public init() {}

    public func refresh() async { show(await .probe()) }

    public func show(_ report: PermissionsReport) {
        permissions = report
        hasAsked = true
    }
}

/// What a fresh install still needs, as a board the reader can open whenever they like.
///
/// Rows tick themselves: the permission poll below is the same one the settings window runs,
/// because macOS posts nothing when a permission changes. Nothing here has a Next button, and
/// nothing is hidden once it is done.
public struct SetupView: View {
    @Environment(\.scale) private var scale
    @State private var model: SetupModel
    /// Optional so a preview can show the board without the app behind it.
    private var dictionary: DictionaryChoice?
    private var shortcut: ShortcutChoice?
    private var openSettings: (() -> Void)?

    public init(
        model: SetupModel = SetupModel(), dictionary: DictionaryChoice? = nil,
        shortcut: ShortcutChoice? = nil, openSettings: (() -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.dictionary = dictionary
        self.shortcut = shortcut
        self.openSettings = openSettings
    }

    /// Built fresh on every evaluation, from whatever is true now. Storing it is how a board starts
    /// showing yesterday's answer.
    public var board: SetupBoard {
        SetupBoard(
            permissions: model.permissions, available: dictionary?.available,
            chosen: dictionary?.chosen, language: ReaderLanguage.preferred,
            shortcut: shortcut?.shortcut, engine: SenseEngine.status())
    }

    public var body: some View {
        Form {
            Section {
                summary.foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(board.steps) { step in
                Section { row(step) }
            }
        }
        .formStyle(.grouped)
        // The same width as the settings window. Not a duplicated number but the same role: this is
        // the width a form of grouped sections reads well at, and the two surfaces are the same
        // kind of surface. If that width moves, both should move together.
        .frame(width: Token.Panel.settingsWidth)
        // macOS posts nothing when a permission changes, and the reader grants them in another app
        // and comes back. Polling is the only way to notice, and `.task` stops it when the window
        // goes away.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: Token.Timing.permissionPoll)
            }
        }
    }

    /// One line above the rows. It reports, and never congratulates — a board that said "all
    /// done" would be claiming something about the reader rather than about the machine.
    ///
    /// Written as literal `Text` rather than a composed `String`: `Text(someString)` takes the
    /// verbatim overload and the compiler extracts nothing, which is how four of the longest
    /// sentences in Settings came to be invisible to every translator.
    @ViewBuilder private var summary: some View {
        if !model.hasAsked {
            Text("Checking…")
        } else {
            switch board.outstanding.count {
            case 0: Text("Everything needed is in place. Anything here can still be changed.")
            case 1: Text("One thing is still needed.")
            default: Text("\(board.outstanding.count) things are still needed.")
            }
        }
    }

    @ViewBuilder private func row(_ step: SetupBoard.Step) -> some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                Image(systemName: board.isSettled(step) ? "checkmark.circle.fill" : symbol(step))
                    .foregroundStyle(
                        board.isSettled(step) ? AnyShapeStyle(.green)
                            : (step.needsReader ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)))
                title(step).font(.system(size: scale.text.heading, weight: .medium))
                Spacer(minLength: scale.space.inline)
                state(step)
                    .font(.system(size: scale.text.body, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            detail(step)
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actions(step)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The unsettled symbol. A step the reader need not act on is not a warning.
    private func symbol(_ step: SetupBoard.Step) -> String {
        step.needsReader ? "exclamationmark.triangle.fill" : "circle"
    }

    @ViewBuilder private func title(_ step: SetupBoard.Step) -> some View {
        switch step {
        case .accessibility: Text("Accessibility")
        case .screenRecording: Text("Screen Recording")
        case .dictionary: Text("Study dictionary")
        case .shortcut: Text("Lookup shortcut")
        case .senseEngine: Text("Sense picking")
        }
    }

    @ViewBuilder private func state(_ step: SetupBoard.Step) -> some View {
        if board.isSettled(step) {
            Text("Ready")
        } else if step.needsReader {
            Text("Needed")
        } else {
            Text("Not set")
        }
    }

    @ViewBuilder private func detail(_ step: SetupBoard.Step) -> some View {
        switch step {
        case .accessibility: Text(Permission.accessibility.blocks)
        case .screenRecording: Text(Permission.screenRecording.blocks)
        case .dictionary: dictionaryDetail
        case .shortcut: shortcutDetail
        case .senseEngine: engineDetail
        }
    }

    /// The only row whose text is a decision rather than a description.
    @ViewBuilder private var dictionaryDetail: some View {
        if board.chosenDictionaryIsMissing {
            Text("""
                 The dictionary you study from is no longer enabled in Dictionary. Until it is \
                 back, or another is chosen, no sense can be marked.
                 """)
        } else if let chosen = board.chosenDictionary {
            Text("Studying from \(chosen.identity.name) — \(chosen.note).")
        } else if dictionary?.available == nil {
            Text("Asking which dictionaries are enabled…")
        } else {
            switch board.proposal {
            case .propose(let one):
                Text("""
                     \(one.identity.name) matches your language. One dictionary is studied from \
                     at a time, and changing it later starts your study over.
                     """)
            case .choose(let several):
                Text("""
                     \(several.count) enabled dictionaries match your language. Choose the one to \
                     study from — changing it later starts your study over.
                     """)
            case .nothingSuitable:
                // This app cannot enable one: the dictionaries it cannot see are undownloaded
                // system assets, and the enabled list is Dictionary.app's own preference.
                Text("""
                     No enabled dictionary explains English in your language. Enable one in \
                     Dictionary, under Settings, and this will notice.
                     """)
            }
        }
    }

    /// What backs sense picking, said without implying the reader is missing out.
    ///
    /// **Measured 2026-09-22 over three identical runs: the confidently-wrong rate is 17% with
    /// Apple's on-device model and 17% with the `NLEmbedding` fallback.** So this row reports which
    /// one is running and never suggests the other would be better — a warning here would be
    /// manufacturing anxiety about a difference measured to be zero.
    @ViewBuilder private var engineDetail: some View {
        switch board.engine {
        case .onDevice:
            Text("Senses are picked by Apple's on-device model.")
        case .unavailable(.appleIntelligenceNotEnabled):
            Text("""
                 Apple Intelligence is off, so senses are picked by a simpler match. A marked \
                 sense is a guess until you confirm it, either way.
                 """)
        case .unavailable(.modelNotReady):
            Text("""
                 Apple's on-device model is still preparing. Senses are picked by a simpler match \
                 until it is ready.
                 """)
        case .unavailable:
            Text("""
                 Apple's on-device model does not run here, so senses are picked by a simpler \
                 match. A marked sense is a guess until you confirm it, either way.
                 """)
        }
    }

    @ViewBuilder private var shortcutDetail: some View {
        if let shortcut = shortcut?.shortcut, shortcut.isUsable {
            Text("Select a word anywhere and press \(shortcut.label()).")
        } else {
            Text("No shortcut is registered, so selections can be looked up from the menu only.")
        }
    }

    @ViewBuilder private func actions(_ step: SetupBoard.Step) -> some View {
        switch step {
        case .accessibility, .screenRecording:
            let permission: Permission = step == .accessibility ? .accessibility : .screenRecording
            if !board.isGranted(permission) {
                Text(permission.location)
                    .font(.system(size: scale.text.label))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                HStack(spacing: scale.space.stack) {
                    // macOS prompts only the first time ever, which is why the second button
                    // exists and why the list is named above it.
                    Button("Ask macOS…") { permission.request() }
                        .buttonStyle(.glassProminent)
                    Button("Open Settings…") { NSWorkspace.shared.open(permission.settingsURL) }
                        .buttonStyle(.glass)
                }
                .controlSize(.small)
            }
        case .dictionary:
            dictionaryActions
        case .senseEngine:
            // Nothing to offer. There is no action inside this app that changes the answer, and a
            // button that only opened System Settings would imply one.
            EmptyView()
        case .shortcut:
            if let openSettings {
                Button("Change…") { openSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var dictionaryActions: some View {
        HStack(spacing: scale.space.stack) {
            if case .propose(let one) = board.proposal, board.chosenDictionary == nil {
                Button("Use \(one.identity.name)") { dictionary?.choose(one.identity.key) }
                    .buttonStyle(.glassProminent)
            }
            if case .nothingSuitable = board.proposal, dictionary?.available != nil {
                Button("Open Dictionary…") { openDictionaryApp() }
                    .buttonStyle(.glassProminent)
            }
            if let openSettings, dictionary?.available != nil {
                Button(board.chosenDictionary == nil ? "Choose…" : "Change…") { openSettings() }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
    }

    /// Dictionary.app is where the reader enables one. XiaolaiDict cannot do it for them: the
    /// dictionaries it cannot see are undownloaded system assets, and the enabled list is that
    /// app's own preference.
    private func openDictionaryApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Dictionary")
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
