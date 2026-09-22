import Foundation
import XiaolaiDictCore
import Synchronization

/// A dictionary enabled in Dictionary.app's settings.
public struct InstalledDictionary: Sendable, Equatable {
    public let identity: DictionaryIdentity
    /// What the bundle declares about its languages — empty for every sideloaded conversion,
    /// which is six of the seven enabled on the development Mac.
    public let languages: [DictionaryLanguages]

    public init(identity: DictionaryIdentity, languages: [DictionaryLanguages] = []) {
        self.identity = identity
        self.languages = languages
    }

    public var name: String { identity.name }
}

public enum DictionaryBridgeError: Error, Equatable {
    case blankTerm
    case termTooLong(characters: Int)
    /// The framework or one of its private symbols is gone, or answered with something this code
    /// does not understand — a future macOS changed it.
    case unavailable(String)
    /// Dictionaries had the term, but not one of their entries could be read.
    case unreadable(dictionaries: [String])
}

/// What the dictionaries had for a term.
public struct DictionaryLookup: Sendable, Equatable {
    /// Every entry every dictionary had for the term, grouped under its dictionary, in the
    /// reader's dictionary order. A dictionary contributes as many as it answered with.
    ///
    /// **Whether one entry can appear twice is the answering function's promise, not this type's.**
    /// `entries(for:)` collapses the copies a dictionary returns when it indexes a single entry
    /// under several headwords; `records(for:)`, which it is built from, hands them over as the
    /// framework gave them. Stating "never twice" here would have made the type claim something
    /// one of its two producers does not do.
    public let entries: [DictionaryEntry]
    /// Dictionaries that had the term but at least one of whose entries could not be read. Named
    /// once each, however many of their records failed.
    public let unreadable: [String]
}

/// The private DictionaryServices API: per-dictionary, fully styled entries, which the public
/// `DCSCopyTextDefinition` cannot give. Undocumented, and its failure mode is a segfault — so this
/// module is linked only by the XPC service, never by the app (design note §10).
///
/// Signatures as probed on macOS 27, 2026-09-18.
public enum DictionaryBridge {
    /// Every call into the framework holds this. Nothing documents DictionaryServices as safe to
    /// call from two threads at once, and an undocumented API gets no benefit of the doubt: the
    /// service's listener already delivers requests one at a time, and this holds any other caller
    /// — tests run concurrently — to the same.
    private static let serial = Mutex(())

    /// Every enabled dictionary, in the order the reader set in Dictionary.app.
    public static func activeDictionaries() throws(DictionaryBridgeError) -> [InstalledDictionary] {
        try serial.withLock { _ throws(DictionaryBridgeError) in
            let api = try API.loaded.get()
            var installed: [InstalledDictionary] = []
            for dictionary in try api.dictionaries() {
                installed.append(InstalledDictionary(
                    identity: try api.identity(of: dictionary),
                    languages: api.languages(of: dictionary)))
            }
            return installed
        }
    }

    /// The XPC service's answer to whatever the app asked.
    public static func reply(to request: ServiceRequest) -> ServiceReply {
        switch request {
        case .lookup(let lookup): .lookup(reply(to: lookup))
        case .dictionaries(let reprobing): .dictionaries(capabilities(reprobing: reprobing))
        }
    }

    /// Which words the capability probe tries, in order, until one is found in the dictionary being
    /// probed. Mixed scripts on purpose: a Chinese-only or Korean-only dictionary has no "fine",
    /// and reporting it as unkeyable because an English word missed would be a measurement error
    /// dressed as a finding.
    static let probeWords = ["fine", "hold", "water", "水", "人", "하다", "する"]

