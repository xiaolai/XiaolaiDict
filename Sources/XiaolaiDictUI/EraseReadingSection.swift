import Foundation
import SwiftUI

/// **Erasing the reader's reading history, previewed before it happens.**
///
/// This is the one destructive command in the app that cannot be undone, so it says three things
/// before it is available: how much history goes, how many saved cards it leaves without a sentence,
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
                Button("Delete all reading history…") { act(.preview) }
            case .previewing(let impact):
                preview(impact)
            case .erased(let report):
                erased(report)
            case .failed(let reason):
                // **A command that could not run says so.** Staying on the first button would
                // read as a click that did nothing, and the reader would press it again.
                Text("That could not be done: \(reason)")
                    .foregroundStyle(.orange)
                Button("Done") { act(.cancel) }
            }
        } header: {
            Text("Reading history")
        } footer: {
            Text("""
                Deleting your reading history keeps the meanings you saved. They will need a new \
                sentence before they can be reviewed again.
                """)
            .font(.system(size: scale.text.small))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func preview(_ impact: ErasePresentation.Impact) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text("\(impact.lookups) lookups will be deleted.")
            if impact.cardsLeftWithoutASentence > 0 {
                Text("\(impact.cardsLeftWithoutASentence) saved meanings will lose their sentence.")
                    .foregroundStyle(.orange)
            }
            if impact.backups > 0 {
                Text("\(impact.backups) backup copies made by XiaolaiDict will be deleted too.")
                    .font(.system(size: scale.text.small))
                    .foregroundStyle(.secondary)
            }
            // **Said plainly, not in a footnote.** No claim is made about copies outside the app.
            Text("""
                Copies you made yourself — Time Machine, an exported file, anything you duplicated — \
                are not affected and cannot be reached from here.
                """)
            .font(.system(size: scale.text.small))
            .foregroundStyle(.secondary)
            HStack(spacing: scale.space.inline) {
                Button("Delete \(impact.lookups) lookups", role: .destructive) { act(.erase) }
                Button("Cancel") { act(.cancel) }
            }
        }
    }

    @ViewBuilder
    private func erased(_ report: ErasePresentation.Report) -> some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text("\(report.lookupsRemoved) lookups deleted.")
            // A failure to remove a copy is **reported**, never swallowed: a reader told their
            // history is gone while a copy of it sits on disk has been told something false.
            if !report.backupsLeft.isEmpty {
                Text("\(report.backupsLeft.count) backup copies could not be deleted.")
                    .foregroundStyle(.orange)
                ForEach(report.backupsLeft, id: \.self) { reason in
                    Text(verbatim: reason)
                        .font(.system(size: scale.text.micro))
                        .foregroundStyle(.secondary)
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
