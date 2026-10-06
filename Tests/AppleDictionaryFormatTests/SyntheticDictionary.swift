import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import AppleDictionaryFormat

/// A `.dictionary` bundle whose body the test wrote, so the reader can be exercised end to end without a
/// licensed dictionary on disk.
///
/// **The container, as `ContainerReader` documents it**: `Body.data` is 0x40 bytes of zeros, a `UInt32`
/// payload size, then one chunk at 0x60 — `size`, `compressed`, `decompressed`, a zlib stream — and the
/// stream holds entries, each a `UInt32` length and that many bytes of UTF-8. The stream is **stored**
/// deflate blocks, which need no compressor; the wrapper is what is being read, not the compression.
///
/// No `KeyText.data`: nothing built on it is asked here, and a missing one only makes the content version
/// say `unreadable` for that file.
enum SyntheticDictionary {
    /// Writes `entries` as the body of a bundle in `directory` and describes it the way
    /// `DictionaryLocator.describe` would.
    static func bundle(
        in directory: TemporaryDirectory, identifier: String, name: String? = nil,
        index: String = "en_US", explains: String = "en_US", entries: [String]
    ) throws -> DictionaryBundle {
        let url = directory.appending("\(name ?? identifier).dictionary")
        let resources = url.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleDisplayName": name ?? identifier,
            "CFBundleShortVersionString": "1",
            "DCSDictionaryLanguages": [[
                "DCSDictionaryIndexLanguage": index, "DCSDictionaryDescriptionLanguage": explains,
            ]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appending(path: "Contents/Info.plist"))
        try body(of: entries).write(to: resources.appending(path: "Body.data"))
        return try #require(DictionaryLocator.describe(url))
    }

    static func body(of entries: [String]) throws -> Data {
        var payload: [UInt8] = []
        for entry in entries {
            let bytes = Array(entry.utf8)
            payload += le32(bytes.count) + bytes
        }
        let stream = try ContainerReaderTests.zlibStream(payload)
        // `compressed` counts the four bytes of the decompressed-size word that follows it, and the next
        // chunk begins `4 + size` after this one's size field.
        let compressed = stream.count + ContainerReader.compressedFieldOverhead
        let size = compressed + 4
        let chunk = le32(size) + le32(compressed) + le32(payload.count) + stream

        var file = [UInt8](repeating: 0, count: ContainerReader.payloadSizeOffset)
        // The payload size is counted from 0x40 and covers the gap to the first chunk.
        file += le32((ContainerReader.firstBodyChunk - ContainerReader.payloadSizeOffset) + chunk.count)
        file += [UInt8](repeating: 0, count: ContainerReader.firstBodyChunk - file.count)
        file += chunk
        return Data(file)
    }

    private static func le32(_ value: Int) -> [UInt8] {
        (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
