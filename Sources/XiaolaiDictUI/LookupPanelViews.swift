
import XiaolaiDictCore
import SwiftUI
import WebKit

public struct PanelView: View {
    public let content: PanelContent

    public init(content: PanelContent) {
        self.content = content
    }

    public var body: some View {
        switch content {
        case .message(let title, let detail):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .lookup(let presentation):
            VStack(alignment: .leading, spacing: 0) {
                Header(
                    term: presentation.term, lemma: presentation.lemma,
                    source: presentation.source, capture: presentation.capture)
                Divider()
                // The panel is a container that fills in: the heading is there from the first
                // frame, and what the dictionaries say replaces the waiting line when it arrives.
                // Prior encounters, never prior meanings — and absent entirely on a first lookup.
                if let memory = presentation.memory { MemoryStripView(memory: memory) }
                if let outcome = presentation.outcome {
                    OutcomeView(
                        term: presentation.term, outcome: outcome, sense: presentation.sense,
                        met: presentation.met, sentence: presentation.sentence)
                } else {
                    WaitingView(detail: content.waitingDescription)
                }
            }
        }
    }
}

/// Waiting for the dictionaries, saying so. Never a blank pane: the invariant that a failure must
/// not render as confidently as a success applies just as much to a result that has not arrived.
private struct WaitingView: View {
    public let detail: String?

