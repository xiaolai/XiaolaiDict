import AppKit
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
