import SwiftUI

/// The Review pane of the Library: a sitting, on the skeleton the other panes are built on.
///
/// **What Review is about goes where the other panes say theirs.** How much is due and from which
/// dictionary is the window's subtitle, as a count is on History and Saved; a failure or a note
/// about cards held back is a notice; the way to the meanings that still need confirming is a
/// footer button. It was a stack — those lines centred above the card and the button below it —
/// which held the sitting's scroll view off the toolbar and gave this pane a header no other has.
public struct LibraryReviewPane<Sitting: View>: View {
    @Environment(\.scale) private var scale
    let due: Int
    let dictionary: String?
    let problem: String?
    let heldBack: Int
    let findUnconfirmed: @MainActor () -> Void
    let sitting: Sitting

    public init(due: Int, dictionary: String?, problem: String?, heldBack: Int,
                findUnconfirmed: @escaping @MainActor () -> Void, @ViewBuilder sitting: () -> Sitting) {
        self.due = due; self.dictionary = dictionary; self.problem = problem; self.heldBack = heldBack
        self.findUnconfirmed = findUnconfirmed; self.sitting = sitting()
    }

    public var body: some View {
        sitting
            .modifier(LibraryPaneChrome(notice: { notice }, footer: {
                LibraryFooter {
                    IconButton(title: "Find meanings needing confirmation", symbol: "exclamationmark.triangle", action: findUnconfirmed)
                }
            }))
            .navigationSubtitle(subtitle)
    }

    private var subtitle: Text {
        let today = Text("Review today · \(due)")
        guard let dictionary else { return today }
        return Text("\(today) · \(Text(verbatim: dictionary))")
    }

    @ViewBuilder private var notice: some View {
        if problem != nil || heldBack > 0 {
            LibraryNotice {
                if let problem { Text(verbatim: problem).foregroundStyle(.orange).textSelection(.enabled) }
                if heldBack > 0 { Text("\(heldBack) new meanings are held until tomorrow.") }
            }
        }
    }
}
