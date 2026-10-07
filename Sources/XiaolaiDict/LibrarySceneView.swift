import StudyModels
import StudyPresentation
import SwiftUI
import XiaolaiDictUI

/// The Library window's content. A view, not scene-body code — see `ReviewSceneView`.
struct LibrarySceneView: View {
    let model: LibraryModel
    let review: ReviewModel
    var body: some View {
        LearningLibraryView(pane: model.pane, saved: model.presentation, archive: model.archive,
            layout: model.layout, chooseLayout: { model.setLayout($0) },
            inspectorShown: model.inspectorShown, showInspector: { model.setInspector($0) },
            choose: { model.show($0) }, savedAction: { model.act($0) }, archiveAction: { model.actArchive($0) }) {
            LibraryReviewPane(due: model.reviewCount, dictionary: model.reviewDictionary,
                              problem: model.reviewProblem, heldBack: model.reviewHeldBack,
                              unconfirmed: model.reviewUnconfirmed,
                              sittingOffersFind: review.presentation.offersFindUnconfirmed,
                              canUndo: review.canUndo, undo: { review.act(.undo) },
                              findUnconfirmed: { model.findUnconfirmed() }) {
                ReviewSceneView(model: review, findUnconfirmed: { model.findUnconfirmed() },
                                findUnanswered: { model.findUnanswered() })
            }
        }
        .task { await model.refreshPane(); await model.importLegacy() }
        .onChange(of: LedgerChanges.shared.revision) { _, _ in Task { await model.refreshPane() } }
    }
}
