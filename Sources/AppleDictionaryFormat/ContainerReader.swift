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
    static let firstKeyChunk = 0x44
    static let keyStride = 8192

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
    public static func bodyChunks(at url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // The read below is a UInt32 at `payloadSizeOffset`, so four bytes past it must exist. Guarding
        // on `headerSize` alone accepted 65–67-byte files and turned a truncated file into a
        // precondition crash instead of a thrown error.
        guard data.count >= payloadSizeOffset + 4 else {
            throw Failure.truncated("\(url.lastPathComponent): \(data.count) bytes, shorter than the header")
        }
        let payload = Int(data.uint32(at: payloadSizeOffset))
        let end = payloadSizeOffset + payload
        guard end <= data.count else {
            throw Failure.truncated("\(url.lastPathComponent): header claims \(end) bytes, file has \(data.count)")
        }
        var out: [Data] = []
        var position = firstBodyChunk
        while position + chunkHeader <= end {
            let size = Int(data.uint32(at: position))
            if size == 0 { break }
            let compressed = Int(data.uint32(at: position + 4))
            let expected = Int(data.uint32(at: position + 8))
            let start = position + chunkHeader
            guard start + compressed <= data.count else {
                throw Failure.truncated("\(url.lastPathComponent): chunk at \(position) runs past the file")
            }
            let block = try inflate(data.subdata(in: start ..< start + compressed), expecting: expected)
            guard block.count == expected else {
                throw Failure.badChunk(
                    "\(url.lastPathComponent): chunk at \(position) gave \(block.count) bytes, header says \(expected)")
            }
            out.append(block)
            position += 4 + size
        }
        guard !out.isEmpty else {
            throw Failure.badChunk("\(url.lastPathComponent): no chunks at \(firstBodyChunk)")
        }
        return out
    }

    /// Every entry's XHTML, in file order. Each chunk holds a run of length-prefixed UTF-8 records.
    public static func entries(in bundle: URL) throws -> [String] {
        var out: [String] = []
        for chunk in try bodyChunks(at: try bodyURL(of: bundle)) {
            var offset = 0
            while offset + 4 <= chunk.count {
                let length = Int(chunk.uint32(at: offset))
                guard length > 0, offset + 4 + length <= chunk.count else { break }
                let slice = chunk.subdata(in: offset + 4 ..< offset + 4 + length)
                if let text = String(data: slice, encoding: .utf8) { out.append(text) }
                offset += 4 + length
            }
        }
        return out
    }

    /// Every decompressed chunk of the key index.
    ///
    /// Walked by the **fixed stride**, not by the per-chunk size field, which is 0 in some chunks. A
    /// reader that trusts that field stops at the first such chunk and returns a partial index that
    /// looks complete.
    public static func keyChunks(at url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > firstKeyChunk + chunkHeader else {
            throw Failure.truncated("\(url.lastPathComponent): \(data.count) bytes, no first chunk")
        }
        var out: [Data] = []
        var position = firstKeyChunk
        while position + chunkHeader <= data.count {
            let compressed = Int(data.uint32(at: position + 4))
            let expected = Int(data.uint32(at: position + 8))
            let start = position + chunkHeader
            if compressed > 0, expected > 0, start + compressed <= data.count,
               let block = try? inflate(data.subdata(in: start ..< start + compressed), expecting: expected),
               block.count == expected {
                out.append(block)
            }
            position += keyStride
        }
        guard !out.isEmpty else {
            throw Failure.badChunk("\(url.lastPathComponent): no chunks at \(firstKeyChunk)")
        }
        return out
    }

    /// zlib-wrapped deflate. `COMPRESSION_ZLIB` in Apple's Compression framework is **raw** deflate, so
    /// the two-byte zlib header is dropped first; passing the wrapped stream straight in fails.
    static func inflate(_ input: Data, expecting: Int) throws -> Data {
        guard input.count > 2 else { throw Failure.badChunk("chunk too short to be a zlib stream") }
        guard expecting > 0 else { throw Failure.badChunk("chunk declares no decompressed size") }
        let raw = input.dropFirst(2)
        // **One byte of slack, deliberately.** `compression_decode_buffer` returns the destination size
        // when output fills it, so a buffer of exactly `expecting` cannot distinguish "decompressed to
        // exactly the declared size" from "produced more and was cut off". With room for one more byte,
        // `written > expecting` is detectable and a chunk claiming the wrong size fails loudly.
        var output = Data(count: expecting + 1)
        let written: Int = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expecting + 1,
                    source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw Failure.badChunk("chunk did not decompress") }
        guard written == expecting else {
            throw Failure.badChunk("chunk decompressed to \(written) bytes, header declares \(expecting)")
        }
        return output.prefix(written)
    }
}

extension Data {
    /// Little-endian UInt32 at a byte offset, read relative to `startIndex` rather than to 0.
    ///
    /// `Data`'s range subscript yields a slice whose indices continue the parent's, so `slice[0]` traps
    /// or reads the wrong byte. `subdata(in:)` copies and does rebase, but relying on which of the two
    /// a caller used is exactly the bug this avoids: offsetting from `startIndex` is correct for both.
    func uint32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        precondition(base + 4 <= endIndex, "uint32 read past the end")
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }
}
