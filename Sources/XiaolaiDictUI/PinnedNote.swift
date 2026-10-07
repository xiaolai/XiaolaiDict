import AppKit
import DictionaryModel
import SwiftUI

/// A sense the reader kept: a sticky note that survives the next lookup and is dismissed on its own
/// terms (`feature-ledger-ux.md` B5).
///
/// **A copy, not a live reference** (decision D3). The dictionary's id and content version are
/// recorded with it, so a dictionary update — or the reader disabling that dictionary — cannot
/// silently rewrite a note they chose to keep. What the note says is what it said when it was
/// pinned, and it can say which version of which dictionary it came from.
public struct PinnedNote: Equatable, Identifiable {
    public let id = UUID()
    public let heading: String
    public let dictionary: DictionaryIdentity
    public let partOfSpeech: String?
    public let pronunciation: String?
    /// The sense's own words, copied at the moment of pinning.
    public let text: String
    /// **How sure the panel was, kept with the words.** A note outlives the panel that made it,
    /// and the panel's ambiguity badge does not travel — so a sense the selector was unsure of
    /// became a note indistinguishable from one the reader confirmed. `chosen_by` never merges,
    /// and this is the same distinction at the surface that lasts longest.
    public let standing: Standing

    public enum Standing: String, Equatable, Sendable {
        /// The reader tapped it, or it was the entry's only sense.
        case confirmed
        /// The selector proposed it and nobody has confirmed it.
        case proposed
        /// Several senses fitted and this is the one it nearly picked.
        case ambiguous

        /// What the note says about itself. Empty for a confirmed sense: a note that announces its
        /// own certainty is noise, and only the uncertain ones need saying.
        /// Explicit `return`s, not a switch expression. `swiftc -emit-localized-strings`
        /// extracted nothing from the expression form here — the catalog stayed at 239 across two
        /// runs while the identical construct in `LookupCardView` extracted fine — and
        /// `everyLiteralTheReaderSeesIsInTheCatalog` is what caught it. A sentence a translator
        /// never sees is the defect that rule exists for.
        public var caveat: String? {
            switch self {
            case .confirmed:
                return nil
            case .proposed:
                return String(
                    localized: "A guess, not confirmed",
                    comment: "On a pinned note whose sense the selector proposed")
            case .ambiguous:
                return String(
                    localized: "Several meanings fit. This is the nearest",
                    comment: "On a pinned note whose sense was one of several that fitted")
            }
        }
    }

    /// Where it came from, precisely enough to be checked later.
    public var provenance: String {
        let version = dictionary.version.map { " \($0)" } ?? ""
        return "\(dictionary.name)\(version)"
    }

    public static func == (a: PinnedNote, b: PinnedNote) -> Bool { a.id == b.id }

    /// **Whether two notes hold the same sense — the question `==` deliberately does not answer.**
    ///
    /// `id` is a fresh `UUID` per value and stays that way: one window per value, so closing a note
    /// can never close another. But nothing asked whether a sense was *already* kept, so a reader
    /// pressing pin twice got two identical stickies, and holding it got a dozen (reported
    /// 2026-09-27). A note is a copy and not a live reference (D3), so it **is** its content: the
    /// same words under the same headword from the same dictionary are the same note.
    ///
    /// `standing` is deliberately excluded. A guess the reader kept and later confirmed is the same
    /// words in the same place; a second sticky announcing so would be this button failing again in
    /// a way that looks like it worked.
    ///
    /// The set on screen is `PinnedNoteController`'s, and it is what enforces one of each — a value
    /// cannot know what else is open.
    public func holdsTheSameSense(as other: PinnedNote) -> Bool {
        heading == other.heading && text == other.text && dictionary == other.dictionary
    }
}

/// The pinned notes on screen. Each is its own always-on-top window, closed by its own button — a
/// new lookup never touches them, which is the whole point of pinning one.
///
/// A `WindowGroup(for:)` scene rather than an `NSPanel` per note: SwiftUI opens one window per
/// value, which is exactly the shape of "several notes, each independent". The note itself is held
/// here and looked up by id, because a scene is handed a value and not an object.