    /// Every enabled dictionary and the finest rung it can key a study item to.
    ///
    /// Measured rather than assumed, because the rung is a property of the entries: the Writer's
    /// Thesaurus carries publisher sense ids on some entries and not on others. Computed once per
    /// service process — each probe parses a real entry, and Longman's *hold* alone is 625 KB.
    public static func capabilities(reprobing: Bool = false) -> [DictionaryCapability] {
        // Cleared before the fast path is consulted, so a reprobe cannot be answered from the very
        // cache it was sent to discard.
        if reprobing { probed.withLock { $0 = nil } }
        if let known = probed.withLock({ $0 }) { return known }
        // The *probe* is serialised, not merely its result cached. Reading the cache and then
        // probing without holding anything lets two callers both find it empty and both parse
        // every installed dictionary — 625 KB for Longman's *hold* alone — with the loser throwing
        // its work away. The XPC listener happens to deliver requests one at a time, but nothing
        // here makes that a guarantee, and the doc above promises once per process.
        //
        // Found by counting probes in a test. The assertion it replaced timed the second call, and
        // timing could not see this: the second call is fast either way.
        //
        // Safe to hold across `activeDictionaries()`, which takes `serial`: nothing anywhere calls
        // `capabilities()` while holding `serial`, so the two are never taken in the other order.
        return probing.withLock { _ in
            // Another caller won the race — but not for a reprobe, which must not be satisfied by
            // an answer that was already stale when it was asked for.
            if !reprobing, let known = probed.withLock({ $0 }) { return known }
            let installed = (try? activeDictionaries()) ?? []
            let scripts = indexedScripts()
            var found: [DictionaryCapability] = []
            for dictionary in installed {
                found.append(capability(
                    of: dictionary, indexes: scripts[dictionary.identity.key] ?? []))
            }
            probeRuns.withLock { $0 += 1 }
            probed.withLock { $0 = found }
            return found
        }
    }

    private static let probed = Mutex<[DictionaryCapability]?>(nil)
    /// Held across the probe itself, so it happens once however many callers arrive together.
    private static let probing = Mutex(())

    /// How many times the probe has actually run. Counted because it cannot be *timed*: the cache
    /// is process-wide, so a test that happens to run second measures a warm cache, passes in
    /// microseconds, and has checked nothing at all.
    static let probeRuns = Mutex(0)

    private static func capability(
        of installed: InstalledDictionary, indexes: Set<ProbeScript>
    ) -> DictionaryCapability {
        let identity = installed.identity
        for word in probeWords {
            let entries = ((try? entries(for: word))?.entries ?? []).filter { $0.dictionary == identity }
            guard let best = entries.map(\.senseKeyKind).max() else { continue }
            return DictionaryCapability(
                identity: identity, senseKeyKind: best, probed: true,
                languages: installed.languages, indexes: indexes)
        }
        return DictionaryCapability(
            identity: identity, senseKeyKind: SenseKeyKind.none, probed: false,
            languages: installed.languages, indexes: indexes)
    }

    /// Which scripts each enabled dictionary answers in, keyed by `DictionaryIdentity.key`.
    ///
    /// This is the language signal that survives a bundle declaring nothing, and it is measured on
    /// records alone — no entry is parsed, so it costs the cheap half of a lookup rather than
    /// Longman's 625 KB *hold*. One probe per script is enough: the loop stops asking about a
    /// script the dictionary has already answered in, so *hold* and *water* are never sent to a
    /// dictionary that answered *fine*.
    ///
    /// **The headword comparison is not optional.** `DCSCopyRecordsForSearchString` matches
    /// fuzzily — a probe for `purple passage` comes back headed `passage` — so a returned record
    /// is a hit only when its headword *is* the word asked for. Taking non-empty records as a hit
    /// makes every dictionary answer every script, which is the same fuzzy-match trap the
    /// multi-word-expression probe already records.
    /// Whether a record's headword is the probe word.
    ///
    /// **A CJK headword carries its reading**, measured 2026-09-22: 牛津英汉汉英词典 answers 水 with the
    /// headword `水  shuǐ` and 譯典通 with `水  ㄕㄨㄟˇ`. Compared whole, both are misses and a
    /// bilingual reports itself as indexing Latin script alone — which is how this was found.
    ///
    /// So the comparison is against the headword's first whitespace-delimited token, never a
    /// prefix test: `hasPrefix` would accept *finest* for *fine*, which is the fuzzy match this
    /// exists to reject. Every probe word is a single token, so a first-token comparison keeps the
    /// rejection exact — `passage` is still not `purple passage`.
    static func matches(_ word: String, _ headword: String?) -> Bool {
        guard let first = headword?.components(separatedBy: .whitespacesAndNewlines)
            .first(where: { !$0.isEmpty })
        else { return false }
        return first.compare(word, options: .caseInsensitive) == .orderedSame
    }

