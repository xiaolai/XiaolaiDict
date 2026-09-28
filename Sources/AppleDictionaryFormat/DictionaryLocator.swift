import CryptoKit
import Foundation

/// One installed `.dictionary` bundle, identified by what it says about itself.
/// One `DCSDictionaryLanguages` entry: what a dictionary indexes, and what it explains in.
///
/// Declared here rather than borrowed from `DictionaryModel`, because this module deliberately links
/// nothing but Foundation, Compression, CryptoKit and SQLite3 — that is what makes it shippable on its
/// own, and `ModuleBoundaryTests` holds it to that exact set.
public struct DeclaredLanguage: Sendable, Equatable {
    public let index: String
    public let explains: String

    public init(index: String, explains: String) {
        self.index = index
        self.explains = explains
    }

    static func tag(_ identifier: String) -> Locale.Language? {
        let normalised = identifier.replacingOccurrences(of: "_", with: "-")
        return normalised.isEmpty ? nil : Locale.Language(identifier: normalised)
    }

    /// Whether two tags name the same language **and script**.
    ///
    /// Script, because Apple writes `zh_CN` and `zh_TW` and Foundation resolves those to Hans and Hant —
    /// so a Simplified reader is served 牛津英汉汉英词典 and not 譯典通. Region is not compared: it has
    /// already done its work by deciding the script, and `zh-Hans-SG` is a Simplified reader.
    static func same(_ a: String, _ b: String) -> Bool {
        guard let x = tag(a), let y = tag(b) else { return false }
        return x.languageCode == y.languageCode && x.script == y.script
    }

    public var indexesEnglish: Bool { Self.tag(index)?.languageCode?.identifier == "en" }
    var explainsInEnglish: Bool { Self.tag(explains)?.languageCode?.identifier == "en" }
}

public struct DictionaryBundle: Sendable, Equatable {
    public let url: URL
    /// `CFBundleIdentifier` from the bundle's own `Info.plist`.
    public let identifier: String
    /// `CFBundleDisplayName`, for showing a reader — never for keying.
    public let displayName: String
    /// `CFBundleShortVersionString`, as the bundle declares it. NOAD reads `2.6`.
    public let declaredVersion: String
    /// **Resolved through the language adapters**, not `DictionaryProfile.profile` directly.
    ///
    /// Calling the latter bypassed every adapter, so a declaration in `SimplifiedChinese` or `Korean`
    /// had no effect on the profile a caller actually got from a bundle — the adapters existed and were
    /// silently unused. `LanguageAdapters.profile` consults them first and falls back to the default.
    public var profile: DictionaryProfile { LanguageAdapters.profile(for: identifier) }

    /// `DCSDictionaryLanguages`, as the bundle declares it. Empty for a sideloaded conversion — none of
    /// the six installed here declares any — and an undeclared bundle serves nobody, because guessing
    /// would put a dictionary in an audience it may not belong to.
    public let languages: [DeclaredLanguage]

    public init(url: URL, identifier: String, displayName: String, declaredVersion: String = "",
                languages: [DeclaredLanguage] = []) {
        self.url = url
        self.identifier = identifier
        self.displayName = displayName
        self.declaredVersion = declaredVersion
        self.languages = languages
    }

    /// Whether this dictionary belongs in `reader`'s index.
    ///
    /// **Three audiences, not two.** Simplified Chinese, Traditional Chinese and Cantonese each want
    /// their own bilingual dictionary: a Cantonese reader wants Cantonese glosses, not Mandarin written
    /// in Traditional characters, and `yue` is a different language from `zh` however the script agrees.
    ///
    /// English headwords are the whole point — a dictionary whose headwords are Chinese can never answer
    /// the lookup this product exists for (ADR-0027) — and the English monolinguals come along for every
    /// audience, because NOAD is what every accuracy figure here rests on and the thesaurus is where a
    /// tapped sense is studiable.
    /// Whether this dictionary can be asked about an English word at all.
    ///
    /// Wider than `serves(reader:)` on purpose. **Phrase detection is not sense selection**: D7 scopes the
    /// selector's candidate set to one dictionary, and says nothing about which spans exist. A Simplified
    /// reader whose primary is 牛津英汉汉英 would find almost no phrases from it — its multi-word keys are
    /// pinyin — while NOAD sitting right beside it holds 104,009.
    public var indexesEnglish: Bool { languages.contains(where: \.indexesEnglish) }

    public func serves(reader: String) -> Bool {
        languages.contains { $0.indexesEnglish && ($0.explainsInEnglish || DeclaredLanguage.same($0.explains, reader)) }
    }

    /// What a rebuild compares against to decide whether this dictionary's content has changed.
    ///
    /// **A hash of the bytes, because the declared version and a length are both too weak.** Apple
    /// re-masters these — 牛津英汉汉英's copyright reads "© 2010, 2025" — so the version string alone misses
    /// content changes. Adding the body's *length* was the first fix and it misses two real cases: a
    /// replacement of the same size, and a change confined to `KeyText.data`, which decides what can be
    /// looked up at all. Either one leaves a rebuild reporting `upToDate` over stale senses and aliases
    /// for ever — and nothing downstream could notice, because the only symptom is a definition that is
    /// quietly out of date.
    ///
    /// **Both files, streamed.** SHA-256 over `Body.data` and `KeyText.data`, read a chunk at a time and
    /// never held whole: NOAD's body is 100 MB on disk. Length and modification time are deliberately not
    /// part of it — an asset re-download touches the mtime without changing a word, and rebuilding NOAD for
    /// nothing costs minutes.
    ///
    /// A file that cannot be read contributes `unreadable`, which differs from any digest, so an
    /// unreadable dictionary is never mistaken for an unchanged one. `IndexRebuilder` refuses it anyway.
    public func contentVersion() -> String {
        let body = fingerprint(of: try? ContainerReader.bodyURL(of: url))
        let keys = fingerprint(of: try? ContainerReader.keyTextURL(of: url))
        return "\(declaredVersion):\(body):\(keys)"
    }

    /// SHA-256 of one file, read incrementally. 16 hex is 64 bits, over two files and a version string —
    /// this identifies a build of a dictionary, and is not a security boundary.
    private func fingerprint(of url: URL?) -> String {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? handle.close() }
        var hash = SHA256()
        // **A read error is not the end of the file.** `try?` made the two indistinguishable, so a failure
        // part-way through returned a perfectly plausible digest of the prefix — or of nothing at all — and
        // a rebuild would have compared that against a complete one and found them different, or worse,
        // found two different truncations alike.
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hash.update(data: chunk)
            }
        } catch {
            return "unreadable"
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
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
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String) ?? ""
        let declared = (info["DCSDictionaryLanguages"] as? [[String: Any]] ?? []).compactMap { entry -> DeclaredLanguage? in
            guard let index = entry["DCSDictionaryIndexLanguage"] as? String else { return nil }
            return DeclaredLanguage(index: index,
                                    explains: entry["DCSDictionaryDescriptionLanguage"] as? String ?? index)
        }
        return DictionaryBundle(url: url, identifier: identifier, displayName: name,
                                declaredVersion: version, languages: declared)
    }
}