public struct PinnedNoteView: View {
    @Environment(\.scale) private var scale
    public let note: PinnedNote
    /// **How the reader puts it away, with no default.** The note's window carries no traffic lights
    /// (`PinnedNoteWindow`), so this is the only way to close one — and a defaulted closure nobody
    /// supplies is exactly how `HoverPause` and `LookupRunner`'s prior encounters shipped complete,
    /// unit-tested and unreachable. Required, so the compiler is what asserts the wire.
    let unpin: () -> Void
    /// Revealed under the pointer rather than always drawn, so a note is its words and not a widget.
    @State private var pointerIsOver = false
    /// And revealed when the keyboard reaches it: a control that has focus and cannot be seen is
    /// worse than one that is always drawn.
    @FocusState private var unpinIsFocused: Bool

    public init(note: PinnedNote, unpin: @escaping () -> Void) {
        self.note = note
        self.unpin = unpin
    }

    public var body: some View {
        ScrollView {
            // **At the reader's text size, like the card it was pinned from.** These were the
            // system's semantic fonts, which take no notice of the setting: at Large the card's
            // meaning was 17 pt and the note made from it 13.
            VStack(alignment: .leading, spacing: scale.space.stack) {
                // The unpin button's own width, kept clear whether or not it is showing: a heading
                // that reflowed when the pointer arrived would be worse than the button appearing.
                HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                    Text(note.heading)
                        .font(.system(size: scale.text.display, weight: .semibold))
                    if let partOfSpeech = PartOfSpeechLabel.reader(note.partOfSpeech) {
                        Text(partOfSpeech)
                            .font(.system(size: scale.text.body).italic())
                            .foregroundStyle(.secondary)
                    }
                    if let pronunciation = note.pronunciation {
                        Text(pronunciation)
                            .font(.system(size: scale.text.body))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, Token.Target.minimum)
                Text(note.text)
                    .font(.system(size: scale.text.strong))
                    .lineSpacing(scale.text.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // **Where the panel's badge goes when the panel is gone.** Only the uncertain
                // standings say anything; a note announcing its own certainty would be noise. A
                // mark and ordinary text, as on the card — it was orange text.
                if let caveat = note.standing.caveat {
                    StatusLabel(.unconfirmed, text: Text(verbatim: caveat))
                }
                Spacer(minLength: scale.space.line)
                // What it is a copy of, and from when. A note that outlives its dictionary can
                // still say where it came from. Secondary: it is there to be read.
                Text(note.provenance)
                    .font(.system(size: scale.text.micro))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, scale.space.padAcross)
            // Symmetric with the bottom, because nothing floats over the top any more. This was a
            // 28 pt structural offset dodging the traffic lights; they are gone, and so is it — the
            // note was that offset's last reader in the whole project.
            .padding(.top, scale.space.padDown)
            .padding(.bottom, scale.space.padDown)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // On the scroll view, so it stays in the corner rather than scrolling away with the words.
        .overlay(alignment: .topTrailing) { unpinControl }
        // The same act from the pointer's other button, for a reader who looks there first.
        .contextMenu {
            Button(action: unpin) { ActionSymbol.unpinNote.label }
        }
        // **Escape puts a focused note away**, as it does a panel. A second, undrawn button
        // because a control has one key: Command-W is on the one the reader can see.
        .background {
            Button(action: unpin) { Text(ActionSymbol.unpinNote.title) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onHover { pointerIsOver = $0 }
    }

    /// **Always in the view tree, and so always in the accessibility tree.**
    ///
    /// It was `if pointerIsOver { IconButton(…) }`: with no pointer over the note there was no
    /// button at all, and the note's window has no traffic lights — so a VoiceOver or keyboard
    /// reader could make an always-on-top window and had no way to remove it (2026-10-01). The
    /// reader asked for the control to stay out of sight until wanted, and it still does: that is
    /// the opacity. Its existence no longer depends on a pointer.
    ///
    /// Command-W is bound here, and named in the tooltip, because this window has no menu to
    /// offer Close from.
    private var unpinControl: some View {
        IconButton(.unpinNote, shortcut: KeyboardShortcut("w", modifiers: .command), action: unpin)
            .focused($unpinIsFocused)
            .foregroundStyle(.secondary)
            .padding(.top, scale.space.padDown)
            .padding(.trailing, scale.space.padAcross)
            .opacity(pointerIsOver || unpinIsFocused ? 1 : 0)
            .motionAwareAnimation(.easeInOut(duration: Token.Motion.hover), value: pointerIsOver)
            .motionAwareAnimation(.easeInOut(duration: Token.Motion.hover), value: unpinIsFocused)
    }
}