    static func indexedScripts() -> [String: Set<ProbeScript>] {
        serial.withLock { _ in
            guard let api = try? API.loaded.get(), let dictionaries = try? api.dictionaries() else {
                return [:]
            }
            var found: [String: Set<ProbeScript>] = [:]
            for dictionary in dictionaries {
                guard let identity = try? api.identity(of: dictionary) else { continue }
                var scripts: Set<ProbeScript> = []
                for word in probeWords {
                    guard let script = ProbeScript.of(word), !scripts.contains(script) else { continue }
                    guard let records = try? api.records(for: word, in: dictionary),
                          !records.isEmpty
                    else { continue }
                    guard records.contains(where: { matches(word, api.headword(of: $0)) })
                    else { continue }
                    scripts.insert(script)
                }
                found[identity.key] = scripts
            }
            return found
        }
    }

    /// The service's answer to one lookup. Errors become typed `.failure` values, so the app
    /// can tell "nothing found" from "could not look", and why.
    public static func reply(to request: LookupRequest) -> LookupReply {
        do {
            let lookup = try entries(for: request.term)
            guard let entries = NonEmpty(lookup.entries) else { return .notFound }
            return .entries(entries, unreadable: lookup.unreadable)
        } catch {
            switch error {
            case .blankTerm: return .failure(.invalidRequest("the term is blank"))
            case .termTooLong(let characters):
                return .failure(.invalidRequest(
                    "the term is \(characters) characters; the most is \(LookupRequest.maximumLength)"))
            case .unavailable(let why): return .failure(.dictionaryServicesUnavailable(why))
            case .unreadable(let names): return .failure(.unreadableEntries(dictionaries: names))
            }
        }
    }

    /// Every entry every dictionary has for `term`, grouped under its dictionary, in the reader's
    /// dictionary order. A dictionary whose entry exists but cannot be read is named in
    /// `unreadable`; when that is every dictionary that had the term, the lookup fails rather than
    /// reporting "not found".
    ///
    /// Every record, not the first: NOAD files *fine* as four entries and *hold* as two, and the
    /// one the reader needed — the penalty, the ship's hold — is never the first
    /// (`dev-docs/study-unit.md` §2).
    /// Collapsing the copies is the last step, and it is a step rather than part of the walk so
    /// that `records(for:)` below stays available to say what the framework actually answered —
    /// which is what `recordsSharingAnEntryIDAreOneEntry` checks the collapse is entitled to
    /// assume.
    public static func entries(for term: String) throws(DictionaryBridgeError) -> DictionaryLookup {
        let answered = try records(for: term)
        return DictionaryLookup(
            entries: DictionaryEntry.collapsingRepeatedRecords(answered.entries),
            unreadable: answered.unreadable)
    }

