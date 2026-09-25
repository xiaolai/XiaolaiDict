import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictUI
import XiaolaiDictTestSupport

/// How much of what is behind the history drawer comes through it — the reader's choice.
///
/// Frosted glass over a dark, uniform window is flat grey: measured at (133, 133, 133) over black,
/// the exact value of the drawer on a reader's screen while it docked over a black terminal. It
/// was working and looked broken. Which glass reads well depends on what is usually behind the
/// drawer, and that is the reader's to know, so it is a setting rather than a constant.
@MainActor
struct DrawerGlassTests {
    /// The drawer as it shipped, for everyone who has not chosen.
    @Test func aReaderWhoHasNeverChosenGetsFrosted() {
        #expect(AppearanceStore(defaults: TemporaryDefaults.suite()).loadDrawerGlass() == .frosted)
        #expect(DrawerGlass.standard == .frosted)
    }

    @Test func aChosenGlassSurvivesTheNextLaunch() {
        let defaults = TemporaryDefaults.suite()
        AppearanceStore(defaults: defaults).save(DrawerGlass.clear)
        #expect(AppearanceStore(defaults: defaults).loadDrawerGlass() == .clear)
    }

    /// A value a later version wrote, or a hand-edited one, is the default — never a failure.
    @Test func anUnrecognisedGlassFallsBackToFrosted() {
        let defaults = TemporaryDefaults.suite()
        defaults.set("stained", forKey: AppearanceStore.drawerGlassKey)
        #expect(AppearanceStore(defaults: defaults).loadDrawerGlass() == .frosted)
    }

    /// Changed in Settings, it is saved at once — not only on a clean quit.
    @Test func choosingItInSettingsSavesIt() {
        let defaults = TemporaryDefaults.suite()
        let appearance = Appearance(store: AppearanceStore(defaults: defaults))
        appearance.drawerGlass = .clear
        #expect(Appearance(store: AppearanceStore(defaults: defaults)).drawerGlass == .clear)
    }

    /// Each choice is SwiftUI's own style, not an approximation of one.
    @Test func eachChoiceIsSwiftUIsOwnGlass() {
        #expect(DrawerGlass.frosted.glass == .regular)
        #expect(DrawerGlass.clear.glass == .clear)
    }

    @Test func everyChoiceIsNamed() {
        for choice in DrawerGlass.allCases { #expect(!choice.label.isEmpty) }
    }
}
