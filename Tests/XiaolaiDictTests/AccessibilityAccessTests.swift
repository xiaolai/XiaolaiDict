import ApplicationServices
import Foundation
import Synchronization
import Testing

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// One owner for the Accessibility grant, the way `ScreenRecordingAccess` is one owner for the
/// other. Three call sites asked three different ways before this.
struct AccessibilityAccessTests {
    private func access(
        _ found: PermissionProbe, grantedByAsking: Bool = false
    ) -> (AccessibilityAccess, Counter) {
        let counter = Counter()
        return (AccessibilityAccess(
            probe: { found },
            request: { counter.bump(); return grantedByAsking }), counter)
    }

    /// Checked `Sendable`, with a lock, for the reason `ScreenRecordingAccessTests` gives its own:
    /// `@unchecked` would assert a safety nothing provides the moment a test stops awaiting one call.
    final class Counter: Sendable {
        private let count = Mutex(0)
        var asks: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    @Test func aGrantedPermissionIsNeverAskedFor() {
        let (permission, counter) = access(.granted)
        #expect(permission.ensure() == .granted)
        #expect(permission.granted())
        #expect(counter.asks == 0, "a granted permission must not raise a prompt")
    }

    @Test func aDeclinedPermissionAsksAndIsAllowedWhenTheReaderAgrees() {
        let (permission, counter) = access(.declined, grantedByAsking: true)
        #expect(permission.ensure() == .granted)
        #expect(counter.asks == 1)
    }

    @Test func aDeclinedPermissionStaysDeclinedWhenTheReaderRefuses() {
        let (permission, counter) = access(.declined, grantedByAsking: false)
        #expect(permission.ensure() == .declined)
        #expect(counter.asks == 1)
    }

    /// **`couldNotTell` never prompts and never reads as granted.** It cannot arise from
    /// `AXIsProcessTrusted()` today, which is exactly why it is worth pinning: a gate written as
    /// `!= .granted` would prompt on it, and one written as `!= .declined` would let a capture
    /// through. The sibling permission learned this the expensive way — a dialog on a Mac granted
    /// three days earlier, with nothing in the TCC database changing.
    @Test func anUnreadableProbeNeitherPromptsNorPasses() {
        let (permission, counter) = access(.couldNotTell)
        #expect(permission.ensure() == .couldNotTell)
        #expect(!permission.granted())
        #expect(counter.asks == 0)
    }

    /// **Hover never prompts, however the probe answers.** `granted()` is what
    /// `ScreenWordReader.target` reads on every pointer rest; a prompt there is a dialog attached to
    /// nothing the reader asked for, which is the rule `ScreenRecordingAccess.ensure()` already
    /// keeps for the other permission.
    @Test func theHoverGateNeverPrompts() {
        for found: PermissionProbe in [.granted, .declined, .couldNotTell] {
            let (permission, counter) = access(found, grantedByAsking: true)
            _ = permission.granted()
            #expect(counter.asks == 0, "hover prompted on \(found)")
        }
    }

    /// **The literal the SDK will not let Swift read, read out of the framework instead.**
    ///
    /// `Permissions.swift` said of this string, in one comment, that "a test holds the two equal",
    /// and in another, 145 lines below, that "there is no compile-time check of this string and no
    /// test that can make one… If this ever needs proving, the route is `dlsym` against the
    /// framework at runtime — deliberately not taken for one string." The first was false: no such
    /// test existed. The second was measured on 2026-09-26 and is now this.
    ///
    /// **It has to be a `dlopen` of the framework; `RTLD_DEFAULT` does not find it.** A first
    /// attempt answers "no symbol", which reads as confirmation that the route is closed. It is not
    /// closed — the symbol is a `CFStringRef` global in HIServices, so the handle points at the
    /// pointer and one dereference gives the string.
    @Test func theAccessibilityPromptKeyIsTheFrameworksOwn() throws {
        let framework = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        let handle = try #require(dlopen(framework, RTLD_LAZY), "could not open \(framework)")
        defer { dlclose(handle) }
        let symbol = try #require(dlsym(handle, "kAXTrustedCheckOptionPrompt"),
                                  "the SDK no longer exports kAXTrustedCheckOptionPrompt")
        // The symbol is a `CFStringRef` global, so the handle points at the pointer: one
        // dereference gives the string. `#require` on the dereference itself confuses the macro,
        // which reads `.pointee` as optional chaining — bound first.
        let stored: CFString? = symbol.assumingMemoryBound(to: CFString?.self).pointee
        let constant = try #require(stored, "kAXTrustedCheckOptionPrompt is exported but null")
        #expect(Permission.promptKey == constant as String, """
            the prompt key has drifted from the framework's own constant. A mistyped key is not an \
            error: AXIsProcessTrustedWithOptions simply never prompts, and the reader is left on a \
            permission screen that does nothing.
            """)
    }
}
