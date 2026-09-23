import Foundation

/// Who published the local model's weights, and under what terms — **one place**, because About is
/// where a reader goes for the legal answer and three strings written out beside each other are
/// three chances for a future model to be downloaded while the old one's attribution is still on
/// screen.
///
/// Here rather than in `XiaolaiDictCore` beside the pins: the publisher is a sentence the reader
/// sees, and the core has no view layer to extract it from. `LocalModelAttributionTests` ties this
/// to the catalogue instead, by asserting the family against the repositories actually pinned.
public enum LocalModelAttribution {
    /// The model family the pins come from.
    public static let family = "Qwen3.5"

    /// Named as the publisher names itself.
    public static var publisher: String {
        String(localized: "The Qwen team, Alibaba Cloud",
               comment: "About pane: who published the local model's weights")
    }

    public static let licenceName = "Apache License 2.0"
    public static let licenceURL = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")
}
