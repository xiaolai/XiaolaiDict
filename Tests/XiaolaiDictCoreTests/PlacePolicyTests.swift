import XiaolaiDictCore
import Testing

/// The exclusion list has to exist before the place columns are first written, not after, or the
/// first excluded app is already in the database (`dev-docs/where-a-word-was-read.md` §7).
struct PlacePolicyTests {
    private let page = ReadingPlace(
        bundleID: "com.1password.1password", name: "1Password", document: nil,
        page: "https://vault.example.com/item/42", title: "Bank — login", rawTitle: "Bank — login | 1Password")

    @Test func itShipsNonEmpty() {
        #expect(!PlacePolicy.shipped.excluded.isEmpty)
        #expect(PlacePolicy.shipped.excludes("com.1password.1password"))
    }

    /// The app is always recorded — that is how "in 1Password" gets said at all. Everything that
    /// locates a word *inside* it is not.
    @Test func anExcludedAppKeepsItsNameAndNothingElse() {
        let kept = PlacePolicy.shipped.applied(to: page)
        #expect(kept.bundleID == "com.1password.1password")
        #expect(kept.name == "1Password")
        #expect(kept.page == nil)
        #expect(kept.document == nil)
        #expect(kept.title == nil, "a window title can be the name of the item being looked at")
        #expect(kept.rawTitle == nil)
        #expect(kept.precision == .appOnly)
    }

    @Test func anOrdinaryAppIsUntouched() {
        let safari = ReadingPlace(
            bundleID: "com.apple.Safari", name: "Safari", document: nil,
            page: "https://example.com/", title: "Example", rawTitle: "Example")
        #expect(PlacePolicy.shipped.applied(to: safari) == safari)
    }

    /// An app that did not say who it is cannot be matched against a list of identifiers, and is
    /// not excluded by accident.
    @Test func anAppWithNoIdentifierIsNotExcluded() {
        #expect(!PlacePolicy.shipped.excludes(nil))
    }

    /// Messaging apps are the reader's call: excluding them silently would make "where did I read
    /// this" wrong without saying so.
    @Test func messagingAppsAreNotExcludedByDefault() {
        #expect(!PlacePolicy.shipped.excludes("com.tencent.xinWeChat"))
        #expect(PlacePolicy(excluded: ["com.tencent.xinWeChat"]).excludes("com.tencent.xinWeChat"))
    }
}

/// Found by audit: the label shown for a lookup is built from the URL, and a URL can carry
/// credentials. A "where did I read this" label is not a place to put someone's password.
struct ReadingPlaceLabelTests {
    private func label(page: String) -> String? {
        ReadingPlace(bundleID: "com.apple.Safari", name: "Safari", page: page).label
    }

    @Test func credentialsNeverReachTheLabel() {
        #expect(label(page: "https://alice:secret@example.com/page") == "example.com")
        #expect(label(page: "https://alice@example.com/page") == "example.com")
        // A password containing an "@" must not leave part of itself behind.
        #expect(label(page: "https://alice:p@ss@example.com/page") == "example.com")
    }

    @Test func aPortIsNotPartOfTheHost() {
        #expect(label(page: "http://example.com:8080/page") == "example.com")
        #expect(label(page: "https://alice:secret@example.com:8443/") == "example.com")
    }

    /// An IPv6 literal keeps its brackets; only a colon after the closing bracket is a port.
    @Test func anIPv6LiteralSurvives() {
        #expect(label(page: "http://[2001:db8::1]:8080/page") == "[2001:db8::1]")
        #expect(label(page: "http://[2001:db8::1]/page") == "[2001:db8::1]")
    }

    @Test func anOrdinaryURLIsUnchanged() {
        #expect(label(page: "https://example.com/a/b?c=d") == "example.com")
    }

    /// A title, where there is one, is still preferred over any of this.
    @Test func aTitleStillWins() {
        let place = ReadingPlace(
            bundleID: "com.apple.Safari", name: "Safari",
            page: "https://alice:secret@example.com/", title: "A page", rawTitle: "A page")
        #expect(place.label == "A page")
    }
}
