import Foundation

/// One installed `.dictionary` bundle, identified by what it says about itself.
public struct DictionaryBundle: Sendable, Equatable {
    public let url: URL
    /// `CFBundleIdentifier` from the bundle's own `Info.plist`.
    public let identifier: String
    /// `CFBundleDisplayName`, for showing a reader — never for keying.
    public let displayName: String
    /// **Resolved through the language adapters**, not `DictionaryProfile.profile` directly.
    ///
    /// Calling the latter bypassed every adapter, so a declaration in `SimplifiedChinese` or `Korean`
    /// had no effect on the profile a caller actually got from a bundle — the adapters existed and were
    /// silently unused. `LanguageAdapters.profile` consults them first and falls back to the default.
    public var profile: DictionaryProfile { LanguageAdapters.profile(for: identifier) }

    public init(url: URL, identifier: String, displayName: String) {
        self.url = url
        self.identifier = identifier
        self.displayName = displayName
    }
}

/// Finding the dictionaries this Mac actually has.
///
/// **Identity comes from the bundle, never the path.** `Simplified Chinese - English.dictionary`
/// contains `com.apple.dictionary.zh_CN-en.OCD` — the Oxford Chinese Dictionary — because Apple's
/// package names are generic slots and what fills them depends on region and release. A tool keyed to
/// file names silently reads a different dictionary than it thinks.
///
/// Region decides what exists at all: a Mac gets one Oxford monolingual and one thesaurus, and which
/// pair depends on its languages. So nothing here assumes a particular dictionary is present — the
/// caller works with what it finds.
public enum DictionaryLocator {
    /// Where macOS keeps them: the OS assets, then anything the reader sideloaded.
    public static let searchPaths: [URL] = {
        var out = [URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS")]
        out.append(URL(fileURLWithPath: "/Library/Dictionaries"))
        out.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Dictionaries"))
        return out
    }()

    /// Every readable bundle found, in a stable order.
    ///
    /// A bundle whose `Info.plist` names no identifier is skipped rather than keyed by name: a tool
    /// that rebuilds an index needs a stable key, and inventing one would produce rows that silently
    /// change on the next import.
    public static func installed(in roots: [URL] = searchPaths) -> [DictionaryBundle] {
        var found: [DictionaryBundle] = []
        var seen = Set<String>()
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker where url.pathExtension == "dictionary" {
                guard let bundle = describe(url), !seen.contains(bundle.identifier) else { continue }
                seen.insert(bundle.identifier)
                found.append(bundle)
            }
        }
        return found.sorted { $0.identifier < $1.identifier }
    }

    /// What a bundle says about itself, or nil when it names no identifier.
    public static func describe(_ url: URL) -> DictionaryBundle? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { return nil }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return DictionaryBundle(url: url, identifier: identifier, displayName: name)
    }
}
