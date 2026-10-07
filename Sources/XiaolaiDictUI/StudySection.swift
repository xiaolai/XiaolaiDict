import StudyKit
import StudyPresentation
import SwiftUI

/// **Settings › General › Study**: what is saved for study, and what choosing a meaning does to a
/// word saved without one. One section, because both answer "what ends up in Saved".
struct StudySection: View {
    let keepPolicy: Binding<LookupKeepPolicy>?
    let choice: StudyChoice?

    var body: some View {
        Section {
            if let keepPolicy {
                Picker("Save meanings for study", selection: keepPolicy) {
                    Text("Automatically").tag(LookupKeepPolicy.automatic)
                    Text("Only when I choose Save").tag(LookupKeepPolicy.manual)
                }
            }
            if let choice {
                Toggle("When I choose a meaning for a word I saved, replace the word-only card with it",
                       isOn: Binding(get: { choice.replacesWordCards }, set: { choice.setReplacesWordCards($0) }))
            }
        } header: {
            Text("Study")
        } footer: {
            VStack(alignment: .leading) {
                if keepPolicy != nil {
                    Text("""
                         Every reading is kept in Reading History either way. Meanings saved \
                         automatically come from your study dictionary, and a meaning that was a \
                         guess needs your confirmation before it can be reviewed.
                         """)
                }
                if choice != nil {
                    Text("""
                         Replacing gives the meaning your own answer and tags, and moves the word-only \
                         card to Archived in Saved, where it can be restored. A word-only card you have \
                         already reviewed is kept beside the meaning.
                         """)
                }
            }
        }
    }
}

/// **Settings › General › Review**: the wait after a confirmation. In General beside Study and the
/// reminder because the app has no study pane — a "Learning" tab was rejected on 2026-10-02 — and
/// this decides when a saved meaning first reaches Review, which is what those two sections are about.
struct ReviewWaitSection: View {
    let choice: StudyChoice

    var body: some View {
        Section {
            Toggle("Wait before first asking a meaning I confirm", isOn: Binding(
                get: { choice.waitsAfterConfirming }, set: { choice.setWaitsAfterConfirming($0) }))
            Picker("Wait at least", selection: Binding(
                get: { choice.minimumWait }, set: { choice.setMinimumWait($0) })) {
                ForEach(choice.minimumWaitChoices, id: \.self) { wait in
                    // A duration, which Foundation words in the reader's language — not prose.
                    Text(Duration.seconds(wait), format: .units(allowed: [.hours, .minutes], width: .wide))
                        .tag(wait)
                }
            }
            .disabled(choice.minimumWaitReason != nil)
            if choice.minimumWaitReason == .waitIsOff {
                Text("Turn on the wait to choose how long.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Review")
        } footer: {
            Text("""
                 A meaning you confirm in History, with its answer showing, is first asked on the next \
                 study day and no sooner than the time chosen, so that your first answer is recalled \
                 rather than just read. Optional and untested: it applies to half of those meanings, \
                 chosen at random, so the two halves can be compared.
                 """)
        }
    }
}
