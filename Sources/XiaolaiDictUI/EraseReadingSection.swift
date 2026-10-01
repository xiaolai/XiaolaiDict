import Foundation
import SwiftUI

/// **Erasing the reader's reading history, previewed before it happens.**
///
/// This is the one destructive command in the app that cannot be undone, so it says three things
/// before it is available: how much history goes, how many saved meanings it leaves without a sentence,
/// and what it cannot reach. The last is the one most easily left out and the one that matters most —
/// a copy the reader made themselves is not ours to delete, and implying otherwise is worse than
/// saying nothing.
///
/// **It does not touch their cards.** Removing from study is a different command in a different
/// window, and conflating them is how months of study disappears on a menu item about history.
public struct EraseReadingSection: View {
    @Environment(\.scale) private var scale
    public let state: ErasePresentation
    public let act: @MainActor (EraseAction) -> Void

    public init(state: ErasePresentation, act: @escaping @MainActor (EraseAction) -> Void) {
        self.state = state
        self.act = act
    }

    public var body: some View {
        Section {
            switch state.stage {
            case .idle:
                Button("Delete All Reading History…") { act(.preview) }
            case .previewing(let impact):
                preview(impact)
            case .erased(let report):
                erased(report)
            case .failed(let reason):
                // **A command that could not run says so.** Staying on the first button would
                // read as a click that did nothing, and the reader would press it again.
                StatusLabel(.error, text: Text("That could not be done: \(reason)"), size: Token.Text.form)
                Button("Done") { act(.cancel) }
            }
        } header: {
            Text("Reading History")
        } footer: {
            Text("""
                Deleting your reading history keeps the meanings you saved. They will need a new \
                sentence before they can be reviewed again.
                """)
        }
    }

    /// What is about to go, and the two buttons.
    ///
    /// **Inline rather than an alert, in the platform's button order.** The preview has three
    /// counts and a caveat to carry, which is more than an alert's message holds. It keeps an
    /// alert's manners: Cancel first and answering Escape, the destructive button last and never
    /// the default, and named for exactly what it will delete.
    @ViewBuilder
    private func preview(_ impact: ErasePresentation.Impact) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            if impact.lookups == 0 {
                Text("There is no reading history to delete.")
            } else {
                Text("^[\(impact.lookups) reading](inflect: true) will be deleted.")
            }
            if impact.cardsLeftWithoutASentence > 0 {
                // The sentence that matters most in this flow, so it is the one with a mark —
                // in the label colour. It was orange body text on the form's grey, the hardest
                // line here to read.
                StatusLabel(
                    .caution,
                    "^[\(impact.cardsLeftWithoutASentence) saved meaning](inflect: true) will be left without a sentence.",
                    size: Token.Text.form)
            }
            if impact.backups > 0 {
                Text("^[\(impact.backups) backup copy](inflect: true) made by XiaolaiDict will be deleted too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // **Said plainly, not in a footnote.** No claim is made about copies outside the app.
            Text("""
                Copies you made yourself — Time Machine, an exported file, anything you duplicated — \
                are not affected and cannot be reached from here.
                """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: scale.space.inline) {
                Button("Cancel", role: .cancel) { act(.cancel) }
                    .keyboardShortcut(.cancelAction)
                // **Disabled at zero, and the line above says why.** It offered "Delete 0
                // lookups": an irreversible command with nothing to do, still live.
                Button("Delete ^[\(impact.lookups) Reading](inflect: true)", role: .destructive) { act(.erase) }
                    .disabled(impact.lookups == 0)
            }
        }
    }

    @ViewBuilder
    private func erased(_ report: ErasePresentation.Report) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text("^[\(report.lookupsRemoved) reading](inflect: true) deleted.")
            // A failure to remove a copy is **reported**, never swallowed: a reader told their
            // history is gone while a copy of it sits on disk has been told something false.
            if !report.backupsLeft.isEmpty {
                StatusLabel(
                    .error,
                    "^[\(report.backupsLeft.count) backup copy](inflect: true) could not be deleted.",
                    size: Token.Text.form)
                ForEach(report.backupsLeft, id: \.self) { reason in
                    Text(verbatim: reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Button("Done") { act(.cancel) }
        }
    }
}

public enum EraseAction: Sendable, Equatable {
    case preview
    case erase
    case cancel
}

public struct ErasePresentation: Sendable, Equatable {
    public let stage: Stage

    public init(stage: Stage = .idle) { self.stage = stage }

    public enum Stage: Sendable, Equatable {
        case idle
        case previewing(Impact)
        case erased(Report)
        /// The command could not run at all — an unreadable store, a locked file. Distinct from an
        /// erase that ran and left a copy behind, which is `erased` with `backupsLeft`.
        case failed(String)
    }

    public struct Impact: Sendable, Equatable {
        public let lookups: Int
        public let cardsLeftWithoutASentence: Int
        public let backups: Int

        public init(lookups: Int, cardsLeftWithoutASentence: Int, backups: Int) {
            self.lookups = lookups
            self.cardsLeftWithoutASentence = cardsLeftWithoutASentence
            self.backups = backups
        }
    }

    public struct Report: Sendable, Equatable {
        public let lookupsRemoved: Int
        /// One line per copy that could not be removed, with its reason.
        public let backupsLeft: [String]

        public init(lookupsRemoved: Int, backupsLeft: [String]) {
            self.lookupsRemoved = lookupsRemoved
            self.backupsLeft = backupsLeft
        }
    }
}
