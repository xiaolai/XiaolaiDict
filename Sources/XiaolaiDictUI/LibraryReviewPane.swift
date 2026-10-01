import SwiftUI

/// The Review pane of the Library: a sitting, on the skeleton the other panes are built on.
///
/// **What Review is about goes where the other panes say theirs.** How much is due and from which
/// dictionary is the window's subtitle, as a count is on History and Saved; a failure or a note
/// about new meanings waiting for tomorrow is a notice; Undo and the way to the meanings that still
/// need confirming are toolbar items. It was a stack — those lines centred above the card and the
/// button below it — which held the sitting's scroll view off the toolbar and gave this pane a
/// header no other has.
///
/// **The way to the unconfirmed meanings is there only when there are some.** It was a warning
/// triangle in a pill at the bottom-right corner on every visit, reading as an alert about a pane
/// with nothing wrong in it.
public struct LibraryReviewPane<Sitting: View>: View {
    @Environment(\.scale) private var scale
    let due: Int
    let dictionary: String?
    let problem: String?
    let heldBack: Int
    let unconfirmed: Int
    let canUndo: Bool
    let undo: @MainActor () -> Void
    let findUnconfirmed: @MainActor () -> Void
    let sitting: Sitting

    public init(due: Int, dictionary: String?, problem: String?, heldBack: Int, unconfirmed: Int,
                canUndo: Bool, undo: @escaping @MainActor () -> Void,
                findUnconfirmed: @escaping @MainActor () -> Void, @ViewBuilder sitting: () -> Sitting) {
        self.due = due; self.dictionary = dictionary; self.problem = problem; self.heldBack = heldBack
        self.unconfirmed = unconfirmed; self.canUndo = canUndo; self.undo = undo
        self.findUnconfirmed = findUnconfirmed; self.sitting = sitting()
    }

    public var body: some View {
        sitting
            .modifier(LibraryPaneChrome(showsNotice: problem != nil || heldBack > 0) { notice })
            .navigationSubtitle(subtitle)
            .toolbar {
                // **Undo is the window's**, not a button on the card: it is about the review just
                // committed, which is no longer on screen.
                LibraryUndoToolbar(title: canUndo ? "Undo the Last Review" : nil, undo: undo)
                if unconfirmed > 0 {
                    ToolbarItem {
                        IconButton(.findUnconfirmed, title: "Find ^[\(unconfirmed) Meaning](inflect: true) to Confirm",
                                   hint: "shows them in Saved", size: Token.Library.toolbarGlyph, action: findUnconfirmed)
                            .accessibilityIdentifier("library-find-unconfirmed")
                    }
                }
            }
    }

    private var subtitle: Text {
        let today = Text("Review today · \(due)")
        guard let dictionary else { return today }
        return Text("\(today) · \(Text(verbatim: dictionary))")
    }

    @ViewBuilder private var notice: some View {
        if problem != nil || heldBack > 0 {
            LibraryNotice {
                if let problem {
                    StatusLabel(.error, text: Text(verbatim: problem), prominence: .secondary).textSelection(.enabled)
                }
                if heldBack > 0 { Text("^[\(heldBack) new meaning](inflect: true) will be introduced tomorrow.") }
            }
        }
    }
}
