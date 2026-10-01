import Compression
import Foundation

/// Reading an Apple `.dictionary` bundle's own files, rather than asking Dictionary Services.
///
/// **Why the files at all.** Dictionary Services answers one headword at a time and exposes no way to
/// enumerate — there is no `DCSCopyKeys`, confirmed by symbol probe. So a hover cannot discover
/// `take something into account` by asking: the API answers only to that exact citation form, which is
/// the thing being looked for. NOAD's own index holds 271,029 records, 146,535 of them multi-word.
/// Reading the container is the only way to have them.
///
/// **The layout, measured rather than assumed.** It holds for the 85 readable assets in the macOS 27
/// catalogue, all of which declare `FormatVersion: 2`.
///
/// **Three path layouts, and one bundle this reader still cannot read.** Most bundles keep `Body.data`
/// under `Contents/Resources/`, some directly under `Contents/`, and `com.apple.dictionary.AppleDictionary`
/// keeps **one per locale** under `Contents/Resources/<lang>.lproj/` — all three are searched.
///
/// Apple Dictionary is nonetheless the one failure, and the reason is the payload, not the path: its
/// chunks do not decompress as zlib-wrapped deflate. So it differs in **two** ways, and two earlier
/// claims here were wrong about it — first that it has no `Body.data` (it has about thirty), then that
/// only its path differed. It is Apple's software glossary rather than a language dictionary, so it is
/// left unread rather than reverse-engineered; **85 of 86** is the honest figure and a caller iterating
/// the catalogue should expect that one failure.
///
///     Body.data
///       0x00..0x40  zeros
///       0x40        UInt32  payload size, counted from 0x40
///       0x60        first chunk — fixed, never read from the file
///       chunk       UInt32 size · UInt32 compressed · UInt32 decompressed · zlib stream
///                   the next chunk begins 4 + size later
///       payload     a run of entries, each a UInt32 length then that many bytes of UTF-8
///
///     KeyText.data
///       0x44        first chunk, and chunks are a FIXED 8,192 bytes apart
///
/// **The one trap.** `KeyText.data`'s per-chunk size field is **0 in some chunks**, so a walker that
/// trusts it stops early and silently returns a partial index. The stride is fixed; use it.
public enum ContainerReader {
    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case truncated(String)
        case badChunk(String)
        public var description: String {
            switch self {
            case .missing(let s), .truncated(let s), .badChunk(let s): return s
            }
        }
    }

    static let headerSize = 0x40
    static let payloadSizeOffset = 0x40
    static let firstBodyChunk = 0x60
    static let chunkHeader = 12
    /// Bytes of the `compressed` field that are **not** the zlib stream.
    ///
    /// **Measured, because the field is inclusive of the decompressed-size word that follows it.** Over
    /// NOAD's body, `size - compressed` is a constant **4** in every chunk, and every chunk decompresses
    /// correctly from `compressed - 4` bytes with its Adler-32 trailer in the last four of those. The same
    /// holds for `KeyText.data` in NOAD, the Oxford thesaurus and 牛津英汉汉英 — 460 key chunks checked, all
    /// of them. Slicing the whole field read four bytes of the *next* chunk's header; zlib stops at the end
    /// of its stream and ignored them, so nothing failed and every bounds check was four bytes too lax.
    static let compressedFieldOverhead = 4
    static let firstKeyChunk = 0x44
    static let keyStride = 8192
    /// The largest decompressed chunk this reader will allocate for.
    ///
    /// **A file-controlled size was allocated unchecked.** `Data(count: expecting + 1)` where `expecting`
    /// is four bytes read off disk means a corrupt chunk declaring `0xffffffff` asks for 4 GiB before
    /// decompression can reject it. Measured across the catalogue, the largest real chunk is well under a
    /// megabyte — Apple's are about 290 KB — so 64 MiB refuses the malformed case without coming near a
    /// legitimate one.
    static let maximumChunkSize = 64 << 20

    /// `Body.data`, in either bundle layout Apple has shipped.
    public static func bodyURL(of bundle: URL) throws -> URL {
        try locate(bundle, "Body.data")
    }

    /// `KeyText.data`, in either bundle layout.
    public static func keyTextURL(of bundle: URL) throws -> URL {
        try locate(bundle, "KeyText.data")
    }

    private static func locate(_ bundle: URL, _ name: String) throws -> URL {
        for relative in [["Contents", "Resources", name], ["Contents", name]] {
            let candidate = relative.reduce(bundle) { $0.appendingPathComponent($1) }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // The localized layout, last because only Apple's own glossary uses it. Preference order is the
        // reader's languages, then English, then whatever exists — so the choice is deterministic rather
        // than whatever the directory enumerator returned first.
        let resources = bundle.appendingPathComponent("Contents/Resources")
        if let localized = try? FileManager.default.contentsOfDirectory(atPath: resources.path) {
            let projects = localized.filter { $0.hasSuffix(".lproj") }.sorted()
            let preferred = Locale.preferredLanguages.map { "\($0).lproj" }
                + ["en.lproj", "English.lproj"]
            for candidate in preferred + projects {
                let url = resources.appendingPathComponent(candidate).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        throw Failure.missing("\(bundle.lastPathComponent): no \(name) in any known bundle layout")
    }

    /// Every decompressed chunk of the body, in file order.
    ///
    /// **Materialises all of them.** NOAD's body is 230 MB decompressed, so a pass that only needs one
    /// chunk at a time should use `forEachBodyChunk(at:_:)` and let each one go.
    public static func bodyChunks(at url: URL) throws -> [Data] {
        var out: [Data] = []
        try forEachBodyChunk(at: url) { _, chunk in out.append(chunk) }
        guard !out.isEmpty else {
            throw Failure.badChunk("\(url.lastPathComponent): no chunks at \(firstBodyChunk)")
        }
        return out
    }

    /// The same walk, handing each chunk over and keeping none. The file is memory-mapped, so peak
    /// memory is one decompressed chunk — about 290 KB — rather than the whole body.
    public static func forEachBodyChunk(at url: URL, _ body: (Int, Data) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // **The read is the bound.** Guarding on `headerSize` alone accepted 65–67-byte files and turned
        // a truncated file into a precondition crash; a separate `count >= payloadSizeOffset + 4` guard
        // beside it was a second spelling of the same four bytes, free to drift from the read it guarded.
        guard let payload = data.uint32(at: payloadSizeOffset).map(Int.init) else {
            throw Failure.truncated("\(url.lastPathComponent): \(data.count) bytes, shorter than the header")
        }
        let end = payloadSizeOffset + payload
        guard end <= data.count else {
            throw Failure.truncated("\(url.lastPathComponent): header claims \(end) bytes, file has \(data.count)")
        }
        var position = firstBodyChunk
        var index = 0
        while position + chunkHeader <= end {
            guard let size = data.uint32(at: position).map(Int.init),
                  let compressed = data.uint32(at: position + 4).map(Int.init),
                  let expected = data.uint32(at: position + 8).map(Int.init)
            else {
                throw Failure.truncated(
                    "\(url.lastPathComponent): the chunk header at \(position) runs past the file")
            }
            if size == 0 { break }
            let start = position + chunkHeader
            // **Checked before the copy, not inside `inflate`.** `subdata` copies a file-controlled length,
            // so a malformed chunk forced the allocation before anything could reject it.
            guard compressed <= maximumChunkSize, expected <= maximumChunkSize else {
                throw Failure.badChunk("\(url.lastPathComponent): chunk at \(position) declares "
                                       + "\(compressed)/\(expected) bytes, over the \(maximumChunkSize) cap")
            }
            let streamLength = compressed - compressedFieldOverhead
            guard streamLength > 0, start + streamLength <= data.count else {
                throw Failure.truncated("\(url.lastPathComponent): chunk at \(position) runs past the file")
            }
            let block = try inflate(data.subdata(in: start ..< start + streamLength), expecting: expected)
            guard block.count == expected else {
                throw Failure.badChunk(
                    "\(url.lastPathComponent): chunk at \(position) gave \(block.count) bytes, header says \(expected)")
            }
            // The index is the chunk's position in file order, which is what a pointer's chunk id
            // resolves to. It must count every chunk the walk yields, or every later index shifts.
            try body(index, block)
            index += 1
            position += 4 + size
        }
    }

    /// Every entry's XHTML, handed over one at a time and kept none.
    ///
    /// **Prefer this to `entries(in:)` for any pass over a whole dictionary.** That one materialises every
    /// record: NOAD's body is 230 MB decompressed across 111,606 records, and a caller that wanted the
    /// first 200 still paid for all of them. Here the file is memory-mapped and one decompressed chunk is
    /// live at a time, so peak memory is about 290 KB whatever the dictionary's size.
    ///
    /// `limit` stops the walk after that many entries, without decompressing the rest.
    public static func forEachEntry(in bundle: URL, limit: Int? = nil,
                                    _ body: (String) throws -> Void) throws {
        /// Thrown to leave `forEachBodyChunk`, which has no other way to stop early, and never escapes.
        struct Enough: Error {}
        // **`limit: 0` must deliver nothing.** The check below fires after a record is handed over, so zero
        // used to yield one — and a negative limit behaved the same way.
        if let limit, limit <= 0 { return }
        var delivered = 0
        do {
            try forEachBodyChunk(at: try bodyURL(of: bundle)) { _, chunk in
                for offset in BodyLayout.recordOffsets(in: chunk) {
                    guard let text = BodyLayout.record(in: chunk, at: offset) else { continue }
                    try body(text)
                    delivered += 1
                    if let limit, delivered >= limit { throw Enough() }
                }
            }
        } catch is Enough {
            return
        }
    }

    /// Every entry's XHTML, in file order, all of it in memory at once.
    ///
    /// Kept for callers that genuinely want the array; anything walking a whole dictionary should use
    /// `forEachEntry(in:limit:_:)` instead.
    public static func entries(in bundle: URL) throws -> [String] {
        var out: [String] = []
        try forEachEntry(in: bundle) { out.append($0) }
        return out
    }

    /// Every decompressed chunk of the key index.
    ///
    /// Walked by the **fixed stride**, not by the per-chunk size field, which is 0 in some chunks. A
    /// reader that trusts that field stops at the first such chunk and returns a partial index that
    /// looks complete.
    /// Every decompressed chunk, **and how many the stride visited** — because the difference is the
    /// defect.
    ///
    /// A chunk that fails any check below is dropped and the walk continues, so a file whose chunks are
    /// almost all unreadable returns a handful of groups and no error at all. Measured 2026-09-28:
    /// 英譯廣東口語詞典 yields **7 key groups for 2,472 entries** from a 188 KB key file, and the
    /// confidence gate then marked it `verified` at 100% agreement — because agreement is measured over
    /// the keys that were read. `read` against `attempted` is what makes that visible.
    public struct KeyChunkRead: Sendable {
        public let blocks: [Data]
        /// Chunk positions the fixed stride visited, whether or not they decompressed.
        public let attempted: Int
        public var read: Int { blocks.count }
        /// The share that decompressed. **Never a claim about content** — a chunk can decompress and
        /// still hold nothing a caller wants.
        public var coverage: Double { attempted == 0 ? 0 : Double(blocks.count) / Double(attempted) }
    }

    /// The blocks alone, for callers that do not judge coverage.
    public static func keyChunks(at url: URL) throws -> [Data] {
        try readKeyChunks(at: url).blocks
    }

    public static func readKeyChunks(at url: URL) throws -> KeyChunkRead {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > firstKeyChunk + chunkHeader else {
            throw Failure.truncated("\(url.lastPathComponent): \(data.count) bytes, no first chunk")
        }
        var out: [Data] = []
        var attempted = 0
        var position = firstKeyChunk
        while position + chunkHeader <= data.count {
            attempted += 1
            // A chunk whose header is not there is one this stride-walk cannot read, like every other
            // unreadable chunk here: counted in `attempted` and skipped, never fatal.
            guard let compressed = data.uint32(at: position + 4).map(Int.init),
                  let expected = data.uint32(at: position + 8).map(Int.init)
            else {
                position += keyStride
                continue
            }
            let start = position + chunkHeader
            let streamLength = compressed - compressedFieldOverhead
            if streamLength > 0, expected > 0, start + streamLength <= data.count,
               compressed <= maximumChunkSize, expected <= maximumChunkSize,
               let block = try? inflate(data.subdata(in: start ..< start + streamLength),
                                        expecting: expected),
               block.count == expected {
                out.append(block)
            }
            position += keyStride
        }
        guard !out.isEmpty else {
            throw Failure.badChunk("\(url.lastPathComponent): no chunks at \(firstKeyChunk)")
        }
        return KeyChunkRead(blocks: out, attempted: attempted)
    }

    /// One zlib stream: a two-byte header, raw deflate, and a four-byte Adler-32 of the output.
    ///
    /// `COMPRESSION_ZLIB` in Apple's Compression framework is **raw** deflate, so the wrapper is handled
    /// here — and handled means *checked*, not merely skipped. The header's own check value and the
    /// publisher's Adler-32 are both verified, which is what output length alone cannot do: probes decoded
    /// identical bytes with an invalid header, an altered checksum and no checksum at all, so a matching
    /// length was never evidence of integrity. Verified present and correct over 400 NOAD body chunks and
    /// 460 key chunks across three dictionaries.
    static func inflate(_ input: Data, expecting: Int) throws -> Data {
        // 2 header + at least 1 deflate byte + 4 trailer.
        guard input.count >= 7 else { throw Failure.badChunk("chunk too short to be a zlib stream") }
        guard input.count <= maximumChunkSize else {
            throw Failure.badChunk("chunk carries \(input.count) compressed bytes, over the "
                                   + "\(maximumChunkSize) this reader will read")
        }
        guard expecting > 0 else { throw Failure.badChunk("chunk declares no decompressed size") }
        guard expecting <= maximumChunkSize else {
            throw Failure.badChunk("chunk declares \(expecting) decompressed bytes, over the "
                                   + "\(maximumChunkSize) this reader will allocate")
        }
        // RFC 1950: low nibble of CMF is the method, 8 for deflate, and CMF·256+FLG is a multiple of 31.
        let cmf = input[input.startIndex], flg = input[input.startIndex + 1]
        guard cmf & 0x0f == 8 else {
            throw Failure.badChunk("zlib header names method \(cmf & 0x0f), not deflate")
        }
        guard (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw Failure.badChunk("zlib header check value is wrong")
        }
        let raw = input.dropFirst(2).dropLast(4)
        // **One byte of slack, deliberately.** `compression_decode_buffer` returns the destination size
        // when output fills it, so a buffer of exactly `expecting` cannot distinguish "decompressed to
        // exactly the declared size" from "produced more and was cut off". With room for one more byte,
        // `written > expecting` is detectable and a chunk claiming the wrong size fails loudly.
        var output = Data(count: expecting + 1)
        // **Both base addresses below are non-nil by the guards above**: `baseAddress` is nil only for
        // an *empty* buffer, `input.count >= 7` leaves `raw` at least one byte, and `expecting > 0`
        // leaves `output` at least two. Were that ever wrong, writing nothing throws "did not
        // decompress" below — a bad chunk, not a trap in the reader's process.
        let written: Int = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let into = destination.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(into, expecting + 1, from, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw Failure.badChunk("chunk did not decompress") }
        guard written == expecting else {
            throw Failure.badChunk("chunk decompressed to \(written) bytes, header declares \(expecting)")
        }
        let result = output.prefix(written)
        // The publisher's own checksum, big-endian in the last four bytes of the stream.
        let trailer = input.suffix(4)
        let declared = trailer.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let actual = adler32(of: result)
        guard declared == actual else {
            throw Failure.badChunk(String(format: "chunk checksum is %08x, the stream declares %08x",
                                          actual, declared))
        }
        return result
    }

    /// Adler-32 (RFC 1950), which is what a zlib stream carries and what Apple's raw-deflate decoder never
    /// looks at. `5552` is the largest run that cannot overflow `UInt32` before the modulo.
    static func adler32<Bytes: Collection>(of bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        let base: UInt32 = 65521
        var a: UInt32 = 1, b: UInt32 = 0
        var remaining = bytes[bytes.startIndex...]
        while !remaining.isEmpty {
            let run = remaining.prefix(5552)
            for byte in run {
                a += UInt32(byte)
                b += a
            }
            a %= base
            b %= base
            remaining = remaining.dropFirst(run.count)
        }
        return b << 16 | a
    }
}

extension Data {
    /// Little-endian UInt32 at a byte offset, read relative to `startIndex` rather than to 0 — **nil
    /// where the four bytes are not there**.
    ///
    /// `Data`'s range subscript yields a slice whose indices continue the parent's, so `slice[0]` traps
    /// or reads the wrong byte. `subdata(in:)` copies and does rebase, but relying on which of the two
    /// a caller used is exactly the bug this avoids: offsetting from `startIndex` is correct for both.
    ///
    /// **Optional rather than a `precondition`, because these are the reader's own files.** Every caller
    /// bounds its offset, and a truncated container already turned one missed bound into a crash rather
    /// than a thrown error — the comment in `forEachBodyChunk` is what is left of that. A dictionary
    /// this reader installed is external input: it may be truncated, replaced mid-read, or from a macOS
    /// this build has not met, and none of those is a reason to end the process. Now the read itself is
    /// the bound, so a caller's guard cannot drift from what it guards.
    func uint32(at offset: Int) -> UInt32? {
        let base = startIndex + offset
        guard base >= startIndex, base + 4 <= endIndex else { return nil }
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
