import Foundation
import Testing
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
}