    public var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(detail ?? "Looking up…").foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Header: View {
    public let term: String
    public let lemma: Lemma
    public let source: String?
    public let capture: CaptureQuality

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(term).font(.title2.weight(.semibold))
            if lemma.text != Lemmatizer.canonical(term) {
                // A dictionary form read from the grammar around the word is a judgement; says so.
                Text(lemma.basis == .inferred ? "→ \(lemma.text) (from context)" : "→ \(lemma.text)")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                if let source { Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                // What is recorded with the word says what it is; a partial sentence is not passed
                // off as the whole one.
                if let caveat = capture.context.caveat { Text(caveat).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 28)  // clear of the transparent title bar's controls
        .padding(.bottom, 12)
    }
}

private struct OutcomeView: View {
    /// The encounter a tap on `senseKey` amounts to. Nil when there is nothing to key it to — an
    /// entry with no id, or a dictionary whose senses carry none.
    public static func encounter(from entry: DictionaryEntry, senseKey: String) -> SenseEncounter? {
        guard let entryKey = entry.entryKey,
              let sense = entry.senses.first(where: { $0.key == senseKey }),
              sense.keyKind != SenseKeyKind.none
        else { return nil }
        return SenseEncounter(
            dictionary: entry.dictionary, entryID: entryKey, senseKey: sense.key,
            senseKeyKind: sense.keyKind, sensePath: sense.path, entrySenseCount: entry.senseCount,
            senseHash: sense.textHash, gloss: sense.label, chosenBy: .reader, chosenAt: .now)
    }

    public let term: String
    public let outcome: LookupOutcome
    /// Nil while the selector is still deciding. The entry does not wait for it.
    public let sense: SenseMark?
    public let met: Set<StudyItem>
    /// The reader's own sentence, where one was captured.
    public let sentence: String?
    /// Nil until the reader picks a row: the first entry is shown, but nothing is *claimed* to be
    /// the sense they read.
    @State private var selected: OutlineSelection?
    @Environment(\.studySense) private var studySense

    public var body: some View {
        switch outcome {
        case .entries(let entries, let unreadable):
            VStack(alignment: .leading, spacing: 0) {
                if !unreadable.isEmpty {
                    // A dictionary is named once however many of its records failed, so this says
                    // "an entry": claiming all of them, or only one, would both be guesses.
                    Notice(text: "An entry in \(unreadable.joined(separator: ", ")) could not be read, so what is shown is not all of it.")
                }
                if case .couldNot(let why) = sense {
                    // The other half of marking a sense: saying why it did not.
                    Notice(text: why.reason, symbol: "questionmark.circle")
                }
                HStack(spacing: 0) {
                    OutlineSidebar(
                        outline: EntryOutline(entries: Array(entries)), selected: $selected, mark: sense)
                        .frame(width: 260)
                    Divider()
                    // `entries` is never empty, and the index is clamped into it. Selecting a sense
                    // still renders its whole entry: decision D2 is to mark a sense, never to jump
                    // to it — a wrong jump hides the right sense, a wrong mark is recoverable.
                    let index = min(max(selected?.entryIndex ?? 0, 0), entries.count - 1)
                    EntryPane(
                        entry: entries[index], term: term,
                        popup: EntryPresentation(entry: entries[index], mark: sense, met: met),
                        chosenSense: selected?.senseKey, sentence: sentence)
                        .id(index)
                }
                // Tapping a sense is the reader saying "this is the one" — a fact, recorded as
                // theirs and never merged with the selector's guess. It works in any dictionary,
                // including an auxiliary one, which is what D8 allows.
                .onChange(of: selected) { _, choice in
                    guard let choice, let key = choice.senseKey,
                          let encounter = Self.encounter(
                              from: entries[min(max(choice.entryIndex, 0), entries.count - 1)], senseKey: key)
                    else { return }
                    studySense(encounter)
                }
            }
        case .plainText(let text, let failure):
            VStack(alignment: .leading, spacing: 0) {
                Notice(text: "The dictionary service could not answer, so this is the plain-text definition. (\(failure))")
                ScrollView {
                    Text(text).textSelection(.enabled).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .notFound(let failure):
            VStack(alignment: .leading, spacing: 10) {
                Text("No entry for “\(term)” in your dictionaries.").font(.headline)
                if let failure { Notice(text: "The dictionary service could not be asked: \(failure)") }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The sidebar: dictionary → entry → sense (decision D1), each dictionary a section the reader can
/// collapse. `NavigationSplitView` is unusable in a hosted window — measured in the ledger-ux
/// spike, which saw it lay out 1284 pt inside a 640 pt frame — so this is a plain `List`.
private struct OutlineSidebar: View {
    public let outline: EntryOutline
    @Binding var selected: OutlineSelection?
    public let mark: SenseMark?

    public var body: some View {
        List(selection: $selected) {
            ForEach(outline.dictionaries) { dictionary in
                Section {
                    ForEach(dictionary.entries) { entry in
                        EntryRow(entry: entry).tag(OutlineSelection.entry(entry.index))
                        ForEach(entry.senses) { sense in
                            SenseRow(sense: sense, mark: mark).tag(sense.id)
                        }
                    }
                } header: {
                    Text(dictionary.name).lineLimit(2)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One entry in the sidebar — and, when it is not headed by the term itself, which headword
/// answered. A dictionary that cannot key senses says so here, once, rather than showing rows it
/// cannot stand behind.
private struct EntryRow: View {
    public let entry: EntryNode

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.label).lineLimit(1)
            if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if entry.senseKeyKind == SenseKeyKind.none {
                Text("senses not marked in this dictionary").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One sense under its entry. A sense addressed only by where it sits is a weaker claim than one
/// carrying the publisher's id, and reads as one.
private struct SenseRow: View {
    public let sense: SenseNode
    public let mark: SenseMark?

    /// Marked, never jumped to (decision D2): a wrong jump hides the right sense, a wrong mark is
    /// visible and recoverable — which matters, because the selector's measured confidently-wrong
    /// rate is not small.
    private var isMarked: Bool { mark?.key == sense.sense.key }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(sense.sense.path.ordinal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(sense.label).font(.callout).lineLimit(2)
            if sense.keyKind == .position {
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("This dictionary does not number its senses, so this one is identified by its position.")
            }
            if isMarked, let mark {
                Spacer(minLength: 4)
                // A sense XiaolaiDict guessed and one the reader chose must never read alike.
                Image(systemName: mark.isHypothesis ? "sparkle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(mark.isHypothesis ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .help(mark.isHypothesis
                        ? "XiaolaiDict's guess at the sense you were reading, from your sentence. It may be wrong."
                        : "The only sense in this entry.")
            }
        }
        .padding(.leading, 14)
    }
}

/// A result that is less than it looks must say so, in the result.
public struct Notice: View {
    public let text: String
    public var symbol = "exclamationmark.triangle"

    public var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08))
    }
}

/// The strip that says the reader has been here before — how many times, when, and where. It never
/// says what the word meant last time: an earlier encounter says *you should know this*, while an
/// earlier gloss answers the question and destroys the retrieval (`feature-ledger-ux.md` C2).
private struct MemoryStripView: View {
    public let memory: MemoryStrip

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(memory.headline).font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(memory.lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if memory.more > 0 {
                    Text("and \(memory.more) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        // The honey accent only where XiaolaiDict owns the meaning — memory and study (J2).
        .background(Color.accentColor.opacity(0.07))
    }
}

/// One entry, or why it could not be shown — never a blank pane that looks like an entry. Above the
/// publisher's own rendering sits the chrome XiaolaiDict draws: what this entry is, how it sounds, and
/// what can be done with it.
private struct EntryPane: View {
    public let entry: DictionaryEntry
    public let term: String
    public let popup: EntryPresentation
    /// The sense row the reader selected in the sidebar, if any — what pin and speak act on.
    public let chosenSense: String?
    /// The reader's own sentence, for the pane that explains it.
    public let sentence: String?
    @State private var failure: String?
    @State private var explanation: SentenceExplanation?

    private var selected: SensePresentation? {
        popup.senses.first { $0.key != nil && $0.key == chosenSense }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EntryChrome(
                popup: popup, selected: selected, term: term, sentence: sentence,
                explanation: $explanation)
            if let explanation { SentencePaneView(explanation: explanation) }
            Divider()
            if let failure {
                VStack(alignment: .leading) {
                    Notice(text: "This entry could not be displayed: \(failure)")
                    Spacer()
                }
            } else {
                EntryView(html: entry.html) { failure = $0 }
            }
        }
    }
}

/// Entry heading · part of speech · IPA · speak · copy · pin.
private struct EntryChrome: View {
    public let popup: EntryPresentation
    public let selected: SensePresentation?
    public let term: String
    /// The reader's own sentence, when one was captured.
    public let sentence: String?
    @Environment(\.pinNote) private var pin
    @State private var copied = false
    @State private var explaining = false
    @State private var speechCaveat: String?
    @Binding var explanation: SentenceExplanation?

    private var spokenText: String { selected?.label ?? popup.heading }

    private func explain() async {
        guard let sentence else { return }
        explaining = true
        defer { explaining = false }
        explanation = await OnDeviceSentenceExplainer().explain(SentenceQuestion(
            sentence: sentence, term: term, senseText: selected?.label ?? popup.senses.first?.label))
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(popup.heading).font(.title3.weight(.semibold))
            if !popup.partsOfSpeech.isEmpty {
                Text(popup.partsOfSpeech.joined(separator: " · "))
                    .font(.caption).italic().foregroundStyle(.secondary)
            }
            ForEach(popup.pronunciations.prefix(2), id: \.self) { pronunciation in
                Text(pronunciation).font(.caption).foregroundStyle(.secondary)
            }
            if !popup.canKeySenses {
                Text("whole entries only")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("This dictionary marks its senses with nothing XiaolaiDict can key a card to.")
            }
            Spacer(minLength: 8)

            Button {
                Speech.say(spokenText)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            // Spike S1 measured that no enhanced or premium voice is downloaded by default. A
            // reader who does not know better ones exist concludes that XiaolaiDict sounds bad.
            // Computed once when the chrome appears, never in the body: both calls behind it are
            // expensive, and a body is evaluated many times per layout.
            .help(speechCaveat ?? "Speak")
            .task(id: spokenText) {
                speechCaveat = Speech.caveat(for: Lemmatizer.language(of: spokenText, in: nil) ?? "en")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected?.label ?? popup.heading, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy")

            // Decision D4: on request, per lookup. Automatic would mean every hover starts a
            // generation, and Milestone 2's whole point is that a hover is cheap.
            Button {
                Task { await explain() }
            } label: {
                Image(systemName: explaining ? "ellipsis" : "text.bubble")
            }
            .disabled(explaining || sentence == nil)
            .help(sentence == nil
                ? "No sentence was captured, so there is nothing to explain."
                : "Explain how this word is used in your sentence — runs on this Mac")

            Button {
                pin(PinnedNote(
                    term: term, heading: popup.heading, dictionary: popup.dictionary,
                    partOfSpeech: selected?.partOfSpeech ?? popup.partsOfSpeech.first,
                    pronunciation: popup.pronunciations.first,
                    // Copied now, by value (decision D3): a dictionary update must not rewrite it.
                    text: selected?.label ?? popup.senses.first?.label ?? popup.heading,
                    senseKey: selected?.key, pinnedAt: .now))
            } label: {
                Image(systemName: "pin")
            }
            .help("Pin this as a note that stays until you close it")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

/// What the on-device model made of the reader's sentence — or why it could not. Never a blank
/// pane: a model that declined says so.
private struct SentencePaneView: View {
    public let explanation: SentenceExplanation

    public var body: some View {
        switch explanation {
        case .explained(let text, let tier):
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // Which tier answered, so "this stayed on my Mac" is visible rather than promised.
                Text(tier == .onDevice ? "on this Mac" : "sent to a remote service")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.05))
        case .unavailable(let why):
            Notice(text: why, symbol: "text.bubble")
        }
    }
}

/// Pinning is the app's job, not the view's; the panel is handed a way to do it.
private struct PinNoteKey: EnvironmentKey {
    public static let defaultValue: @MainActor (PinnedNote) -> Void = { _ in }
}

/// So is writing to the ledger. Decision D8: an auxiliary dictionary's sense becomes a study item
/// only when the reader asks for one, and it is recorded as theirs.
private struct StudySenseKey: EnvironmentKey {
    public static let defaultValue: @MainActor (SenseEncounter) -> Void = { _ in }
}

extension EnvironmentValues {
    public var pinNote: @MainActor (PinnedNote) -> Void {
        get { self[PinNoteKey.self] }
        set { self[PinNoteKey.self] = newValue }
    }

    public var studySense: @MainActor (SenseEncounter) -> Void {
        get { self[StudySenseKey.self] }
        set { self[StudySenseKey.self] = newValue }
    }
}

/// One dictionary entry, rendered from the document the service returned. A document, not a page:
/// no JavaScript, nothing fetched, nothing followed, nothing kept.
private struct EntryView: NSViewRepresentable {
    public let html: String
    public let onFailure: (String) -> Void

    public func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, into: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        /// A local document of a few kilobytes renders in milliseconds; one still loading after this
        /// is stuck, and says so rather than staying a blank pane.
        static let loadLimit: Duration = .seconds(5)

        private let onFailure: (String) -> Void
        private var requested: String?
        /// Set while XiaolaiDict's own load of the document is on its way, so that load — and only it — is
        /// let through the navigation policy.
        private var expectingLoad = false
        private var rulesInstalled = false
        /// Pending until WebKit reports the document finished; fails the pane if it never does.
        private var watchdog: Task<Void, Never>?

        init(onFailure: @escaping (String) -> Void) {
            self.onFailure = onFailure
        }

        func load(_ html: String, into view: WKWebView) {
            guard requested != html else { return }
            requested = html
            Task {
                do {
                    let rules = try await EntryContentRules.compiled()
                    if !rulesInstalled {
                        view.configuration.userContentController.add(rules)
                        rulesInstalled = true
                    }
                } catch {
                    onFailure("its resource blocker could not be prepared (\(error.localizedDescription))")
                    return
                }
                guard requested == html else { return }  // superseded while the rules compiled
                expectingLoad = true
                watchForStall(of: view)
                // As XHTML, not HTML: the entries use Apple's `d:` namespace, and the dictionaries'
                // stylesheets select on it — an HTML parse would drop the namespace and the styling.
                view.load(Data(html.utf8), mimeType: "application/xhtml+xml", characterEncodingName: "UTF-8",
                          baseURL: EntryNavigationPolicy.documentURL)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let allowed = EntryNavigationPolicy.allows(
                url: action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? false, expectingLoad: expectingLoad)
            if allowed { expectingLoad = false }
            return allowed ? .allow : .cancel
        }

        private func watchForStall(of view: WKWebView) {
            watchdog?.cancel()
            watchdog = Task { [weak self, weak view] in
                do { try await Task.sleep(for: Self.loadLimit) } catch { return }  // finished in time
                view?.stopLoading()
                self?.onFailure("it did not finish loading within \(Self.loadLimit.components.seconds) seconds")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            watchdog?.cancel()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            fail(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            fail(error.localizedDescription)
        }

        /// The renderer process died — crashed, or killed for memory — and took the entry with it.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("the page renderer stopped")
        }

        private func fail(_ reason: String) {
            watchdog?.cancel()
            onFailure(reason)
        }
    }
}

/// Which navigations an entry may make: exactly one — XiaolaiDict's own load of the document, in the main
/// frame. Links, redirects, refreshes and frames are all refused. (`.other` alone would admit
/// redirects and meta refreshes too.)
public enum EntryNavigationPolicy {
    public static let documentURL = URL(string: "about:blank")!

    public static func allows(url: URL?, isMainFrame: Bool, expectingLoad: Bool) -> Bool {
        expectingLoad && isMainFrame && url == documentURL
    }
}

/// Blocks every resource an entry's document could fetch — images, stylesheets, fonts, media,
/// anything over any scheme. Entries are self-contained (their stylesheet is inlined), so a fetch
/// is either broken or a request to someone's server; navigation policy does not cover these.
public enum EntryContentRules {
    public static let identifier = "\(XiaolaiDictIdentity.app).entry-resources"
    public static let json = """
        [{"trigger": {"url-filter": ".*", "resource-type": ["image", "style-sheet", "script", "font", "raw", \
        "svg-document", "media", "popup", "ping", "fetch", "websocket", "other"]}, "action": {"type": "block"}}]
        """

    @MainActor private static var compiling: Task<WKContentRuleList, any Error>?

    /// Compiled once per launch; a failed compile is retried next time rather than cached.
    @MainActor
    public static func compiled() async throws -> WKContentRuleList {
        if let compiling { return try await compiling.value }
        let task = Task { () async throws -> WKContentRuleList in
            guard let store = WKContentRuleListStore.default() else {
                throw CocoaError(.featureUnsupported)
            }
            guard let rules = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                throw CocoaError(.featureUnsupported)
            }
            return rules
        }
        compiling = task
        do {
            return try await task.value
        } catch {
            compiling = nil
            throw error
        }
    }
}

public extension CaptureQuality.Context {
    /// What the panel says about the sentence recorded with the word, when it is less than whole.
    var caveat: String? {
        switch self {
        case .complete: nil
        case .mayBeCut: "sentence may be cut"
        case .missing: "no surrounding sentence"
        }
    }
}

extension DictionaryEntry {
    /// Under the dictionary's name in the sidebar, when its entry is not headed by the term itself.
    public var matchNote: String? {
        switch match {
        case .exact: nil
        case .dictionaryForm: "entry for “\(headword)”, its dictionary form"
        case .otherHeadword: "nearest entry: “\(headword)”"
        case .headwordUnknown: "the dictionary did not name its headword"
        }
    }
}

// MARK: - Previews

// The panel's states that need no dictionary behind them. The *waiting* state matters most: the
// panel is a container that fills in, not a payload that is awaited, and how it reads before the
// dictionaries answer is a design decision rather than a loading spinner.
#if DEBUG
// A function, not a global: `LookupPresentation` is not Sendable, and a shared mutable global
// would be a concurrency error rather than a convenience.
private func sampleWaiting() -> LookupPresentation {
    LookupPresentation(
        term: "ephemeral",
        lemma: Lemma(text: "ephemeral", basis: .tagger),
        source: "Safari · A page",
        capture: .accessibility(.accessibilityTextMarkers, context: .complete),
        sentence: "The ephemeral beauty of morning frost.",
        outcome: nil)
}

#Preview("Waiting for the dictionaries") {
    PanelView(content: .lookup(sampleWaiting()))
        .frame(width: 760, height: 520)
}

#Preview("Nothing to look up") {
    PanelView(content: .message(
        title: "Nothing to look up",
        detail: "The frontmost app could not be identified, so its selection cannot be read."))
        .frame(width: 420, height: 150)
}

#Preview("Accessibility is off") {
    PanelView(content: .message(
        title: "XiaolaiDict needs Accessibility access",
        detail: "It reads your selection through Accessibility. Allow XiaolaiDict in "
            + "\(PrivacySettings.accessibilityLocation), then press the shortcut again."))
        .frame(width: 420, height: 180)
}
#endif
