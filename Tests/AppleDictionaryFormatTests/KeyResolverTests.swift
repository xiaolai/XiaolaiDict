import Foundation
import Testing
@testable import AppleDictionaryFormat

/// The resolver's derivation, on an invented layout where the right answer is known by construction.
struct KeyResolverTests {
    static func layout(_ map: [Int: [Int]]) -> BodyLayout {
        BodyLayout(chunksByOffset: map, chunkCount: 4, recordCount: map.values.reduce(0) { $0 + $1.count })
    }

    /// Neither group's offset is unique, but together they pin the chunk: offset 100 is in chunks 1 and 2,
    /// offset 200 in chunks 2 and 3, so an id carrying both can only mean chunk 2.
    @Test func intersectionPinsAChunkNeitherGroupCouldPinAlone() {
        let layout = Self.layout([100: [1, 2], 200: [2, 3]])
        let groups = [
            KeyGroup(keys: ["a"], pointer: EntryPointer(chunkID: 7, offset: 100)),
            KeyGroup(keys: ["b"], pointer: EntryPointer(chunkID: 7, offset: 200)),
        ]
        let resolver = KeyResolver(groups: groups, layout: layout)
        #expect(resolver.table[7] == 2)
        #expect(resolver.ambiguousIDs == 0)
    }

    /// **A group that cannot be satisfied must not erase the chunk id.** Intersecting blindly cost 4,829
    /// groups across 7 ids on NOAD, because one unmatched offset emptied the set for everything sharing it.
    @Test func anUnsatisfiableGroupDoesNotEraseItsChunkID() {
        let layout = Self.layout([100: [1, 2], 200: [2, 3]])
        let groups = [
            KeyGroup(keys: ["a"], pointer: EntryPointer(chunkID: 7, offset: 100)),
            KeyGroup(keys: ["b"], pointer: EntryPointer(chunkID: 7, offset: 200)),
            KeyGroup(keys: ["c"], pointer: EntryPointer(chunkID: 7, offset: 999)),   // matches nothing
        ]
        let resolver = KeyResolver(groups: groups, layout: layout)
        #expect(resolver.table[7] == 2, "an unmatched group emptied the intersection")
    }

    @Test func anIDThatNeverNarrowsIsReportedRatherThanGuessed() {
        let layout = Self.layout([100: [1, 2]])
        let groups = [KeyGroup(keys: ["a"], pointer: EntryPointer(chunkID: 9, offset: 100))]
        let resolver = KeyResolver(groups: groups, layout: layout)
        #expect(resolver.table[9] == nil)
        #expect(resolver.ambiguousIDs == 1)
    }

    /// A pointer into open space is nil, not the record before it. Returning a neighbour would make a
    /// wrong key→entry pair indistinguishable from a right one.
    @Test func aPointerThatIsNotARecordStartResolvesToNothing() {
        var chunk = Data()
        let text = Array("<d:entry id=\"x\"/>".utf8)
        for i in 0..<4 { chunk.append(UInt8((text.count >> (8 * i)) & 0xff)) }
        chunk.append(contentsOf: text)
        #expect(BodyLayout.record(in: chunk, at: 0) == "<d:entry id=\"x\"/>")
        #expect(BodyLayout.record(in: chunk, at: 2) == nil)
        #expect(BodyLayout.record(in: chunk, at: chunk.count) == nil)
        #expect(BodyLayout.recordOffsets(in: chunk) == [0])
    }
}
