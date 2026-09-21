import Foundation
import Testing

@testable import XiaolaiDictUI

/// What the About pane is allowed to say about this build.
///
/// The version is declared in two tracked plists and `build-bundle.sh` fails when they disagree.
/// A view that typed one out would be a third declaration with nothing checking it — and the one
/// the reader actually sees. So the only thing tested here is that it reads what it is given and
/// refuses to invent anything.
struct AppReleaseTests {
    @Test func itReadsTheVersionAndTheBuildItIsGiven() throws {
        let release = try #require(AppRelease(infoDictionary: [
            "CFBundleShortVersionString": "0.0.2", "CFBundleVersion": "2026.921.101500",
        ]))
        #expect(release.version == "0.0.2")
        #expect(release.build == "2026.921.101500")
    }

    /// The build is bracketed because it names nothing: two builds of 0.0.2 are both 0.0.2, and
    /// this is the only thing that tells them apart.
    @Test func theLabelCarriesBoth() throws {
        let release = try #require(AppRelease(infoDictionary: [
            "CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "97",
        ]))
        #expect(release.label == "Version 1.4.0 (97)")
    }

    /// **Nothing is invented.** A bundle that declares no version gives no release, and the pane
    /// draws no version line — rather than printing "unknown", which claims to have looked and
    /// found that answer.
    @Test func aBundleThatDeclaresNothingGivesNothing() {
        #expect(AppRelease(infoDictionary: nil) == nil)
        #expect(AppRelease(infoDictionary: [:]) == nil)
        #expect(AppRelease(infoDictionary: ["CFBundleShortVersionString": "0.0.2"]) == nil)
        #expect(AppRelease(infoDictionary: ["CFBundleVersion": "12"]) == nil)
    }

    /// An empty string is a declaration of nothing, and reads as one. "Version  ()" on a settings
    /// pane is the shape a missing value takes when only `nil` was guarded against.
    @Test func anEmptyVersionIsNotAVersion() {
        #expect(AppRelease(infoDictionary: [
            "CFBundleShortVersionString": "", "CFBundleVersion": "12",
        ]) == nil)
        #expect(AppRelease(infoDictionary: [
            "CFBundleShortVersionString": "0.0.2", "CFBundleVersion": "",
        ]) == nil)
    }
}
