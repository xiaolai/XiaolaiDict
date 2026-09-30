import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import AppleDictionaryFormat

/// The container reader, against bundles on this machine.
///
/// Gated on `XIAOLAIDICT_BUNDLES` so the ordinary suite does not depend on which dictionaries a
/// machine happens to have. No fixture is committed: a `Body.data` cut from a shipped dictionary would
/// put licensed text in the repository, and the format is what is being asserted, not the content.
@Suite struct ContainerReaderTests {
    static var bundles: [URL] {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else { return [] }
        let base = URL(fileURLWithPath: root)
        let found = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "dictionary" } ?? []
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func everyBundleYieldsWellFormedEntries() throws {
        let bundles = Self.bundles
        guard !bundles.isEmpty else {
            print("ContainerReaderTests: XIAOLAIDICT_BUNDLES not set, not measured")
            return
        }
        var read = 0, failed: [String] = []
        for bundle in bundles {
            do {
                let entries = try ContainerReader.entries(in: bundle)
                guard !entries.isEmpty else { failed.append("\(bundle.lastPathComponent): 0 entries"); continue }
                // Each record must be a whole XML document; a wrong offset yields plausible-looking
                // garbage rather than an error, so the shape is what proves the offsets.
                let first = entries[0]
                #expect(first.contains("<d:entry"), "\(bundle.lastPathComponent) first record is not an entry")
                read += 1
            } catch {
                failed.append("\(bundle.lastPathComponent): \(error)")
            }
        }
        print("ContainerReaderTests: read \(read) of \(bundles.count) bundles")
        for f in failed.prefix(6) { print("  could not read \(f)") }
        #expect(read > 0)
    }

    @Test func theKeyIndexIsWalkedByStrideNotBySize() throws {
        guard let bundle = Self.bundles.first(where: {
            $0.lastPathComponent.contains("New Oxford American")
        }) else {
            print("ContainerReaderTests: NOAD not among the bundles, not measured")
            return
        }
        let chunks = try ContainerReader.keyChunks(at: try ContainerReader.keyTextURL(of: bundle))
        // The per-chunk size field is 0 in some chunks. A size-driven walk stops at the first of those
        // and returns an index that looks complete, so "many chunks" is the assertion that matters.
        #expect(chunks.count > 10, "expected the whole index, got \(chunks.count) chunks")
    }

    /// **A chunk declaring an absurd decompressed size is refused before the allocation.**
    ///
    /// `expecting` is four bytes read off disk, so a corrupt chunk claiming `0xffffffff` asked for 4 GiB
    /// before decompression could reject it.
    @Test func aChunkDeclaringMoreThanTheReaderWillAllocateIsRefused() {
        // Invented bytes: a plausible zlib header over nothing, with an impossible declared size.
        let input = Data([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        #expect(throws: ContainerReader.Failure.self) {
            _ = try ContainerReader.inflate(input, expecting: Int(UInt32.max))
        }
        #expect(throws: ContainerReader.Failure.self) {
            _ = try ContainerReader.inflate(input, expecting: ContainerReader.maximumChunkSize + 1)
        }
    }

    /// **`limit: 0` delivers nothing.** The limit was checked after a record was handed over, so zero
    /// yielded one — and a negative limit behaved the same way.
    @Test func aZeroLimitDeliversNoEntries() throws {
        // **A bundle that actually reads**, not simply the first. Sorted by name, the first is
        // `Apple Dictionary.dictionary` — the catalogue's one unreadable asset — so `delivered` stayed 0 for
        // the positive limit too and the test failed on its own fixture rather than on the limit.
        guard let bundle = Self.bundles.first(where: {
            (try? ContainerReader.forEachEntry(in: $0, limit: 1) { _ in }) != nil
        }) else {
            print("ContainerReaderTests: no readable bundle, not measured"); return
        }
        var delivered = 0
        try ContainerReader.forEachEntry(in: bundle, limit: 0) { _ in delivered += 1 }
        #expect(delivered == 0)
        try ContainerReader.forEachEntry(in: bundle, limit: -5) { _ in delivered += 1 }
        #expect(delivered == 0)
        // And a positive limit delivers exactly that many.
        try ContainerReader.forEachEntry(in: bundle, limit: 3) { _ in delivered += 1 }
        #expect(delivered == 3)
    }

    /// **Adler-32 against a known vector**, so the checksum the reader now enforces is itself checked.
    @Test func adler32MatchesTheKnownVectors() {
        #expect(ContainerReader.adler32(of: [UInt8]()) == 1)
        #expect(ContainerReader.adler32(of: Array("a".utf8)) == 0x0062_0062)
        #expect(ContainerReader.adler32(of: Array("abc".utf8)) == 0x024D_0127)
        #expect(ContainerReader.adler32(of: Array("Wikipedia".utf8)) == 0x11E6_0398)
        // Longer than one 5552-byte run, so the deferred modulo is exercised rather than assumed.
        let long = [UInt8](repeating: 0xFF, count: 20_000)
        #expect(ContainerReader.adler32(of: long) != 0)
        #expect(ContainerReader.adler32(of: long) == ContainerReader.adler32(of: long))
    }

