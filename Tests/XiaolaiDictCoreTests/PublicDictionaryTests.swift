import XiaolaiDictCore
import Testing

/// The public DCSCopyTextDefinition: plain text only, but safe in-process. It is what the panel
/// falls back to when the XPC service has crashed (design note §10).
struct PublicDictionaryTests {
    @Test func aCommonWordHasAPlainDefinition() throws {
        let definition = try #require(PublicDictionary.definition(of: "ephemeral"))
        #expect(definition.count > 20)
    }

    @Test func gibberishHasNone() {
        #expect(PublicDictionary.definition(of: "qzxqzxqzxqzx") == nil)
    }

    @Test(arguments: ["", "  "])
    func aBlankTermHasNone(term: String) {
        #expect(PublicDictionary.definition(of: term) == nil)
    }
}
