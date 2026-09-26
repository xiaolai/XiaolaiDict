import AppKit
import OSLog
import SwiftUI
import XiaolaiDictBase
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
    /// Opens Settings **on a named pane**. A button under the dictionary row that landed the
    /// reader on text size would be worse than no button.
    private var openSettings: ((SettingsPane) -> Void)?
    /// Asks the dictionary service again. The board tells a reader with nothing suitable to enable
    /// one in Dictionary.app, so it has to be able to notice when they come back.
    private var refreshDictionaries: (() async -> Void)?
    private var shortcutIsRegistered: Bool
    /// The local model's row: its state, and the download the reader can agree to or decline.
    private var localModel: LocalModelChoice?

    public init(
        model: SetupModel = SetupModel(), dictionary: DictionaryChoice? = nil,
        shortcut: ShortcutChoice? = nil, shortcutIsRegistered: Bool = true,
        // **No default.** Nil is a board that does not know what this Mac can do about the model,
        // and a default made that the quiet outcome of forgetting to wire it: the row says "Not
        // known" and offers nothing, with nothing to say it was a mistake rather than a state.
        localModel: LocalModelChoice?,
        openSettings: ((SettingsPane) -> Void)? = nil,
        refreshDictionaries: (() async -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.dictionary = dictionary
        self.shortcut = shortcut
        self.shortcutIsRegistered = shortcutIsRegistered
        self.localModel = localModel
        self.openSettings = openSettings
        self.refreshDictionaries = refreshDictionaries
    }

    /// Built fresh on every evaluation, from whatever is true now. Storing it is how a board starts
    /// showing yesterday's answer.
    public var board: SetupBoard {
        SetupBoard(
            permissions: model.permissions, available: dictionary?.available,
            chosen: dictionary?.chosen, language: ReaderLanguage.preferred,
            shortcut: shortcut?.shortcut, shortcutIsRegistered: shortcutIsRegistered,
            // **Not known is not "not downloaded".** Defaulted, the row asked a reader for a
            // download the board had no way to start, and `SetupBoard`'s own nil branch — written
            // for exactly this — could never be reached.
            model: localModel?.state, modelDeclined: localModel?.declined ?? false,
            engine: SenseEngine.status())
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
        // **As tall as it is, not as tall as SwiftUI's default.** A grouped `Form` scrolls, so it
        // offers the window no height — and the board opened at 450 with the model row's buttons
        // below the fold on exactly the Mac the row is for: one with no model downloaded.
        .fitsItsContent(width: Token.Panel.settingsWidth)
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
        if !model.hasAsked || (board.isAsking && dictionary?.hasAsked != true) {
            Text("Checking…")
        } else if board.isAsking {
            // Asked, and got nothing. The row below says so; the summary must not go on implying
            // something is still in flight.
            Text("Some of this could not be checked.")
        } else {
            switch board.outstanding.count {
            // **"Everything" is a claim, and a row this Mac cannot have makes it false.** Nothing is
            // waiting on the reader either way; which of the two sentences is true depends on
            // whether something here is simply not available.
            // **Not known is not "this Mac cannot".** A board that was never told about the model
            // reads as unavailable to `isAvailable`, and the sentence below would say this Mac had
            // everything it can have while the row itself says it does not know.
            case 0 where board.model == nil:
                Text("Nothing is waiting on you. What this Mac can do about the local model is not known yet.")
            case 0 where board.steps.contains(where: { !board.isAvailable($0) }):
                Text("Everything this Mac can do is in place. Anything here can still be changed.")
            // **A model the reader put off is not one that is in place.** Nothing is waiting on
            // them — they answered — but saying everything needed is here would be saying they have
            // something they declined.
            case 0 where localModel?.declined == true && board.model?.answering == nil:
                // "above" was wrong: this summary sits before every row, so the model row is below
                // it. Named rather than pointed at, because which direction it is in depends on a
                // layout this sentence should not have to know.
                Text("Nothing is waiting on you. The local model is still one click away, in the translation row.")
            case 0: Text("Everything needed is in place. Anything here can still be changed.")
            case 1: Text("One thing is still needed.")
            default: Text("\(board.outstanding.count) things are still needed.")
            }
        }
    }

    @ViewBuilder private func row(_ step: SetupBoard.Step) -> some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                let (symbol, colour) = symbolAndColour(step)
                Image(systemName: symbol).foregroundStyle(colour)
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
        case .localModel: Text("Translation and sense picking")
        }
    }

    @ViewBuilder private func state(_ step: SetupBoard.Step) -> some View {
        if step == .localModel, let modelState = modelStateLabel {
            modelState
        } else if board.isSettled(step), board.isAvailable(step) {
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
        case .localModel: modelDetail
        }
    }

    /// The only row whose text is a decision rather than a description.
    @ViewBuilder private var dictionaryDetail: some View {
        if board.chosenDictionaryIsMissing {
            // **What actually happens, not what sounds worst.** `PrimaryDictionary.identity(among:)`
            // falls back to the first dictionary that can key a sense, so lookups keep working and
            // marks keep being made — against a dictionary the reader never chose. Those marks are
            // recorded, not lost: `StudyItem` is keyed by dictionary, so they accumulate as that
            // dictionary's study history instead of theirs. "No sense can be marked" was untrue,
            // and so is "they will not be recorded".
            Text("""
                 The dictionary you study from is no longer enabled in Dictionary. Senses are \
                 being marked against whichever dictionary answers instead, and study history is \
                 kept per dictionary — so those marks build up apart from yours.
                 """)
        } else if let chosen = board.chosenDictionary {
            Text("Studying from \(chosen.identity.name) — \(chosen.note).")
        } else if board.isAsking {
            // **Asked and failed is not still asking.** The list is fetched once, in a task that
            // has already ended, so without this distinction a service that answered nothing left
            // the row saying "Asking…" for the life of the window.
            if dictionary?.hasAsked == true {
                Text("The dictionary service did not answer, so no dictionary can be suggested.")
            } else {
                Text("Asking which dictionaries are enabled…")
            }
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
                // **"None declares it" is not "you have none".** Three of the seven dictionaries
                // enabled on the development Mac declare no language at all, so the rule cannot
                // classify them: a records probe says what a dictionary indexes and never what it
                // explains in. The three are exactly the three sideloaded conversions — measured
                // 2026-09-24 by reading `DCSDictionaryLanguages` out of all seven bundles, where
                // every Apple asset declares and no sideloaded one does. One number, not two.
                // Telling a reader with Longman and Collins enabled that they have no English
                // dictionary would be false, and this is the row where the probe's answer finally
                // earns its keep.
                if board.undeclaredEnglishDictionaries.isEmpty {
                    // No promise of automatic detection: nothing watches Dictionary.app, and
                    // "this will notice" would have the reader waiting for something that never
                    // happens. The button beside it is the answer.
                    Text("""
                         No enabled dictionary explains English in your language. Enable one in \
                         Dictionary, under Settings, then choose Check again.
                         """)
                } else {
                    // "Some", not "none": a reader can have NOAD — which declares its languages
                    // and is simply not for them — beside an undeclared conversion, and a sentence
                    // claiming nothing declares anything would be false in front of them.
                    Text("""
                         Some enabled dictionaries do not say which language they explain English \
                         in, so none can be suggested. Choose one yourself, or enable a dictionary \
                         for your language in Dictionary.
                         """)
                }
            }
        }
    }

    /// The row's state word where "Ready" and "Needed" would say something false: a download in
    /// flight is neither, a declined model is not ready, and a board that was never told about the
    /// model knows nothing about it.
    private var modelStateLabel: Text? {
        switch board.model {
        case .downloading: Text("Downloading")
        case .tooLittleMemory: Text("Not available")
        case nil: Text("Not known")
        case .ready: nil
        case .notDownloaded, .stopped: board.modelDeclined ? Text("Not now") : nil
        }
    }

    /// The tick, the warning, or neither. **A step this Mac cannot have gets no tick**: a green
    /// check over "Not available" would claim the reader had received something they have not.
    private func symbolAndColour(_ step: SetupBoard.Step) -> (String, AnyShapeStyle) {
        guard board.isAvailable(step) else { return ("circle", AnyShapeStyle(.secondary)) }
        if board.isSettled(step) { return ("checkmark.circle.fill", AnyShapeStyle(.green)) }
        return (symbol(step), step.needsReader ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    /// What the model does, what it costs, and — while it is absent — what does its jobs instead.
    /// The fallback is named because it is measured to be worse, and a reader deciding whether a
    /// 3 GB download is worth it deserves to know what they have without it. **It is named only
    /// where it is what answers**: during an upgrade the model already installed goes on working,
    /// and telling that reader their senses are picked by a simpler match would be false.
    @ViewBuilder private var modelDetail: some View {
        switch board.model {
        case .ready(let size):
            Text("\(size.displayName) translates your sentences and picks the sense you met, on this Mac. Nothing is sent anywhere.")
        case .downloading(let progress, let size, let replacing):
            VStack(alignment: .leading, spacing: scale.space.line) {
                if let replacing {
                    Text("Downloading \(size.displayName) — \(Self.bytes(progress.received)) of \(Self.bytes(progress.total)). \(replacing.displayName) goes on answering until it is here.")
                } else {
                    Text("Downloading \(size.displayName) — \(Self.bytes(progress.received)) of \(Self.bytes(progress.total)). It can be stopped and resumed.")
                }
                ProgressView(value: progress.fraction)
                if replacing == nil { fallbackDetail() }
            }
        case .stopped(let reason, let size, let replacing):
            VStack(alignment: .leading, spacing: scale.space.line) {
                // "What arrived" and not "everything that arrived": a file whose hash or size does
                // not match its pin is discarded rather than resumed from, so the promise has to be
                // about the bytes that are still good. Overstated, it tells a reader whose download
                // failed an integrity check that nothing will be re-fetched, and then re-fetches it.
                Text("The \(size.displayName) download stopped: \(reason). What arrived and still checks out is kept, and it resumes from there.")
                if replacing == nil { fallbackDetail() }
            }
        case .tooLittleMemory:
            VStack(alignment: .leading, spacing: scale.space.line) {
                // **Names the requirement, because nothing here can be acted on otherwise.** The
                // reader cannot add memory; what they can do is understand why the row is a dead end
                // rather than wonder whether a retry would help. 16 GB is the real-world threshold:
                // the model's measured peak is 3,585 MB against a quarter-of-RAM budget, so it needs
                // 14.0 GB and no Apple Silicon Mac ships between 8 and 16.
                Text("The local model needs 16 GB of memory. This Mac has less, so it cannot run it.")
                // Nothing is coming later here, so nothing is said to be.
                fallbackDetail(untilThen: false)
            }
        case nil:
            Text("This board was opened without the model's state, so it cannot say what is here.")
        case .notDownloaded:
            VStack(alignment: .leading, spacing: scale.space.line) {
                if let size = localModel?.recommended {
                    Text("\(size.displayName) translates your sentences and picks the sense you met, on this Mac — a \(Self.bytes(size.manifest.totalBytes)) download.")
                }
                fallbackDetail()
            }
        }
    }

    /// What picks senses and translates while the model is absent — Apple's engines, which are
    /// measured to be weaker, or the simpler match where Apple's model does not run. Every sentence
    /// says what is *tried*, not what will answer: Apple's model refuses some sentences and falls to
    /// the simpler match, and its translator needs a language pack that may not be installed.
    ///
    /// **"Until then" is a promise, and on a Mac that cannot hold the model it is a false one.** So
    /// the permanent case has sentences of its own rather than a phrase spliced into these: a
    /// translator is given whole sentences, which is worth more than the repetition it costs.
    @ViewBuilder private func fallbackDetail(untilThen: Bool = true) -> some View {
        if untilThen {
            if board.engine.isOnDevice {
                Text("""
                     Until then, senses are picked by Apple's on-device model, and a simpler match \
                     where it declines. Sentences are translated by Apple where its language pack is \
                     installed — which cannot be told which sense you met, and misreads some.
                     """)
            } else {
                Text("""
                     Until then, senses are picked by a simpler match. Sentences are translated by \
                     Apple where its language pack is installed — which cannot be told which sense you \
                     met, and misreads some.
                     """)
            }
        } else {
            if board.engine.isOnDevice {
                Text("""
                     Without a local model, senses are picked by Apple's on-device model, and a \
                     simpler match where it declines. Sentences are translated by Apple where its \
                     language pack is installed — which cannot be told which sense you met, and \
                     misreads some.
                     """)
            } else {
                Text("""
                     Without a local model, senses are picked by a simpler match. Sentences are \
                     translated by Apple where its language pack is installed — which cannot be told \
                     which sense you met, and misreads some.
                     """)
            }
        }
    }

    /// Bytes as the reader reads them: "3.1 GB".
    private static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    @ViewBuilder private var shortcutDetail: some View {
        if let shortcut = shortcut?.shortcut, shortcut.isUsable, shortcutIsRegistered {
            Text("Select a word anywhere and press \(shortcut.label()).")
        } else if let shortcut = shortcut?.shortcut, shortcut.isUsable {
            // **Registered is not the same as well-formed.** Another app can hold the combination
            // exclusively, and telling the reader to press one that was refused sends them to try
            // something that cannot work and to doubt the app when it does not.
            // **Not "another app is holding it".** That is the commonest reason and not the only
            // one, and this surface is not told which occurred — the menu carries the registration
            // error when there is one. Naming a cause the app has not established is how a reader
            // goes looking for the wrong thing.
            Text("""
                 \(shortcut.label()) is not registered, so it will not look anything up. Choose \
                 another combination, or look words up from the menu.
                 """)
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
        case .localModel:
            modelActions
        case .shortcut:
            if let openSettings {
                Button("Change…") { openSettings(.lookup) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    /// **A download never starts unasked**, so it is always a button — and it stays in the row after
    /// Not now, one click away, for as long as there is something to download.
    @ViewBuilder private var modelActions: some View {
        if let localModel {
            HStack(spacing: scale.space.stack) {
                switch localModel.state {
                case .downloading:
                    Button("Stop") { localModel.cancel() }
                        .buttonStyle(.glass)
                case .notDownloaded, .stopped:
                    // The size a stopped download was of, so Resume finishes what is on disk rather
                    // than starting a second model beside it.
                    if let size = localModel.downloadable {
                        Button(localModel.state == .notDownloaded ? "Download" : "Resume") {
                            localModel.download(size)
                        }
                        .buttonStyle(.glassProminent)
                        if !localModel.declined {
                            Button("Not now") { localModel.decline() }
                                .buttonStyle(.glass)
                        }
                    }
                case .ready:
                    if let larger = localModel.larger {
                        Button("Use the larger model (\(Self.bytes(larger.manifest.totalBytes)))") {
                            localModel.download(larger)
                        }
                        .buttonStyle(.glass)
                    }
                case .tooLittleMemory:
                    EmptyView()
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var dictionaryActions: some View {
        HStack(spacing: scale.space.stack) {
            if case .propose(let one) = board.proposal, board.chosenDictionary == nil {
                Button("Use \(one.identity.name)") { dictionary?.choose(one.identity.key) }
                    .buttonStyle(.glassProminent)
            }
            if case .nothingSuitable = board.proposal, !board.isAsking {
                Button("Open Dictionary…") { openDictionaryApp() }
                    .buttonStyle(.glassProminent)
            }
            if let openSettings, !board.isAsking {
                Button(board.chosenDictionary == nil ? "Choose…" : "Change…") {
                    openSettings(.dictionary)
                }
                .buttonStyle(.glass)
            }
            // **The way back from a service that never answered.** The list is fetched once, in a
            // task that has already ended, and the permission poll does not retry it — so without
            // this a failed or slow probe leaves the row saying "Asking…" for the life of the
            // window. It is also how the board notices a dictionary enabled in Dictionary.app,
            // which the "enable one" sentence above promises it will.
            if let refreshDictionaries {
                Button(board.isAsking ? "Try again" : "Check again") {
                    Task { await refreshDictionaries() }
                }
                .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
    }

    /// Dictionary.app is where the reader enables one. XiaolaiDict cannot do it for them: the
    /// dictionaries it cannot see are undownloaded system assets, and the enabled list is that
    /// app's own preference.
    ///
    /// **Both failures are said out loud.** `return` on an unresolvable bundle identifier, and a
    /// discarded completion on the launch, made this button a control that can do nothing while
    /// looking like it worked — the same shape as the script box that refused a click in silence.
    /// A reader who is being told to go and enable a dictionary, and whose button does nothing,
    /// has no way to tell that from having missed the window.
    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "setup")

    private func openDictionaryApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Dictionary")
        else {
            Self.log.fault("Dictionary.app could not be found by bundle identifier, so the reader's button did nothing")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Self.log.fault("Dictionary.app would not open: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
