/// Where a word was read, as precisely as the app could say.
///
/// Three separate coordinates, not one. **Most apps can say nothing at all** — 12 of the 17 running
/// when this was measured — so the record carries how precisely it knows the place, and a page URL
/// never shares a column with a file. Today's single `source_url` stored a local HTML page open in
/// Safari and a file open in an editor identically, and nothing downstream could tell them apart
/// (`dev-docs/where-a-word-was-read.md` §2).
public struct ReadingPlace: Codable, Sendable, Equatable {
    /// How precisely the place is known. The same principle as `CaptureQuality`: a lookup that
    /// knows only the app must not render as confidently as one that knows the page.
    public enum Precision: String, Codable, Sendable, CaseIterable {
        /// A page URL, which reopens as it is.
        case page
        /// A file the app named. It does not survive the file being moved or renamed — a bookmark
        /// would, and is a later addition; the column is the part that cannot be backfilled.
        case document
        /// Only the app, relaunchable by bundle identifier. The ordinary case.
        case appOnly
    }

    /// The app's bundle identifier.
    public let bundleID: String?
    /// The app's display name. `com.colliderli.iina` is not an answer to "where did I read this".
    public let name: String?
    /// The window's `AXDocument` — a file URL.
    public let document: String?
    /// The web area's `AXURL` — a page URL. Never the same field as `document`.
    public let page: String?
    /// The window title with the app-name suffix stripped: the only human-readable label. The web
    /// area's own title is empty in Safari, so it comes from the window.
    public let title: String?
    /// The title as the window gave it. Kept beside the stripped one because stripping is a
    /// heuristic — Chrome appends " - Google Chrome" — and a heuristic's input is worth keeping.
    public let rawTitle: String?

    public init(
        bundleID: String? = nil, name: String? = nil, document: String? = nil,
        page: String? = nil, title: String? = nil, rawTitle: String? = nil
    ) {
        self.bundleID = bundleID
        self.name = name
        self.document = document
        self.page = page
        self.title = title
        self.rawTitle = rawTitle
    }

    /// Derived, never stored twice: a precision that could drift from the fields it describes would
    /// be the cache this project's memory rules ban.
    public var precision: Precision {
        if page != nil { return .page }
        if document != nil { return .document }
        return .appOnly
    }

    /// What review shows: the title where there is one, else the file name, else the host, else the
    /// app — degrading in the same order as `precision`.
    public var label: String? {
        if let title, !title.isEmpty { return title }
        if let document, let name = document.split(separator: "/").last { return String(name).removingPercentEncoding }
        if let page, let host = URLHost.of(page) { return host }
        return name
    }
}

/// The host of a URL string — the **host alone**.
///
/// Not the authority: `https://alice:secret@example.com/page` has an authority of
/// `alice:secret@example.com`, and this label is shown to the reader and stored in the ledger. A
/// "where did I read this" label is not a place to put someone's credentials.
enum URLHost {
    static func of(_ url: String) -> String? {
        guard let scheme = url.range(of: "://") else { return nil }
        let authority = url[scheme.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // Userinfo is everything before the last "@" — last, because a password may contain one.
        var host = authority
        if let at = authority.lastIndex(of: "@") { host = authority[authority.index(after: at)...] }
        // A port is not part of the host. IPv6 literals keep their brackets, so only a colon
        // *after* the closing bracket — or in a name with no bracket — is a port separator.
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") { host = host[...close] }
        } else if let colon = host.firstIndex(of: ":") {
            host = host[..<colon]
        }
        return host.isEmpty ? nil : String(host)
    }
}
