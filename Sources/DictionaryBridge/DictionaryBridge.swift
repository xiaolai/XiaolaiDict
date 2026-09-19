import Foundation
import XiaolaiDictCore
import Synchronization

/// A dictionary enabled in Dictionary.app's settings.
public struct InstalledDictionary: Sendable, Equatable {
    public let identity: DictionaryIdentity

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
    /// reader's dictionary order. A dictionary contributes as many as it has records.
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
                installed.append(InstalledDictionary(identity: try api.identity(of: dictionary)))
            }
            return installed
        }
    }

    /// The XPC service's answer to whatever the app asked.
    public static func reply(to request: ServiceRequest) -> ServiceReply {
        switch request {
        case .lookup(let lookup): .lookup(reply(to: lookup))
        case .dictionaries: .dictionaries(capabilities())
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
    public static func capabilities() -> [DictionaryCapability] {
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
            if let known = probed.withLock({ $0 }) { return known }   // another caller won the race
            var found: [DictionaryCapability] = []
            for dictionary in (try? activeDictionaries()) ?? [] {
                found.append(capability(of: dictionary.identity))
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

    private static func capability(of identity: DictionaryIdentity) -> DictionaryCapability {
        for word in probeWords {
            let entries = ((try? entries(for: word))?.entries ?? []).filter { $0.dictionary == identity }
            guard let best = entries.map(\.senseKeyKind).max() else { continue }
            return DictionaryCapability(identity: identity, senseKeyKind: best, probed: true)
        }
        return DictionaryCapability(identity: identity, senseKeyKind: SenseKeyKind.none, probed: false)
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
    public static func entries(for term: String) throws(DictionaryBridgeError) -> DictionaryLookup {
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
    private static let versions = Mutex<[String: String?]>([:])

    static func version(ofBundleAt bundle: URL) -> String? {
        versions.withLock { cache in
            if let known = cache[bundle.path] { return known }
            let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
            let version = plist?["CFBundleShortVersionString"] as? String
            cache[bundle.path] = version
            return version
        }
    }

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
