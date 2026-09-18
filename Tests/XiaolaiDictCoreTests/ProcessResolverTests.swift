import XiaolaiDictCore
import Testing

/// On macOS 27 `NSWorkspace` reports Safari — launched from a system cryptex — with process ID -1,
/// and an Accessibility element built from -1 is invalid. Its windows belong to the real process.
struct ProcessResolverTests {
    private let safari = "com.apple.Safari"

    @Test func aValidReportedIDIsTrusted() {
        #expect(ProcessResolver.pid(reported: 412, bundleID: safari, windowOwners: []) == 412)
    }

    @Test func anInvalidIDIsResolvedThroughTheAppsWindows() {
        let owners = [WindowOwner(pid: 9139, bundleID: safari)]
        #expect(ProcessResolver.pid(reported: -1, bundleID: safari, windowOwners: owners) == 9139)
    }

    /// Windows arrive front to back; another app's floating window may be first.
    @Test func windowsOfOtherAppsAreSkipped() {
        let owners = [WindowOwner(pid: 77, bundleID: "com.xiaolaidict"), WindowOwner(pid: 9139, bundleID: safari)]
        #expect(ProcessResolver.pid(reported: -1, bundleID: safari, windowOwners: owners) == 9139)
    }

    @Test func noMatchingWindowMeansNoProcess() {
        let owners = [WindowOwner(pid: 77, bundleID: "com.xiaolaidict")]
        #expect(ProcessResolver.pid(reported: -1, bundleID: safari, windowOwners: owners) == nil)
    }

    /// Without a bundle identifier there is nothing to confirm a window's owner against, and
    /// guessing would read the selection of the wrong app.
    @Test func anInvalidIDWithoutABundleIdentifierIsNotGuessed() {
        let owners = [WindowOwner(pid: 9139, bundleID: safari)]
        #expect(ProcessResolver.pid(reported: -1, bundleID: nil, windowOwners: owners) == nil)
    }
}
