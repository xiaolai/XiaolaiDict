import Foundation
import Testing
import XiaolaiDictCore
@testable import XiaolaiDictUI

/// What the reader is told when no sense was marked.
///
/// The wording lives in the view layer, so this test does too: a sentence is only translatable
/// where the string catalog can extract it.
struct AbstentionTextTests {
    /// The popup must be able to say why it marked nothing, and a blank is where an explanation
    /// belongs.
    @Test(arguments: Abstention.allCases)
    func everyAbstentionHasSomethingToSay(abstention: Abstention) {
        #expect(!abstention.reason.isEmpty)
    }

    /// And says something different each time: five cases sharing one sentence would tell the
    /// reader nothing about which one happened.
    @Test func noTwoAbstentionsReadTheSame() {
        let said = Abstention.allCases.map(\.reason)
        #expect(Set(said).count == said.count)
    }
}
