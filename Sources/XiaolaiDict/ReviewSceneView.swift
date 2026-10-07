import StudyModels
import SwiftUI
import XiaolaiDictUI

/// The Review window's content.
///
/// **A view, not scene-body code.** Reading observable state in an `App`'s `body` invalidates every
/// scene in it — measured in this project as a sibling window whose menu item opened nothing — so the
/// model is read here, one level down.
///
/// **Undo is not here.** It is the window's — a toolbar item on Command-Z, put there by
/// `LibraryReviewPane` — where it was a button at zero opacity behind this view, hidden from
/// VoiceOver, that only a reader who guessed the key could reach.
struct ReviewSceneView: View {
    let model: ReviewModel
    var findUnconfirmed: (@MainActor () -> Void)?
    var findUnanswered: (@MainActor () -> Void)?

    var body: some View {
        ReviewView(state: model.presentation, findUnconfirmed: findUnconfirmed,
                   findUnanswered: findUnanswered) { model.act($0, on: $1) }
            .task { await model.resume() }
    }
}
