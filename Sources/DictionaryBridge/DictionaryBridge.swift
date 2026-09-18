import Foundation
import XiaolaiDictCore
import Synchronization

/// A dictionary enabled in Dictionary.app's settings.
public struct InstalledDictionary: Sendable, Equatable {
    public let name: String
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
    /// One per dictionary that had the term, in the reader's dictionary order.
    public let entries: [DictionaryEntry]
    /// Dictionaries that had the term but whose entry could not be read.
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
            for dictionary in try api.dictionaries() { installed.append(InstalledDictionary(name: try api.name(of: dictionary))) }
            return installed
        }
    }

    /// The XPC service's answer to a request. Errors become typed `.failure` values, so the app
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

    /// One entry per dictionary that has `term`, in the reader's dictionary order. A dictionary
    /// whose entry exists but cannot be read is named in `unreadable`; when that is every
    /// dictionary that had the term, the lookup fails rather than reporting "not found".
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
                guard let record = try api.firstRecord(for: trimmed, in: dictionary) else { continue }
                let name = try api.name(of: dictionary)
                guard let html = api.styledDocument(of: record) else {
                    unreadable.append(name)
                    continue
                }
                entries.append(DictionaryEntry(
                    dictionary: name, headword: api.headword(of: record), lookedUp: trimmed, html: html))
            }
            if entries.isEmpty, !unreadable.isEmpty { throw .unreadable(dictionaries: unreadable) }
            return DictionaryLookup(entries: entries, unreadable: unreadable)
        }
    }

    /// Whether `document` is what the styled form promises: a well-formed XHTML document — the
    /// panel parses it as XML, so anything less renders as an error page — rooted at `html`, with
    /// the dictionary's stylesheet inlined: a `style` element holding at least one whole rule, a
    /// selector and a `property: value` block, not merely the tag or a stray brace. Blank text, plain
    /// text, or the bare entry of another form after an ABI change all fail.
    static func isStyledDocument(_ document: String) -> Bool {
        let parser = XMLParser(data: Data(document.utf8))
        let inspector = DocumentInspector()
        parser.delegate = inspector
        guard parser.parse(), inspector.root == "html" else { return false }
        // Comments first: a rule inside one is not a rule.
        let rules = inspector.stylesheet.replacingOccurrences(of: #"/\*[\s\S]*?(\*/|$)"#, with: " ", options: .regularExpression)
        return rules.range(of: #"[^{}\s][^{}]*\{[^{}]*[\w-]\s*:[^{}]*\S[^{}]*\}"#, options: .regularExpression) != nil
    }
}

/// Collects what `isStyledDocument` checks, by local name: entries use Apple's `d:` namespace.
private final class DocumentInspector: NSObject, XMLParserDelegate {
    var root: String?
    /// The text of every `style` element.
    var stylesheet = ""
    private var styleDepth = 0

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        if root == nil { root = Self.local(name) }
        if Self.local(name) == "style" { styleDepth += 1 }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if Self.local(name) == "style" { styleDepth -= 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 { stylesheet += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if styleDepth > 0 { stylesheet += String(decoding: block, as: UTF8.self) }
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
    typealias RecordHeadword = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    typealias RecordCopyData = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFString>?

    /// `DCSRecordCopyData`'s second argument selects the form. Probed: 0 is the bare entry XHTML,
    /// 1 a complete document with the dictionary's stylesheet inlined, 3 plain text. The design
    /// note's code called it with one argument, which returned form 0 only because the unset
    /// argument register happened to hold zero.
    static let styledDocumentForm = 1

    let activeDictionaries: ActiveDictionaries
    let dictionaryName: DictionaryName
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

    /// Always one explicit dictionary. Passing NULL — "every dictionary" before macOS 26 — segfaults
    /// now, and it is what effectively every published sample for this API does. Nil means the
    /// dictionary has no record for the term.
    func firstRecord(for term: String, in dictionary: CFTypeRef) throws(DictionaryBridgeError) -> CFTypeRef? {
        guard let records = recordsForSearchString(dictionary, term as CFString, nil, nil)?.takeRetainedValue() else {
            return nil
        }
        return try Self.list(records, from: "DCSCopyRecordsForSearchString").first
    }

    func headword(of record: CFTypeRef) -> String? {
        recordHeadword(record)?.takeUnretainedValue() as String?
    }

    /// Nil when the record's document cannot be had, or is not the styled document form 1 promises.
    func styledDocument(of record: CFTypeRef) -> String? {
        guard let document = recordCopyData(record, Self.styledDocumentForm)?.takeRetainedValue() as String?,
              DictionaryBridge.isStyledDocument(document)
        else { return nil }
        return document
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