    /// Every record every dictionary answered with, as the framework gave them — **including the
    /// several a dictionary returns for one entry** when it indexes that entry under several
    /// headwords, which is the one thing `entries(for:)` exists to take away. So this is not an
    /// answer to give a reader: it is what the collapse is measured against, and the only callers
    /// are `entries(for:)` and the test that checks those copies really are one entry.
    static func records(for term: String) throws(DictionaryBridgeError) -> DictionaryLookup {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .blankTerm }
        // The service is the boundary: `XiaolaiDict --lookup`, and any future caller, bypass the app's
        // own limit. A passage is not a lookup, and the private API gets no chance to choke on one.
        guard trimmed.count <= LookupRequest.maximumLength else { throw .termTooLong(characters: trimmed.count) }
        return try serial.withLock { _ throws(DictionaryBridgeError) in
            let api = try API.loaded.get()
            var entries: [DictionaryEntry] = []
            var unreadable: [String] = []
            for dictionary in try api.dictionaries() {
                let records = try api.records(for: trimmed, in: dictionary)
                guard !records.isEmpty else { continue }
                let identity = try api.identity(of: dictionary)
                var readable = 0
                for record in records {
                    guard let styled = api.styledDocument(of: record) else { continue }
                    readable += 1
                    entries.append(DictionaryEntry(
                        dictionary: identity, headword: api.headword(of: record), lookedUp: trimmed,
                        html: styled.html, document: styled.document))
                }
                // Named once per dictionary, however many of its records failed: the reader is told
                // this dictionary had the term and could not show it, not how many times.
                if readable < records.count { unreadable.append(identity.name) }
            }
            if entries.isEmpty, !unreadable.isEmpty { throw .unreadable(dictionaries: unreadable) }
            return DictionaryLookup(entries: entries, unreadable: unreadable)
        }
    }

    static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"

    /// A dictionary bundle's content version, read once per bundle per process — a plist read per
    /// lookup, across seven dictionaries, would be seven file reads on a path with a 1 s budget.
    private static let facts = Mutex<[String: BundleFacts]>([:])

    /// What one read of a bundle's `Info.plist` yields. Both together because it is one file: a
    /// second read for the languages would double a cost this cache exists to pay once.
    struct BundleFacts: Sendable, Equatable {
        var version: String?
        var languages: [DictionaryLanguages]
    }

    static func facts(ofBundleAt bundle: URL) -> BundleFacts {
        facts.withLock { cache in
            if let known = cache[bundle.path] { return known }
            let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
            let declared = plist?["DCSDictionaryLanguages"] as? [[String: Any]] ?? []
            let languages = declared.compactMap { pair -> DictionaryLanguages? in
                // Both keys or nothing. A half-declared pair cannot answer "indexes English and
                // explains in mine", and inventing the missing half is how a wrong dictionary
                // becomes the confident proposal.
                guard let index = pair["DCSDictionaryIndexLanguage"] as? String,
                      let explains = pair["DCSDictionaryDescriptionLanguage"] as? String
                else { return nil }
                return DictionaryLanguages(index: index, explains: explains)
            }
            let read = BundleFacts(
                version: plist?["CFBundleShortVersionString"] as? String, languages: languages)
            cache[bundle.path] = read
            return read
        }
    }

    static func version(ofBundleAt bundle: URL) -> String? { facts(ofBundleAt: bundle).version }

    /// `document` with the XHTML namespace declared on its root. The dictionaries declare only
    /// their own `d:` namespace there, and parsed as XML — which the panel must do, or the `d:`
    /// elements lose the namespace their stylesheets select on — a root outside the XHTML namespace
    /// is not HTML: `style` shows as text and nothing is laid out. A root that already declares a
    /// default namespace, and text with no `html` root, are returned as they are.
    static func renderable(_ document: String) -> String {
        guard let open = document.range(of: #"<html(?=[\s>/])"#, options: .regularExpression),
              let close = document[open.upperBound...].firstIndex(of: ">"),
              document[open.upperBound..<close].range(of: #"\sxmlns\s*="#, options: .regularExpression) == nil
        else { return document }
        return document.replacingCharacters(in: open, with: "<html xmlns=\"\(xhtmlNamespace)\"")
    }

    /// Whether `document` is what the styled form promises: a well-formed XHTML document — the
    /// panel parses it as XML, so anything less renders as an error page — whose root is `html` in
    /// the XHTML namespace, with the dictionary's stylesheet inlined: an XHTML `style` element
    /// holding at least one whole rule, a selector and a `property: value` block, not merely the tag
    /// or a stray brace. Blank text, plain text, a document outside the XHTML namespace, or the
    /// bare entry of another form after an ABI change all fail.
    ///
    /// The same walk that reads the entry's structure, because walking a 625 KB entry twice costs a
    /// quarter of a second the lookup does not have; `styledDocument(of:)` keeps the result.
    static func isStyledDocument(_ document: String) -> Bool {
        EntryDocument.parse(document)?.isStyled ?? false
    }
}

/// The resolved private symbols. Loaded once; a missing symbol fails every call loudly rather than
/// being looked up again, or worse, called through a null pointer.
///
/// `@unchecked Sendable`: C function pointers and a dlopen handle, never mutated once loaded. That
/// makes sharing the pointers safe; it says nothing about calling through them concurrently, which
/// `DictionaryBridge.serial` prevents.
private struct API: @unchecked Sendable {
    typealias ActiveDictionaries = @convention(c) () -> Unmanaged<CFArray>?
    typealias DictionaryName = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    typealias RecordsForSearchString =
        @convention(c) (CFTypeRef?, CFString, UnsafeRawPointer?, UnsafeRawPointer?) -> Unmanaged<CFArray>?
    typealias DictionaryIdentifier = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    typealias DictionaryURL = @convention(c) (CFTypeRef) -> Unmanaged<CFURL>?
    typealias RecordHeadword = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    typealias RecordCopyData = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFString>?

    /// `DCSRecordCopyData`'s second argument selects the form. Probed: 0 is the bare entry XHTML,
    /// 1 a complete document with the dictionary's stylesheet inlined, 3 plain text. The design
    /// note's code called it with one argument, which returned form 0 only because the unset
    /// argument register happened to hold zero.
    static let styledDocumentForm = 1

    let activeDictionaries: ActiveDictionaries
    let dictionaryName: DictionaryName
    let dictionaryIdentifier: DictionaryIdentifier
    let dictionaryURL: DictionaryURL
    let recordsForSearchString: RecordsForSearchString
    let recordHeadword: RecordHeadword
    let recordCopyData: RecordCopyData

    static let loaded: Result<API, DictionaryBridgeError> = load()

    private static func load() -> Result<API, DictionaryBridgeError> {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let handle = dlopen(path, RTLD_NOW) else {
            return .failure(.unavailable("cannot load DictionaryServices: \(String(cString: dlerror()))"))
        }
        func symbol<T>(_ name: String, as _: T.Type) throws(DictionaryBridgeError) -> T {
            guard let pointer = dlsym(handle, name) else { throw .unavailable("DictionaryServices has no \(name)") }
            return unsafeBitCast(pointer, to: T.self)
        }
        do throws(DictionaryBridgeError) {
            // The handle is kept for the life of the process on success: the pointers point into it.
            return .success(API(
                activeDictionaries: try symbol("DCSGetActiveDictionaries", as: ActiveDictionaries.self),
                dictionaryName: try symbol("DCSDictionaryGetName", as: DictionaryName.self),
                dictionaryIdentifier: try symbol("DCSDictionaryGetIdentifier", as: DictionaryIdentifier.self),
                dictionaryURL: try symbol("DCSDictionaryGetURL", as: DictionaryURL.self),
                recordsForSearchString: try symbol("DCSCopyRecordsForSearchString", as: RecordsForSearchString.self),
                recordHeadword: try symbol("DCSRecordGetHeadword", as: RecordHeadword.self),
                recordCopyData: try symbol("DCSRecordCopyData", as: RecordCopyData.self)))
        } catch {
            dlclose(handle)
            return .failure(error)
        }
    }

    // "Get" functions return borrowed references, "Copy" functions owned ones.

    /// Nil, or anything but an array, is the API failing — not "no dictionaries", which would turn
    /// a broken framework into a confident "not found" and skip the public fallback.
    func dictionaries() throws(DictionaryBridgeError) -> [CFTypeRef] {
        guard let array = activeDictionaries()?.takeUnretainedValue() else {
            throw .unavailable("DCSGetActiveDictionaries returned nothing")
        }
        return try Self.list(array, from: "DCSGetActiveDictionaries")
    }

    /// A dictionary without a name is private-API drift, not a dictionary to show as "Unnamed".
    func name(of dictionary: CFTypeRef) throws(DictionaryBridgeError) -> String {
        guard let name = dictionaryName(dictionary)?.takeUnretainedValue() as String?,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .unavailable("DCSDictionaryGetName returned no name") }
        return name
    }

    /// Which dictionary this is, by identifier and content version as well as by display name.
    ///
    /// `DCSDictionaryGetIdentifier` answers `com.apple.dictionary.NOAD` for Apple's assets and an
    /// **empty string** for a sideloaded conversion — measured on all three enabled here — so empty
    /// is read as "has none" rather than stored as an identifier of "".
    ///
    /// There is no `DCSDictionaryGetVersion`: the version comes from the bundle's own Info.plist,
    /// reached through `DCSDictionaryGetURL`. That is a file read, so it is done once per
    /// dictionary per process rather than once per lookup.
    func identity(of dictionary: CFTypeRef) throws(DictionaryBridgeError) -> DictionaryIdentity {
        let name = try name(of: dictionary)
        let identifier = dictionaryIdentifier(dictionary)?.takeUnretainedValue() as String?
        let bundle = dictionaryURL(dictionary)?.takeUnretainedValue() as URL?
        return DictionaryIdentity(
            name: name,
            identifier: identifier?.isEmpty == false ? identifier : nil,
            version: bundle.flatMap { DictionaryBridge.version(ofBundleAt: $0) })
    }

    /// What the bundle declares about its languages, through the same cached plist read the
    /// version comes from. Empty when the bundle declares nothing, which is every sideloaded
    /// conversion measured here.
    func languages(of dictionary: CFTypeRef) -> [DictionaryLanguages] {
        guard let bundle = dictionaryURL(dictionary)?.takeUnretainedValue() as URL? else { return [] }
        return DictionaryBridge.facts(ofBundleAt: bundle).languages
    }

    /// Always one explicit dictionary. Passing NULL — "every dictionary" before macOS 26 — segfaults
    /// now, and it is what effectively every published sample for this API does. Empty means the
    /// dictionary has no record for the term.
    ///
    /// Every record it returns, in its own order: a dictionary answers *fine* with one record per
    /// homograph, and the reader's meaning is rarely the first.
    func records(for term: String, in dictionary: CFTypeRef) throws(DictionaryBridgeError) -> [CFTypeRef] {
        guard let records = recordsForSearchString(dictionary, term as CFString, nil, nil)?.takeRetainedValue() else {
            return []
        }
        return try Self.list(records, from: "DCSCopyRecordsForSearchString")
    }

    func headword(of record: CFTypeRef) -> String? {
        recordHeadword(record)?.takeUnretainedValue() as String?
    }

    /// The record's document and the single parse of it, or nil when the document cannot be had or
    /// is not what form 1 promises. The parse is returned rather than repeated: it is how the
    /// styled form is checked, and it carries the entry's id.
    func styledDocument(of record: CFTypeRef) -> (html: String, document: EntryDocument)? {
        guard let text = recordCopyData(record, Self.styledDocumentForm)?.takeRetainedValue() as String? else { return nil }
        let renderable = DictionaryBridge.renderable(text)
        guard let parsed = EntryDocument.parse(renderable), parsed.isStyled else { return nil }
        return (renderable, parsed)
    }

    /// The pointer is typed as a CFArray only because that is what the symbol is believed to
    /// return; checked, not trusted.
    private static func list(_ object: CFArray, from function: String) throws(DictionaryBridgeError) -> [CFTypeRef] {
        guard CFGetTypeID(object) == CFArrayGetTypeID() else {
            throw .unavailable("\(function) returned something other than an array")
        }
        return object as [CFTypeRef]
    }
}