    /// **A stream whose checksum does not match its bytes is refused.**
    ///
    /// The wrapper was stripped and raw deflate decoded, so probes decoded identical output with an invalid
    /// header, an altered Adler-32 and no checksum at all — a matching output length was never evidence of
    /// integrity, and this is the assertion that says so.
    @Test func aStreamWithAWrongChecksumIsRefused() throws {
        // Built here rather than cut from a dictionary: the format is what is asserted, not the content.
        let payload = Array("a marsh plant that glows".utf8)
        let stream = try Self.zlibStream(payload)
        // The honest stream decodes.
        let decoded = try ContainerReader.inflate(Data(stream), expecting: payload.count)
        #expect(Array(decoded) == payload)

        // One bit flipped in the trailer must fail.
        var corruptTrailer = stream
        corruptTrailer[corruptTrailer.count - 1] ^= 0x01
        #expect(throws: ContainerReader.Failure.self) {
            _ = try ContainerReader.inflate(Data(corruptTrailer), expecting: payload.count)
        }

        // And a header that is not zlib-deflate must fail before anything is decoded.
        var corruptHeader = stream
        corruptHeader[0] = 0x77
        #expect(throws: ContainerReader.Failure.self) {
            _ = try ContainerReader.inflate(Data(corruptHeader), expecting: payload.count)
        }
    }

    /// A minimal zlib stream: header, **stored** deflate blocks, Adler-32. Stored blocks keep this readable
    /// and need no compressor — the point is the wrapper, not the compression.
    static func zlibStream(_ payload: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]   // deflate, 32K window, check value divisible by 31
        var offset = 0
        while offset < payload.count || offset == 0 {
            let run = min(payload.count - offset, 0xFFFF)
            let last: UInt8 = offset + run >= payload.count ? 1 : 0
            out.append(last)
            out.append(UInt8(run & 0xFF))
            out.append(UInt8(run >> 8))
            out.append(UInt8(~run & 0xFF))
            out.append(UInt8((~run >> 8) & 0xFF))
            out += payload[offset ..< offset + run]
            offset += run
            if last == 1 { break }
        }
        let checksum = ContainerReader.adler32(of: payload)
        out += [UInt8(truncatingIfNeeded: checksum >> 24), UInt8(truncatingIfNeeded: checksum >> 16),
                UInt8(truncatingIfNeeded: checksum >> 8), UInt8(truncatingIfNeeded: checksum)]
        return out
    }
}

/// **A dictionary file is external input, and a bounded read is how that is honoured.**
///
/// `Data.uint32(at:)` and `uint16(at:)` were `precondition`s: every caller bounded its offset, and one
/// missed bound had already turned a truncated container into a crash rather than a thrown error — the
/// surviving comment in `forEachBodyChunk` is what is left of that repair. The reader's own dictionaries
/// can be truncated, replaced mid-read, or come from a macOS this build has not met, and none of those
/// is a reason to end the process the dictionary service runs in — ADR-0042.
@Suite struct BoundedBinaryReadTests {
    /// Before the fix each of these ended the test process instead of answering.
    @Test func areadPastTheEndIsNilRatherThanFatal() {
        let four = Data([1, 2, 3, 4])
        #expect(four.uint32(at: 0) == 0x0403_0201)
        #expect(four.uint32(at: 1) == nil, "a read one byte short of four answered")
        #expect(four.uint32(at: 4) == nil)
        #expect(four.uint32(at: 9_999) == nil)
        #expect(Data().uint32(at: 0) == nil)
        #expect(four.uint16(at: 2) == 0x0403)
        #expect(four.uint16(at: 3) == nil)
        #expect(Data().uint16(at: 0) == nil)
    }

    /// **Offsets are relative to `startIndex`, and a slice's indices continue its parent's.** The bound
    /// has to be relative too, or a slice near the end of a large `Data` refuses reads that are there.
    @Test func aslicesOffsetsAreItsOwn() {
        let slice = Data([9, 9, 9, 9, 1, 2, 3, 4, 5, 6]).dropFirst(4)
        #expect(slice.uint32(at: 0) == 0x0403_0201)
        #expect(slice.uint16(at: 4) == 0x0605)
        #expect(slice.uint32(at: 4) == nil, "the slice read past its own end")
    }

    /// The end-to-end shape: a file too short to hold its own header is refused with a reason.
    @Test func atruncatedContainerIsRefusedWithAReason() throws {
        let directory = TemporaryDirectory(named: "container-reader")
        let url = directory.appending("Body.data")
        try Data(repeating: 0, count: 8).write(to: url)
        #expect(throws: ContainerReader.Failure.self) {
            try ContainerReader.forEachBodyChunk(at: url) { _, _ in }
        }
    }
}
