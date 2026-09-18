import XiaolaiDictCore
import SwiftUI
import WebKit

struct PanelView: View {
    let content: PanelContent

    var body: some View {
        switch content {
        case .message(let title, let detail):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .lookup(let term, let lemma, let source, let capture, let outcome):
            VStack(alignment: .leading, spacing: 0) {
                Header(term: term, lemma: lemma, source: source, capture: capture)
                Divider()
                OutcomeView(term: term, outcome: outcome)
            }
        }
    }
}

private struct Header: View {
    let term: String
    let lemma: Lemma
    let source: String?
    let capture: CaptureQuality

    var body: some View {
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
    let term: String
    let outcome: LookupOutcome
    @State private var selected: Int? = 0

    var body: some View {
        switch outcome {
        case .entries(let entries, let unreadable):
            VStack(alignment: .leading, spacing: 0) {
                if !unreadable.isEmpty {
                    Notice(text: "The entry in \(unreadable.joined(separator: ", ")) could not be read.")
                }
                HStack(spacing: 0) {
                    List(entries.indices, id: \.self, selection: $selected) { index in
                        EntryRow(entry: entries[index])
                    }
                    .listStyle(.sidebar)
                    .frame(width: 210)
                    Divider()
                    // `entries` is never empty, and the index is clamped into it.
                    let entry = entries[min(max(selected ?? 0, 0), entries.count - 1)]
                    EntryPane(entry: entry).id(entry.dictionary)
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

/// A dictionary in the sidebar — and, when it answered with another headword, which.
private struct EntryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.dictionary).lineLimit(2)
            if let note = entry.matchNote { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A result that is less than it looks must say so, in the result.
struct Notice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08))
    }
}

/// One entry, or why it could not be shown — never a blank pane that looks like an entry.
private struct EntryPane: View {
    let entry: DictionaryEntry
    @State private var failure: String?

    var body: some View {
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

/// One dictionary entry, rendered from the document the service returned. A document, not a page:
/// no JavaScript, nothing fetched, nothing followed, nothing kept.
private struct EntryView: NSViewRepresentable {
    let html: String
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
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
enum EntryNavigationPolicy {
    static let documentURL = URL(string: "about:blank")!

    static func allows(url: URL?, isMainFrame: Bool, expectingLoad: Bool) -> Bool {
        expectingLoad && isMainFrame && url == documentURL
    }
}

/// Blocks every resource an entry's document could fetch — images, stylesheets, fonts, media,
/// anything over any scheme. Entries are self-contained (their stylesheet is inlined), so a fetch
/// is either broken or a request to someone's server; navigation policy does not cover these.
enum EntryContentRules {
    static let identifier = "\(XiaolaiDictIdentity.app).entry-resources"
    static let json = """
        [{"trigger": {"url-filter": ".*", "resource-type": ["image", "style-sheet", "script", "font", "raw", \
        "svg-document", "media", "popup", "ping", "fetch", "websocket", "other"]}, "action": {"type": "block"}}]
        """

    @MainActor private static var compiling: Task<WKContentRuleList, any Error>?

    /// Compiled once per launch; a failed compile is retried next time rather than cached.
    @MainActor
    static func compiled() async throws -> WKContentRuleList {
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

extension CaptureQuality.Context {
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
    var matchNote: String? {
        switch match {
        case .exact: nil
        case .dictionaryForm: "entry for “\(headword)”, its dictionary form"
        case .otherHeadword: "nearest entry: “\(headword)”"
        case .headwordUnknown: "the dictionary did not name its headword"
        }
    }
}
