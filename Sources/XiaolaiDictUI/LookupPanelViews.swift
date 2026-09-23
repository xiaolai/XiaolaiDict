
import XiaolaiDictCore
import SwiftUI

public struct PanelView: View {
    @Environment(\.scale) private var scale
    public let content: PanelContent

    public init(content: PanelContent) {
        self.content = content
    }

    public var body: some View {
        switch content {
        case .message(let title, let detail):
            // Both arrive localized — `detail` is sometimes the reason a reader was given for a
            // selection that could not be read — so neither is looked up a second time here.
            VStack(alignment: .leading, spacing: scale.space.stack) {
                Text(verbatim: title).font(.headline)
                Text(verbatim: detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(scale.space.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .lookup(let presentation):
            LookupPanelContent(presentation: presentation, waiting: content.waitingDescription)
                .id(presentation.request)
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
            Text(verbatim: detail ?? String(localized: "Looking up…",
                                            comment: "Shown while a lookup is still being made"))
                .foregroundStyle(.secondary)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

extension DictionaryEntry {
    /// Under the dictionary's name in the sidebar, when its entry is not headed by the term itself.
    public var matchNote: String? {
        switch match {
        case .exact: nil
        case .dictionaryForm:
            String(localized: "entry for “\(headword)”, its dictionary form",
                   comment: "Under a dictionary's name when it answered with the word's lemma")
        case .otherHeadword:
            String(localized: "nearest entry: “\(headword)”",
                   comment: "Under a dictionary's name when it answered with a different headword")
        case .headwordUnknown:
            String(localized: "the dictionary did not name its headword",
                   comment: "Under a dictionary's name when its entry carries no headword")
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
        request: 1,
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
        request: 2,
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

// The panel's own two messages, previewed from the same values the app shows — a second copy here
// is how the previews came to be the only place four of these sentences were written as literals.
#Preview("Nothing to look up") {
    PanelView(content: .frontmostAppUnknown)
        .frame(width: 420, height: 150)
}

#Preview("Accessibility is off") {
    PanelView(content: .accessibilityIsOff)
        .frame(width: 420, height: 180)
}
#endif
