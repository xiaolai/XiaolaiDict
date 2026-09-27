import Foundation
import Testing
@testable import AppleDictionaryFormat

/// The key format, against **invented** bytes. Real key text is licensed and is never vendored here, so
/// every fixture below is assembled by `chunk(_:)` from words chosen for the trap they expose.
struct KeyIndexReaderTests {
    /// Builds one key-text chunk the way the file does, so the reader is tested against the layout and
    /// not against a second copy of its own parsing.
    static func chunk(_ groups: [(offset: Int, chunkID: Int, keys: [String])]) -> Data {
        var out = Data()
        for g in groups {
            var keyBlock = Data()
            for key in g.keys {
                let utf16 = Array(key.utf16)
                var bytes = Data()
                for unit in utf16 {
                    bytes.append(UInt8(unit & 0xff)); bytes.append(UInt8(unit >> 8))
                }
                keyBlock.append(UInt8(bytes.count & 0xff)); keyBlock.append(UInt8(bytes.count >> 8))
                keyBlock.append(bytes)
            }
            keyBlock.append(contentsOf: [0, 0])   // the zero length that ends the block

            var body = Data()
            func u32(_ v: Int) { for i in 0..<4 { body.append(UInt8((v >> (8 * i)) & 0xff)) } }
            func u16(_ v: Int) { body.append(UInt8(v & 0xff)); body.append(UInt8((v >> 8) & 0xff)) }
            u32(1)                       // the field that is 1 in every group seen
            u16(0)                       // the redundant size field; the reader must not depend on it
            u32(g.offset)
            u16(g.chunkID)
            u32(keyBlock.count)
            body.append(keyBlock)

            var size = Data()
            for i in 0..<4 { size.append(UInt8((body.count >> (8 * i)) & 0xff)) }
            out.append(size); out.append(body)
        }
        return out
    }

    @Test func aGroupCarriesItsKeysAndItsPointer() {
        let data = Self.chunk([(offset: 172_749, chunkID: 22_015, keys: ["widget", "Widget"])])
        let groups = KeyIndexReader.groups(inChunk: data)
        #expect(groups.count == 1)
        #expect(groups.first?.keys == ["widget", "Widget"])
        #expect(groups.first?.pointer == EntryPointer(chunkID: 22_015, offset: 172_749))
        #expect(groups.first?.searchKey == "widget")
        #expect(groups.first?.displayKey == "Widget")
    }

    /// **The trap that truncated every key.** The two bytes after a length field look like a tag, and are
    /// not — for a key beginning `č` they are `0d 01`, which is U+010D itself. Reading them as a tag drops
    /// the first character and yields a word that still looks like a word, which is what made the bug
    /// survive a first look. The dictionary this was found in reads `čapek`; the fixture is invented,
    /// because no licensed text belongs in this repository.
    @Test func aLeadingNonAsciiCharacterIsNotMistakenForATag() {
        let keys = ["čwimble", "Čwimble", "Čwimble, Karla"]
        let data = Self.chunk([(offset: 8, chunkID: 1, keys: keys)])
        let parsed = KeyIndexReader.groups(inChunk: data).first?.keys
        #expect(parsed == keys)
        #expect(parsed?.first?.first == "č", "the leading č was read as a length tag")
    }

    @Test func severalGroupsChainByTheirDeclaredSize() {
        let data = Self.chunk([
            (offset: 10, chunkID: 5, keys: ["one"]),
            (offset: 20, chunkID: 5, keys: ["two", "Two"]),
            (offset: 30, chunkID: 6, keys: ["three"]),
        ])
        let groups = KeyIndexReader.groups(inChunk: data)
        #expect(groups.count == 3)
        #expect(groups.map(\.pointer.offset) == [10, 20, 30])
        #expect(groups.map(\.pointer.chunkID) == [5, 5, 6])
    }

    @Test func aPhraseIsRecognisedAsOne() {
        let data = Self.chunk([
            (offset: 1, chunkID: 1, keys: ["mass wibbled", "mass-wibbled"]),
            (offset: 2, chunkID: 1, keys: ["widget"]),
        ])
        let groups = KeyIndexReader.groups(inChunk: data)
        #expect(groups[0].isPhrase)
        #expect(!groups[1].isPhrase)
    }

    /// Trailing zeros pad the last chunk of a stride-walked stream. They must end the walk, not be read
    /// as a group of size 0 forever.
    @Test func trailingPaddingEndsTheWalkRatherThanLooping() {
        var data = Self.chunk([(offset: 1, chunkID: 1, keys: ["widget"])])
        data.append(Data(count: 64))
        #expect(KeyIndexReader.groups(inChunk: data).count == 1)
    }

    @Test func aTruncatedGroupIsDroppedRatherThanCrashing() {
        let full = Self.chunk([(offset: 1, chunkID: 1, keys: ["widget"])])
        for cut in 1..<full.count {
            // Any prefix must parse to something or nothing, and must never trap.
            _ = KeyIndexReader.groups(inChunk: full.prefix(cut))
        }
    }
}
