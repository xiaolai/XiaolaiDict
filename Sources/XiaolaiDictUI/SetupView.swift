import AppKit
import DictionaryModel
import OSLog
import ModelKit
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
/// Rows settle themselves: the permission poll below is the only one in the window, because
/// macOS posts nothing when a permission changes. Nothing here has a Next button, and nothing is
/// hidden once it is done.
///
/// **The type is the system's, like every other pane.** The rows were set from the reader's
/// text size — 12 pt at Standard beside the 13 pt of Reading, Lookup and Dictionary — so the
/// window changed type size from tab to tab and only two panes answered the Size control. That
/// control is for what is *read*: cards, sentences, the lookup window. Settings is chrome.
/// Spacing still comes from the scale, which is where spacing lives.
public struct SetupView: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var model: SetupModel
    /// A model the reader asked to remove, held until they confirm: it is gigabytes, and getting
    /// it back is a download.
    @State private var removing: LocalModelChoice.InstalledModel?
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
    /// Told whether anything here still needs the reader, whenever that is known and changes —
    /// so the window can open on this pane next time while something does.
    private var onOutstandingChange: ((Bool) -> Void)?

    public init(
        model: SetupModel = SetupModel(), dictionary: DictionaryChoice? = nil,
        shortcut: ShortcutChoice? = nil, shortcutIsRegistered: Bool = true,
        // **No default.** Nil is a board that does not know what this Mac can do about the model,
        // and a default made that the quiet outcome of forgetting to wire it: the row says "Not
        // known" and offers nothing, with nothing to say it was a mistake rather than a state.
        localModel: LocalModelChoice?,
        openSettings: ((SettingsPane) -> Void)? = nil,
        refreshDictionaries: (() async -> Void)? = nil,
        onOutstandingChange: ((Bool) -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.dictionary = dictionary
        self.shortcut = shortcut
        self.shortcutIsRegistered = shortcutIsRegistered
        self.localModel = localModel
        self.openSettings = openSettings
        self.refreshDictionaries = refreshDictionaries
        self.onOutstandingChange = onOutstandingChange
    }

    /// Whether something still needs the reader — nil until the board can say. Before the first
    /// probe answers, and while the dictionaries are still being read, "nothing outstanding" would
    /// be a guess, and a guess stored is how the window stops opening here on a fresh install.
    var isUnfinished: Bool? {
        guard model.hasAsked, !board.isAsking else { return nil }
        // A permission that could not be checked leaves the answer unknown, not "nothing to do".
        if board.outstanding.isEmpty, !board.unchecked.isEmpty { return nil }
        return !board.outstanding.isEmpty
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
            ForEach(board.steps) { step in
                Section {
                    row(step)
                } header: {
                    // **The summary is the header of the first group, not a group of its own.**
                    // Alone in a section it was grey text in a white box — the shape of a
                    // disabled field — above the rows it was summarising.
                    if step == board.steps.first {
                        summary
                            .font(.body)
                            .textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // **No frame and no window fit of its own.** This was a window once and carried
        // `.frame(width:)` and `.fitsItsContent(width:)` into the tab it became — a second mover
        // on the settings window, with no ceiling, beside `SettingsView`'s clamped one. The pane
        // now only reports its height, like the other five, and `SettingsView` moves the window.
        //
        // macOS posts nothing when a permission changes, and the reader grants them in another app
        // and comes back. Polling is the only way to notice, and `.task` stops it when the window
        // goes away.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: Token.Timing.permissionPoll)
            }
        }
        .onChange(of: isUnfinished, initial: true) { _, unfinished in
            if let unfinished { onOutstandingChange?(unfinished) }
        }
        .confirmationDialog(
            "Remove this model?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { model in
            Button("Remove \(model.size.displayName)", role: .destructive) {
                localModel?.removeModel(model.size)
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("\(model.size.displayName) frees \(Self.bytes(model.bytes)) on this Mac. Using it again means downloading it again.")
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
            // **Not checked is not in place.** Nothing is waiting on the reader, but "everything
            // needed" would be said over a row reading "Not checked".
            case 0 where !board.unchecked.isEmpty:
                Text("Nothing is waiting on you, but a permission could not be checked.")
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
                Text("Nothing is waiting on you. The local model is still one click away, in the last row.")
            case 0: Text("Everything needed is in place. Anything here can still be changed.")
            case 1: Text("One thing is still needed.")
            default: Text("^[\(board.outstanding.count) thing](inflect: true) are still needed.")
            }
        }
    }

    @ViewBuilder private func row(_ step: SetupBoard.Step) -> some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                mark(step)
                title(step).font(.headline)
                Spacer(minLength: scale.space.inline)
                state(step).foregroundStyle(.secondary)
            }

            detail(step)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            actions(step)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The marks a row can carry. State, not actions — which is why they are named here and not
    /// in `ActionSymbol`, except the warning, which is that enum's own.
    private enum Mark {
        static let settled = "checkmark.circle.fill"
        static let open = "circle"
    }

    @ViewBuilder private func title(_ step: SetupBoard.Step) -> some View {
        switch step {
        case .permission(.accessibility): Text("Accessibility")
        case .permission(.screenRecording): Text("Screen Recording")
        case .dictionary: Text("Study Dictionary")
        case .shortcut: Text("Lookup Shortcut")
        case .localModel: Text("Translation and Meanings")
        }
    }

    @ViewBuilder private func state(_ step: SetupBoard.Step) -> some View {
        if step == .localModel, let modelState = modelStateLabel {
            modelState
        } else if board.isSettled(step), board.isAvailable(step) {
            Text("Ready")
        } else if let permission = step.permission, board.isUnchecked(permission) {
            Text("Not checked")
        } else if step.needsReader {
            Text("Needed")
        } else {
            Text("Not set")
        }
    }

    @ViewBuilder private func detail(_ step: SetupBoard.Step) -> some View {
        switch step {
        case .permission(let permission): permissionDetail(permission)
        case .dictionary: dictionaryDetail
        case .shortcut: shortcutDetail
        case .localModel: modelDetail
        }
    }

    @ViewBuilder private func permissionDetail(_ permission: Permission) -> some View {
        if board.isUnchecked(permission) {
            Text("""
                 Whether this is allowed could not be checked just now. It may well be allowed \
                 already; the list it is granted in is below.
                 """)
        } else {
            Text(permission.explanation(isGranted: board.isGranted(permission)))
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
                 The dictionary you study from is no longer turned on in the Dictionary app. \
                 Meanings are being matched in whichever dictionary answers instead, and study \
                 progress is kept separately for each dictionary, so it is building up apart \
                 from yours.
                 """)
        } else if let chosen = board.chosenDictionary {
            Text(DictionaryLabels.studying(from: chosen))
        } else if board.chosen == nil, let automatic = board.automaticDictionary {
            Text(DictionaryLabels.studying(from: automatic))
        } else if board.isAsking {
            // **Asked and failed is not still asking.** The list is fetched once, in a task that
            // has already ended, so without this distinction a service that answered nothing left
            // the row saying "Asking…" for the life of the window.
            if dictionary?.hasAsked == true {
                Text("Your dictionaries could not be read, so none can be suggested.")
            } else {
                Text("Looking for your dictionaries…")
            }
        } else {
            switch board.proposal {
            case .propose(let one):
                Text("""
                     \(one.identity.name) matches your language. You study from one dictionary \
                     at a time, and changing it later starts review over.
                     """)
            case .choose(let several):
                Text("""
                     ^[\(several.count) dictionary](inflect: true) that you have turned on match \
                     your language. Choose the one to study from. Changing it later starts review \
                     over.
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
                // **A dictionary the reader deliberately installed is not an absence.** Checked before
                // the two branches below, because both of them tell the reader to go and enable
                // something — and someone who has enabled 牛津粵英雙語詞典 has already done it. `yue` is
                // a different language code from `zh`, so no Chinese reader matches it and the rule
                // cannot see the choice they made. The menu always let them pick it; this is the row
                // catching up.
                if let sideways = board.englishForAnotherLanguage.first {
                    Text("""
                         \(sideways.identity.name) looks up English but explains it in another \
                         language. If that is the language you read, study from it.
                         """)
                } else if board.undeclaredEnglishDictionaries.isEmpty {
                    // No promise of automatic detection: nothing watches Dictionary.app, and
                    // "this will notice" would have the reader waiting for something that never
                    // happens. The button beside it is the answer.
                    Text("""
                         None of your dictionaries explains English in your language. Turn one on \
                         in the Dictionary app, under Settings, then choose Check Again.
                         """)
                } else {
                    // "Some", not "none": a reader can have NOAD — which declares its languages
                    // and is simply not for them — beside an undeclared conversion, and a sentence
                    // claiming nothing declares anything would be false in front of them.
                    Text("""
                         Some of your dictionaries do not say which language they explain English \
                         in, so none can be suggested. Choose one yourself, or turn on a dictionary \
                         for your language in the Dictionary app.
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
        case .notDownloaded, .stopped: board.modelDeclined ? Text("Not downloaded") : nil
        }
    }

    /// The tick, the warning, or neither. **A step this Mac cannot have gets no tick**: a green
    /// check over "Not available" would claim the reader had received something they have not.
    ///
    /// The warning's tint comes from `StatusPalette`, which holds 3:1 on the form's ground in
    /// both appearances and steps up under Increase Contrast. It was the system orange, which
    /// does neither. Each mark is a different shape as well as a different colour, and the state
    /// word sits at the other end of the row.
    @ViewBuilder private func mark(_ step: SetupBoard.Step) -> some View {
        if !board.isAvailable(step) {
            Image(systemName: Mark.open).foregroundStyle(.secondary)
        } else if board.isSettled(step) {
            Image(systemName: Mark.settled).foregroundStyle(.green)
        } else if step.needsReader {
            ActionSymbol.warning.image
                .foregroundStyle(StatusPalette.caution.color(in: scheme, contrast: contrast))
        } else {
            // A step the reader need not act on is not a warning.
            Image(systemName: Mark.open).foregroundStyle(.secondary)
        }
    }

    /// What the model does, what it costs, and — while it is absent — what does its jobs instead.
    /// The fallback is named because it is measured to be worse, and a reader deciding whether a
    /// 3 GB download is worth it deserves to know what they have without it. **It is named only
    /// where it is what answers**: during an upgrade the model already installed goes on working,
    /// and telling that reader their senses are picked by a simpler match would be false.
    @ViewBuilder private var modelDetail: some View {
        switch board.model {
        case .ready(let size):
            Text("\(size.displayName) translates your sentences and chooses the meaning you met, on this Mac. Nothing is sent anywhere.")
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
            Text("What this Mac can do about the local model is not known yet.")
        case .notDownloaded:
            VStack(alignment: .leading, spacing: scale.space.line) {
                if let size = localModel?.recommended {
                    Text("\(size.displayName) translates your sentences and chooses the meaning you met, on this Mac — a \(Self.bytes(size.manifest.totalBytes)) download.")
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
                     Until then, meanings are chosen by Apple's on-device model, and by a simpler \
                     match where it declines. Sentences are translated by Apple where its language \
                     pack is installed — which cannot be told which meaning you met, and misreads \
                     some.
                     """)
            } else {
                Text("""
                     Until then, meanings are chosen by a simpler match. Sentences are translated \
                     by Apple where its language pack is installed — which cannot be told which \
                     meaning you met, and misreads some.
                     """)
            }
        } else {
            if board.engine.isOnDevice {
                Text("""
                     Without a local model, meanings are chosen by Apple's on-device model, and by \
                     a simpler match where it declines. Sentences are translated by Apple where its \
                     language pack is installed — which cannot be told which meaning you met, and \
                     misreads some.
                     """)
            } else {
                Text("""
                     Without a local model, meanings are chosen by a simpler match. Sentences are \
                     translated by Apple where its language pack is installed — which cannot be \
                     told which meaning you met, and misreads some.
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
            Text("Select a word in any app and press \(shortcut.label()).")
        } else if let shortcut = shortcut?.shortcut, shortcut.isUsable {
            // **Registered is not the same as well-formed.** Another app can hold the combination
            // exclusively, and telling the reader to press one that was refused sends them to try
            // something that cannot work and to doubt the app when it does not.
            // **Not "another app is holding it".** That is the commonest reason and not the only
            // one, and this surface is not told which occurred — the menu carries the registration
            // error when there is one. Naming a cause the app has not established is how a reader
            // goes looking for the wrong thing.
            // **Not "or look words up from the menu".** That named an item the menu no longer
            // carries: Look Up Selection was removed when the menu was cut back to what a reader
            // reaches for, and a refusal that offers a route which does not exist sends them
            // looking for it.
            Text("""
                 \(shortcut.label()) could not be set up, so it will not look anything up. Choose \
                 another combination.
                 """)
        } else {
            Text("No shortcut is set, so a selection cannot be looked up until you choose one.")
        }
    }

    /// **Whether this step's action is the one drawn prominent — at most one on the whole pane.**
    ///
    /// Every primary action was prominent, independently: with both grants missing, no dictionary
    /// chosen and no model, a fresh install showed four filled buttons, and when everything is
    /// prominent nothing says what to do first. The first step still needing the reader is the
    /// answer to that question, and it is the only one that gets the fill.
    private func isNext(_ step: SetupBoard.Step) -> Bool {
        board.outstanding.first == step
    }

    @ViewBuilder private func actions(_ step: SetupBoard.Step) -> some View {
        switch step {
        case .permission(let permission): permissionActions(permission, step: step)
        case .dictionary:
            dictionaryActions
        case .localModel:
            modelActions
        case .shortcut:
            if let openSettings {
                Button("Change…") { openSettings(.lookup) }
                    .stepAction()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func permissionActions(_ permission: Permission, step: SetupBoard.Step) -> some View {
        if !board.isGranted(permission) {
            // Secondary, not tertiary: this is the path the reader is being sent to find.
            Text(permission.location)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: scale.space.stack) {
                // macOS prompts only the first time ever, which is why the second button
                // exists and why the list is named above it. **Not offered for a permission
                // that could not be checked**: asking for a grant that may stand raises a dialog
                // that grants nothing.
                if !board.isUnchecked(permission) {
                    Button("Request Access…") { permission.request() }
                        .stepAction(prominent: isNext(step))
                }
                // *System* Settings: this button is inside the app's own Settings window,
                // where "Open Settings…" named the window the reader was already in.
                Button("Open System Settings…") { NSWorkspace.shared.open(permission.settingsURL) }
                    .stepAction()
            }
            .controlSize(.small)
        }
    }

    /// **The models on this Mac, and which one answers.** Shown only where there is a choice to
    /// make — one model is not a switch, it is a label — and each row says what it occupies, so
    /// keeping it can be weighed against what it costs.
    ///
    /// **A radio group, which is what "one of these" is.** It was a column of plain buttons each
    /// drawing `largecircle.fill.circle` or `circle`: it looked like radio buttons and told
    /// VoiceOver nothing about which was selected. Removing a model sat beside each as a plain
    /// 10-point word that deleted gigabytes on one click; it is a menu now, and it asks.
    @ViewBuilder private func modelSwitch(_ localModel: LocalModelChoice) -> some View {
        if localModel.onDisk.count > 1 {
            VStack(alignment: .leading, spacing: scale.space.inline) {
                Picker(
                    "Answer with",
                    selection: Binding(get: { localModel.chosen }, set: { localModel.choose($0) })
                ) {
                    ForEach(localModel.onDisk) { model in
                        // A name and a size, composed: neither is prose for a translator.
                        Text(verbatim: "\(model.size.displayName) — \(Self.bytes(model.bytes))")
                            .tag(LocalModelSize?.some(model.size))
                    }
                }
                .pickerStyle(.radioGroup)
                // **Said where it is true, and only then.** A reader comparing answers must know
                // when the one in front of them is not from the model they chose.
                if case .standingIn(let answering, let wanted) = localModel.answering {
                    Text("\(wanted.displayName) needs more free memory than this Mac has right now, so \(answering.displayName) is answering.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Menu("Remove a Model") {
                    ForEach(localModel.onDisk) { model in
                        Button { removing = model } label: {
                            Text(verbatim: "\(model.size.displayName) (\(Self.bytes(model.bytes)))…")
                        }
                    }
                }
                .fixedSize()
                .controlSize(.small)
            }
        }
    }

    /// **Where the weights come from.** Offered beside the download, which is the one moment it
    /// matters — and the default measures both hosts, so a reader who has no opinion never needs
    /// one. Named for what each does rather than for the companies: "fastest" is the answer to
    /// the question a reader actually has.
    @ViewBuilder private func sourcePicker(_ localModel: LocalModelChoice) -> some View {
        Picker(
            "From",
            selection: Binding(get: { localModel.source }, set: { localModel.chooseSource($0) })
        ) {
            Text("Fastest available").tag(ModelSource.fastest)
            Text(verbatim: "ModelScope").tag(ModelSource.modelScope)
            Text(verbatim: "Hugging Face").tag(ModelSource.huggingFace)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    /// **A download never starts unasked**, so it is always a button — and it stays in the row after
    /// Not Now, one click away, for as long as there is something to download.
    @ViewBuilder private var modelActions: some View {
        if let localModel {
            VStack(alignment: .leading, spacing: scale.space.inline) {
            modelSwitch(localModel)
            HStack(spacing: scale.space.stack) {
                switch localModel.state {
                case .downloading:
                    Button("Stop") { localModel.cancel() }
                        .stepAction()
                case .notDownloaded, .stopped:
                    // The size a stopped download was of, so Resume finishes what is on disk rather
                    // than starting a second model beside it.
                    if let size = localModel.downloadable {
                        Button(localModel.state == .notDownloaded ? "Download" : "Resume") {
                            localModel.download(size)
                        }
                        .stepAction(prominent: isNext(.localModel))
                        sourcePicker(localModel)
                        if !localModel.declined {
                            Button("Not Now") { localModel.decline() }
                                .stepAction()
                        }
                    }
                case .ready:
                    if let larger = localModel.larger {
                        // **"Download", because that is what one click does.** It said "Use the
                        // larger model", which reads as a switch and starts six gigabytes.
                        Button("Download Larger Model (\(Self.bytes(larger.manifest.totalBytes)))") {
                            localModel.download(larger)
                        }
                        .stepAction()
                    }
                case .tooLittleMemory:
                    EmptyView()
                }
            }
            .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var dictionaryActions: some View {
        HStack(spacing: scale.space.stack) {
            if case .nothingSuitable = board.proposal, !board.isAsking {
                // The sideways offer comes first and is the step's action, because for a reader
                // who installed a dictionary for their own language it is the answer — and "Open
                // Dictionary…" would send them back to a list they have already set.
                if let sideways = board.englishForAnotherLanguage.first {
                    Button("Use \(sideways.identity.name)") { dictionary?.choose(sideways.identity.key) }
                        .stepAction(prominent: isNext(.dictionary))
                    Button("Open Dictionary…") { openDictionaryApp() }
                        .stepAction()
                } else {
                    Button("Open Dictionary…") { openDictionaryApp() }
                        .stepAction(prominent: isNext(.dictionary))
                }
            }
            if let openSettings, !board.isAsking {
                Button(board.chosenDictionary == nil ? "Choose…" : "Change…") {
                    openSettings(.dictionary)
                }
                .stepAction()
            }
            // **The way back from dictionaries that could not be read.** The list is fetched
            // once, in a task that has already ended, and the permission poll does not retry it —
            // so without this a failed or slow probe leaves the row saying it is still looking for
            // the life of the window. It is also how the pane notices a dictionary turned on in
            // Dictionary.app, which the "turn one on" sentence above promises it will.
            if let refreshDictionaries {
                Button(board.isAsking ? "Try Again" : "Check Again") {
                    Task { await refreshDictionaries() }
                }
                .stepAction()
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
    /// **`nonisolated`, because the completion handler below is not on the main actor.** A `View` is
    /// implicitly `@MainActor`, so its statics inherit that isolation and reading one from
    /// `openApplication`'s Sendable completion handler warned — "main actor-isolated static property
    /// 'log' can not be referenced from a Sendable closure", which a later language mode makes an
    /// error. `Logger` is `Sendable` and thread-safe, so there was never a race to fix; what was wrong
    /// was claiming an isolation the value does not need.
    nonisolated private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "setup")

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

private extension View {
    /// A setup row's button: bordered, and filled only where it is the next thing to do.
    ///
    /// **Bordered, never glass.** These are rows of a grouped form — content — and glass is for
    /// what floats over content. They were `.glass` and `.glassProminent`, twelve of them, in a
    /// file whose own header says the rows dropped their glass because glass inside glass muddies
    /// both.
    @ViewBuilder func stepAction(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
