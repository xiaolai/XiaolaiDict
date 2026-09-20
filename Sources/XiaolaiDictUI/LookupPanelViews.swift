
import XiaolaiDictCore
import SwiftUI
import WebKit

public struct PanelView: View {
    @Environment(\.scale) private var scale
    public let content: PanelContent

    public init(content: PanelContent) {
        self.content = content
    }

    public var body: some View {
        switch content {
        case .message(let title, let detail):
            VStack(alignment: .leading, spacing: scale.space.stack) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(scale.space.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .lookup(let presentation):
            LookupPanelContent(presentation: presentation, waiting: content.waitingDescription)
        }
    }
}

/// Waiting for the dictionaries, saying so. Never a blank pane: the invariant that a failure must
/// not render as confidently as a success applies just as much to a result that has not arrived.
struct WaitingView: View {
    @Environment(\.scale) private var scale
    public let detail: String?

    public var body: some View {
        HStack(spacing: scale.space.column) {
            ProgressView().controlSize(.small)
            Text(detail ?? "Looking up…").foregroundStyle(.secondary)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Header: View {
    @Environment(\.scale) private var scale
    public let term: String
    public let lemma: Lemma
    public let source: String?
    public let capture: CaptureQuality

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.space.column) {
            Text(term).font(.title2.weight(.semibold))
            if lemma.text != Lemmatizer.canonical(term) {
                // A dictionary form read from the grammar around the word is a judgement; says so.
                Text(lemma.basis == .inferred ? "→ \(lemma.text) (from context)" : "→ \(lemma.text)")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: scale.space.column)
            VStack(alignment: .trailing, spacing: scale.space.line) {
                if let source { Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                // What is recorded with the word says what it is; a partial sentence is not passed
                // off as the whole one.
                if let caveat = capture.context.caveat { Text(caveat).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.top, Token.Panel.titleBarClearance)  // clear of the transparent title bar's controls
        .padding(.bottom, scale.space.column)
    }
}

struct OutcomeView: View {
    @Environment(\.scale) private var scale
    /// The encounter a tap on `senseKey` amounts to. Nil when there is nothing to key it to — an
    /// entry with no id, or a dictionary whose senses carry none.
    public static func encounter(from entry: DictionaryEntry, senseKey: String) -> SenseEncounter? {
        SenseEncounter.of(entry, senseKey: senseKey, chosenBy: .reader, at: .now)
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
                if case .couldNot(let why, _) = sense {
                    // The other half of marking a sense: saying why it did not.
                    Notice(text: why.reason, symbol: "questionmark.circle")
                }
                HStack(spacing: 0) {
                    OutlineSidebar(
                        outline: EntryOutline(entries: Array(entries)), selected: $selected, mark: sense)
                        .frame(width: Token.Panel.dictionaryList)
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
                    Text(text).textSelection(.enabled).padding(scale.space.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .notFound(let failure):
            VStack(alignment: .leading, spacing: scale.space.column) {
                Text("No entry for “\(term)” in your dictionaries.").font(.headline)
                if let failure { Notice(text: "The dictionary service could not be asked: \(failure)") }
            }
            .padding(scale.space.pad)
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
                    // One row per element. A `ForEach` body that emits an entry *and* its senses
                    // traps SwiftUI's outline coordinator — see `DictionaryNode.rows`.
                    ForEach(dictionary.rows) { row in
                        switch row {
                        case .entry(let entry): EntryRow(entry: entry)
                        case .sense(let sense): SenseRow(sense: sense, mark: mark)
                        }
                    }
                } header: {
                    Text(dictionary.name).lineLimit(Token.Limit.wrapLines)
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
    @Environment(\.scale) private var scale
    public let entry: EntryNode

    public var body: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text(entry.label).lineLimit(1)
            if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(Token.Limit.wrapLines) }
            if entry.senseKeyKind == SenseKeyKind.none {
                Text("senses not marked in this dictionary").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One sense under its entry. A sense addressed only by where it sits is a weaker claim than one
/// carrying the publisher's id, and reads as one.
private struct SenseRow: View {
    @Environment(\.scale) private var scale
    public let sense: SenseNode
    public let mark: SenseMark?

    /// Marked, never jumped to (decision D2): a wrong jump hides the right sense, a wrong mark is
    /// visible and recoverable — which matters, because the selector's measured confidently-wrong
    /// rate is not small.
    private var isMarked: Bool { mark?.key == sense.sense.key }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
            Text("\(sense.sense.path.ordinal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: scale.space.ordinal, alignment: .trailing)
            Text(sense.label).font(.callout).lineLimit(Token.Limit.wrapLines)
            if sense.keyKind == .position {
                Image(systemName: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("This dictionary does not number its senses, so this one is identified by its position.")
            }
            if isMarked, let mark {
                Spacer(minLength: scale.space.line)
                // A sense XiaolaiDict guessed and one the reader chose must never read alike.
                Image(systemName: mark.isHypothesis ? "sparkle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(mark.isHypothesis ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .help(mark.isHypothesis
                        ? "XiaolaiDict's guess at the sense you were reading, from your sentence. It may be wrong."
                        : "The only sense in this entry.")
            }
        }
        .padding(.leading, scale.space.indent)
    }
}

/// A result that is less than it looks must say so, in the result.
public struct Notice: View {
    @Environment(\.scale) private var scale
    public let text: String
    public var symbol = "exclamationmark.triangle"

    public var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(scale.space.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(Token.Opacity.caveatWash))
    }
}

/// The strip that says the reader has been here before — how many times, when, and where. It never
/// says what the word meant last time: an earlier encounter says *you should know this*, while an
/// earlier gloss answers the question and destroys the retrieval (`feature-ledger-ux.md` C2).
struct MemoryStripView: View {
    @Environment(\.scale) private var scale
    public let memory: MemoryStrip

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.space.column) {
            Text(memory.headline).font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: scale.space.tight) {
                ForEach(memory.lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if memory.more > 0 {
                    Text("and \(memory.more) more").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale.space.padAcross)
        .padding(.vertical, scale.space.stack)
        // The honey accent only where XiaolaiDict owns the meaning — memory and study (J2).
        .background(Color.accentColor.opacity(Token.Opacity.memoryWash))
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
    @Environment(\.scale) private var scale
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
        HStack(alignment: .firstTextBaseline, spacing: scale.space.stack) {
            Text(popup.heading).font(.title3.weight(.semibold))
            if !popup.partsOfSpeech.isEmpty {
                Text(popup.partsOfSpeech.joined(separator: " · "))
                    .font(.caption).italic().foregroundStyle(.secondary)
            }
            ForEach(popup.pronunciations.prefix(Token.Limit.pronunciations), id: \.self) { pronunciation in
                Text(pronunciation).font(.caption).foregroundStyle(.secondary)
            }
            if !popup.canKeySenses {
                Text("whole entries only")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("This dictionary marks its senses with nothing XiaolaiDict can key a card to.")
            }
            Spacer(minLength: scale.space.stack)

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
        .padding(.horizontal, scale.space.padAcross)
        .padding(.vertical, scale.space.stack)
    }
}

/// What the on-device model made of the reader's sentence — or why it could not. Never a blank
/// pane: a model that declined says so.
struct SentencePaneView: View {
    @Environment(\.scale) private var scale
    public let explanation: SentenceExplanation

    public var body: some View {
        switch explanation {
        case .explained(let text, let tier):
            VStack(alignment: .leading, spacing: scale.space.line) {
                Text(text).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // Which tier answered, so "this stayed on my Mac" is visible rather than promised.
                Text(tier == .onDevice ? "on this Mac" : "sent to a remote service")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, scale.space.padAcross)
            .padding(.vertical, scale.space.column)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(Token.Opacity.senseWash))
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
        static let loadLimit = Token.Timing.entryLoad

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
func sampleWaiting() -> LookupPresentation {
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

// MARK: - A word actually looked up
//
// The state the panel exists for, and the one that had no preview: an entry, its senses in the
// sidebar, a sense marked, the memory strip and the reader's own sentence. It needs no dictionary
// installed — `DictionaryEntry` takes the markup as a string, so the markup is here, and
// `EntryDocument.parse` reads it exactly as it reads Apple's. That is the point of building the
// sample this way rather than hand-assembling senses: a preview that bypassed the parser could
// look right while the parser was wrong.

/// Apple's own shape: `d:entry` with an id, a headword, a respelling, and `x_xd0` blocks holding
/// `x_xd1` senses that carry publisher ids. Trimmed from the fixture `SenseParsingTests` uses.
func sampleMarkup(_ style: String = sampleStyle) -> String {
    """
    <html xmlns="http://www.w3.org/1999/xhtml"     xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">    <head><style>\(style)</style></head><body>    <d:entry id="m_en_gbus0362750">    <span class="hg x_xh0"><span homograph="1" class="hw">fine</span>    <span d:prn="US" class="ph t_respell">fīn<d:prn></d:prn></span></span>    <span id="m_en_gbus0362750.004" class="se1 x_xd0">    <span class="posg x_xdh"><span d:pos="1" class="pos">adjective<d:pos></d:pos></span></span>    <span id="m_en_gbus0362750.005" class="se2 x_xd1 hasSn">    <span d:def="1" class="df">of high quality<d:def></d:def></span>    <span class="eg"><span class="ex">a fine piece of filmmaking</span></span></span>    <span id="m_en_gbus0362750.020" class="se2 x_xd1 hasSn">    <span d:def="1" class="df">in good health and feeling well</span>    <span class="eg"><span class="ex">&#8220;How are you?&#8221; &#8220;Fine, thanks.&#8221;</span></span></span>    <span id="m_en_gbus0362750.024" class="se2 x_xd1 hasSn">    <span d:def="1" class="df">(of weather) bright and clear</span></span></span>    <span id="m_en_gbus0362750.029" class="se1 x_xd0">    <span class="posg x_xdh"><span d:pos="2" class="pos">adverb<d:pos></d:pos></span></span>    <span id="m_en_gbus0362750.030" class="msDict x_xd1 t_core">    <span d:def="1" class="df">in a satisfactory or pleasing manner</span></span></span>    </d:entry></body></html>
    """
}

/// Enough CSS that the pane reads as an entry rather than as a run-on line. Apple ships its own
/// with each dictionary; this stands in for it so the preview shows the shape the reader sees.
let sampleStyle = """
    body { font: -apple-system-body; margin: 14px 16px; color: -apple-system-label; }
    .hw { font-size: 1.5em; font-weight: 600; }
    .ph { color: -apple-system-secondary-label; margin-left: .4em; }
    .pos { font-style: italic; color: -apple-system-secondary-label; }
    .x_xd0 { display: block; margin-top: .9em; }
    .x_xd1 { display: block; margin: .35em 0 0 1.1em; text-indent: -1.1em; }
    .ex { color: -apple-system-secondary-label; font-style: italic; }
    .eg { display: block; margin-left: 1.1em; }
    """

func sampleEntry(_ name: String, style: String = sampleStyle) -> DictionaryEntry {
    let markup = sampleMarkup(style)
    return DictionaryEntry(
        dictionary: DictionaryIdentity(name: name, identifier: name, version: "2.3.1"),
        headword: "fine", lookedUp: "fine", html: markup,
        document: EntryDocument.parse(markup))
}

/// The reader has been here twice before, so the strip has something to say. Below two occasions
/// it stays away entirely, which is the state the other previews already cover.
private func sampleMemory() -> MemoryStrip? {
    MemoryStrip(PriorEncounters(occasions: [
        PriorEncounter(at: .now.addingTimeInterval(-7_200), where: "Safari", title: "A page"),
        PriorEncounter(at: .now.addingTimeInterval(-259_200), where: "Preview", title: "Ishiguro.pdf"),
    ]))
}

func sampleLookup(_ mark: SenseMark?) -> LookupPresentation {
    // Built from `fine`, not from `sampleWaiting()`. Starting from the waiting sample was the
    // first version and it was wrong in a way a preview is meant to catch: the header read
    // "ephemeral" above an entry for "fine", which is a panel showing one word and defining
    // another. What the reader looked up and what the entry is have to be the same word.
    //
    // Force-unwrapped: the list is two literal entries, so nil here would be this preview being
    // wrong about its own sample rather than anything the app could hit.
    let entries = NonEmpty([
        sampleEntry("New Oxford American Dictionary"), sampleEntry("Oxford Thesaurus"),
    ])!
    return LookupPresentation(
        term: "fine",
        lemma: Lemma(text: "fine", basis: .tagger),
        source: "Safari · A page",
        capture: .accessibility(.accessibilityTextMarkers, context: .complete),
        sentence: "It was a fine piece of filmmaking, and the weather held.",
        outcome: .entries(entries, unreadable: []),
        sense: mark,
        memory: sampleMemory())
}

/// The ordinary success: the reader's own tap, which is a fact and is drawn as one.
#Preview("An entry, sense chosen by the reader") {
    PanelView(content: .lookup(sampleLookup(
        .chosen(key: "m_en_gbus0362750.005", by: .reader))))
        .frame(width: 760, height: 520)
}

/// The selector's guess. The same mark, drawn as the hypothesis it is — the difference between
/// these two previews is the whole of `chosen_by`, and it should be visible at a glance.
#Preview("An entry, sense guessed by XiaolaiDict") {
    PanelView(content: .lookup(sampleLookup(
        .chosen(key: "m_en_gbus0362750.020", by: .model))))
        .frame(width: 760, height: 520)
}

/// Marked nothing, and saying why. The other half of "the panel can mark a sense, and can say why
/// it did not" — and the state a screenshot of a good lookup never catches.
#Preview("An entry, nothing marked") {
    PanelView(content: .lookup(sampleLookup(.couldNot(.tooClose))))
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
