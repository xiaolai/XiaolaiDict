import Foundation

/// Where an entry sits, as `KeyText.data` names it.
///
/// **`chunkID` is Apple's own identifier, not a sequential index.** It is a 16-bit number and there are
/// 785 distinct values across NOAD's 799 body chunks, but the mapping is scrambled: chunk 21 is id
/// 35546, chunk 50 is id 8594, chunk 104 is id 22015. No arithmetic relates them, so the reader does not
/// try to derive one — `KeyResolver` recovers the table from the data instead, and exactly.
///
/// `offset` is the byte position of the entry's length-prefixed record **inside the decompressed chunk**,
/// which is the one field that could be confirmed directly: for the key `čapek`, `offset` is 172749 and
/// the record at 172749 of body chunk 104 is the entry `m_en_gbus0149730`, "Čapek, Karel".
public struct EntryPointer: Sendable, Hashable {
    public let chunkID: Int
    public let offset: Int

    public init(chunkID: Int, offset: Int) {
        self.chunkID = chunkID
        self.offset = offset
    }
}

/// One entry's search keys, as the publisher wrote them into the index.
///
/// A group holds a **case-folded search form followed by display forms**: `["čapek", "Čapek",
/// "Čapek, Karel"]`. Several groups may point at one entry — `čapek` and `čapek, karel` are separate
/// groups with the same pointer — so a group is a *way of finding* an entry, not an entry.
public struct KeyGroup: Sendable, Equatable {
    public let keys: [String]
    public let pointer: EntryPointer

    /// The folded form a lookup should match against. First because that is the order on disk.
    public var searchKey: String? { keys.first }

    /// The form to show a reader, which carries the publisher's own capitalisation and punctuation.
    public var displayKey: String? { keys.last }

    /// Whether any form is more than one word. **39.5% of NOAD's groups**, which is the whole reason to
    /// read this file: a phrase cannot be found by looking up a single word.
    public var isPhrase: Bool {
        keys.contains { $0.contains(" ") || $0.contains("-") }
    }

    public init(keys: [String], pointer: EntryPointer) {
        self.keys = keys
        self.pointer = pointer
    }
}

/// `KeyText.data`, parsed into keys rather than left as bytes.
///
/// **The format, measured rather than documented.** A chunk holds a run of groups, each laid out as:
///
///     UInt32  groupSize      bytes after this field
///     UInt32  ?              1 in every group seen
///     UInt16  ?              always groupSize - 6
///     UInt32  offset         the entry's offset inside its decompressed body chunk
///     UInt16  chunkID        Apple's identifier for that chunk
///     UInt32  keyBytes       length of the key block that follows
///     …       keys           UInt16 byteLength + UTF-16LE text, until a zero length
///
/// **The trap that cost the most:** the two bytes after a key's length field look like a tag, and they
/// are not — `0d 01` is U+010D, `č`. Reading them as a tag silently truncates the first character of
/// every key, turning `čapek` into `apek` and `české budějovice` into `eske budejovic`. The keys still
/// look plausible, which is what makes it dangerous.
///
/// Measured on NOAD: **269,918 groups and 425,749 key strings**, against the 271,029 records Apple's own
/// index reports — so this reads essentially all of it.
public enum KeyIndexReader {
    /// Every key group in the bundle, in file order.
    public static func groups(in bundle: URL) throws -> [KeyGroup] {
        let url = try ContainerReader.keyTextURL(of: bundle)
        return try ContainerReader.keyChunks(at: url).flatMap { groups(inChunk: $0) }
    }

    /// Parsed out of one decompressed chunk. Separate so it can be tested on invented bytes: the real
    /// files are licensed and never vendored into this repository.
    static func groups(inChunk chunk: Data) -> [KeyGroup] {
        var out: [KeyGroup] = []
        var position = 0
        // A group needs its own header before any key can be read; `headerBytes` past the size field.
        while position + 4 + headerBytes <= chunk.count {
            let size = Int(chunk.uint32(at: position))
            // Trailing zeros pad the last chunk of the stride-walked stream.
            guard size > headerBytes, position + 4 + size <= chunk.count else { break }
            let body = position + 4
            let offset = Int(chunk.uint32(at: body + offsetField))
            let chunkID = Int(chunk.uint16(at: body + chunkIDField))
            let keyBytes = Int(chunk.uint32(at: body + keyLengthField))
            position += 4 + size

            guard keyBytes > 0, body + headerBytes + keyBytes <= chunk.count else { continue }
            var keys: [String] = []
            var read = body + headerBytes
            let end = read + keyBytes
            while read + 2 <= end {
                let length = Int(chunk.uint16(at: read))
                // A zero length terminates the block; the remaining bytes are padding.
                guard length > 0, read + 2 + length <= end else { break }
                let slice = chunk.subdata(in: (read + 2) ..< (read + 2 + length))
                if let text = String(data: slice, encoding: .utf16LittleEndian), !text.isEmpty {
                    keys.append(text)
                }
                read += 2 + length
            }
            guard !keys.isEmpty else { continue }
            out.append(KeyGroup(keys: keys, pointer: EntryPointer(chunkID: chunkID, offset: offset)))
        }
        return out
    }

    /// Bytes of group header between the size field and the first key record.
    static let headerBytes = 16
    static let offsetField = 6
    static let chunkIDField = 10
    static let keyLengthField = 12
}

extension Data {
    /// Little-endian UInt16, offset from `startIndex` for the same reason `uint32(at:)` is.
    func uint16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        precondition(base + 2 <= endIndex, "uint16 read past the end")
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }
}
