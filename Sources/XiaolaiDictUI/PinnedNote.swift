import AppKit
import DictionaryModel
import XiaolaiDictCore
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
                    localized: "A guess — not confirmed",
                    comment: "On a pinned note whose sense the selector proposed")
            case .ambiguous:
                return String(
                    localized: "Several senses fitted — this is the nearest",
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

    public init(note: PinnedNote) {
        self.note = note
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scale.space.stack) {
                HStack(alignment: .firstTextBaseline, spacing: scale.space.stack) {
                    Text(note.heading).font(.title3.weight(.semibold))
                    if let partOfSpeech = note.partOfSpeech {
                        Text(partOfSpeech).font(.caption).italic().foregroundStyle(.secondary)
                    }
                    if let pronunciation = note.pronunciation {
                        Text(pronunciation).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(note.text).font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // **Where the panel's badge goes when the panel is gone.** Only the uncertain
                // standings say anything; a note announcing its own certainty would be noise.
                if let caveat = note.standing.caveat {
                    Text(verbatim: caveat)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: scale.space.line)
                // What it is a copy of, and from when. A note that outlives its dictionary can
                // still say where it came from.
                Text(note.provenance).font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, scale.space.padAcross)
            .padding(.top, Token.Panel.titleBarClearance)
            .padding(.bottom, scale.space.padDown)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
