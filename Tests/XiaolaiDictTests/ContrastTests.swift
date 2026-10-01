import AppKit
import SwiftUI
import Testing

@testable import XiaolaiDictUI

/// WCAG 2 contrast, computed from what the app would actually draw.
///
/// Through `NSColor` on purpose: the assertion is about the `Color` a view is handed, not about the
/// numbers the palette was written with, so a conversion that went wrong on the way is caught too.
enum WCAG {
    /// Relative luminance of an opaque sRGB colour.
    static func luminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) else { return .nan }
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }

    static func contrast(_ one: NSColor, _ other: NSColor) -> Double {
        let (a, b) = (luminance(one), luminance(other))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func contrast(_ one: Color, _ other: Color) -> Double {
        contrast(NSColor(one), NSColor(other))
    }

    /// `top` at `opacity` over an opaque `bottom`, which is what a wash or a translucent edge is.
    static func blend(_ top: Color, at opacity: Double, over bottom: Color) -> NSColor {
        guard let over = NSColor(top).usingColorSpace(.sRGB),
              let under = NSColor(bottom).usingColorSpace(.sRGB) else { return .clear }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * opacity + b * (1 - opacity) }
        return NSColor(
            srgbRed: mix(over.redComponent, under.redComponent),
            green: mix(over.greenComponent, under.greenComponent),
            blue: mix(over.blueComponent, under.blueComponent), alpha: 1)
    }
}

/// Every fill a word's colour is drawn on, by appearance.
enum CardFills {
    static func all(in scheme: ColorScheme) -> [(name: String, color: Color)] {
        [
            ("resting", CardSurface.fill(for: scheme, hovering: false)),
            ("hovered", CardSurface.fill(for: scheme, hovering: true)),
            ("panel", CardSurface.panel(for: scheme)),
        ]
    }
}

/// **The palette is legible, and this is what keeps it so.**
///
/// The hue gap was asserted and legibility was not: measured 2026-10-01, five of the seven light
/// shades were under 4.5:1 on a white card — orange 3.29, teal 3.12 — for the marked word, which is
/// regular-weight italic at body size and the one word on the card the reader has to find.
struct PaletteContrastTests {
    /// The helper is checked against the two answers everybody knows, so a wrong formula cannot
    /// pass the palette by being wrong the same way everywhere.
    @Test func theContrastFormulaAgreesWithTheStandard() {
        #expect(abs(WCAG.contrast(NSColor.white, NSColor.black) - 21) < 0.001)
        // #767676 on white is the textbook 4.54:1.
        let grey = NSColor(srgbRed: 0x76 / 255.0, green: 0x76 / 255.0, blue: 0x76 / 255.0, alpha: 1)
        #expect(abs(WCAG.contrast(grey, NSColor.white) - 4.54) < 0.01)
    }

    /// **The positive control**: the palette as it was on 2026-10-01 fails this check, so the check
    /// can fail. Orange at 0.85 / 0.76 on a white card measured 3.29.
    @Test func theOldOrangeWouldHaveFailed() {
        let old = Color(hue: 0.10, saturation: 0.85, brightness: 0.76)
        #expect(WCAG.contrast(old, CardSurface.fill(for: .light, hovering: false)) < 4.5)
    }

    /// Every accent, on every fill it is drawn on, in both appearances and at both contrast
    /// settings: 7 × 3 × 2 × 2. 4.5:1 ordinarily — the marked word is regular-weight body text —
    /// and 7:1 for a reader who turned on Increase Contrast.
    @Test func everyAccentReadsAsTextOnEveryFill() {
        var failures: [String] = []
        var checked = 0
        for (index, accent) in ReadingPalette.accents.enumerated() {
            for scheme in [ColorScheme.light, .dark] {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let bar = contrast == .increased ? 7.0 : 4.5
                    for fill in CardFills.all(in: scheme) {
                        let ratio = WCAG.contrast(accent.color(in: scheme, contrast: contrast), fill.color)
                        checked += 1
                        if ratio < bar {
                            failures.append(
                                "accent \(index) \(scheme) \(contrast) on \(fill.name): "
                                    + String(format: "%.2f", ratio))
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "under the bar — \(failures.joined(separator: "; "))")
        // Counted, because a loop over an empty palette passes: seven accents, three fills, two
        // appearances, two settings.
        #expect(checked == 84)
    }

    /// Increase Contrast must increase it — for every accent, in both appearances. A pair of
    /// shades written the wrong way round would pass the bars above for the hues with headroom.
    @Test func theIncreasedShadeIsNeverTheWeakerOne() {
        for accent in ReadingPalette.accents {
            for scheme in [ColorScheme.light, .dark] {
                let fill = CardSurface.fill(for: scheme, hovering: true)
                let standard = WCAG.contrast(accent.color(in: scheme, contrast: .standard), fill)
                let increased = WCAG.contrast(accent.color(in: scheme, contrast: .increased), fill)
                #expect(increased >= standard, "hue \(accent.hue) \(scheme): \(increased) < \(standard)")
            }
        }
    }

    /// The caller that predates the parameter still gets the ordinary shade.
    @Test func leavingContrastOutIsTheStandardShade() {
        for accent in ReadingPalette.accents {
            for scheme in [ColorScheme.light, .dark] {
                #expect(accent.color(in: scheme) == accent.color(in: scheme, contrast: .standard))
            }
        }
    }

    /// **A miss is quieter than a word, not invisible.** It was `secondary` at 45% — 1.71:1 on a
    /// light card — while being the headword's own colour in the Library.
    @Test func aMissIsStillText() {
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let bar = contrast == .increased ? 7.0 : 4.5
                let miss = ReadingPalette.missAccent.color(in: scheme, contrast: contrast)
                for fill in CardFills.all(in: scheme) {
                    let ratio = WCAG.contrast(miss, fill.color)
                    #expect(ratio >= bar, "miss \(scheme) \(contrast) on \(fill.name): \(ratio)")
                }
                #expect(NSColor(miss).usingColorSpace(.sRGB)?.saturationComponent == 0, "a miss wears no hue")
            }
        }
    }

    /// `ReadingPalette.miss` is the same grey for a caller with no environment, and it has to
    /// follow the appearance it is drawn in, or it is a light-mode colour.
    ///
    /// Light and dark only. Increase Contrast is read from the workspace — AppKit does not pass a
    /// high-contrast appearance to a colour's provider — and a test cannot turn the system
    /// setting on, so which of the two contrast shades is expected is asked the same way.
    @Test @MainActor func theUnscopedMissFollowsTheAppearance() throws {
        let contrast: ColorSchemeContrast =
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .increased : .standard
        var seen: [CGFloat] = []
        for (name, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light), (.darkAqua, .dark)] {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(ReadingPalette.miss).usingColorSpace(.sRGB)
            }
            let expected = try #require(
                NSColor(ReadingPalette.missAccent.color(in: scheme, contrast: contrast)).usingColorSpace(.sRGB))
            let brightness = try #require(resolved?.brightnessComponent)
            #expect(abs(brightness - expected.brightnessComponent) < 0.01, "\(name.rawValue)")
            seen.append(brightness)
        }
        #expect(abs(seen[0] - seen[1]) > 0.1, "one grey for both appearances: \(seen)")
    }

    /// The memory badge sets a digit in the word's colour on an 18% wash of the same colour, which
    /// is a darker ground than the card. Held to 3:1 — it is semibold, inside a capsule — and
    /// measured 2026-10-02 at 3.4 to 4.3. It was 2.5 for teal. Not 4.5: a surface that needs the
    /// digit read as body text should set it in the label colour.
    @Test func anAccentStillReadsOnItsOwnWash() {
        for (index, accent) in ReadingPalette.accents.enumerated() {
            for scheme in [ColorScheme.light, .dark] {
                let colour = accent.color(in: scheme)
                for fill in CardFills.all(in: scheme) {
                    let wash = WCAG.blend(colour, at: Token.Opacity.badgeWash, over: fill.color)
                    let ratio = WCAG.contrast(NSColor(colour), wash)
                    #expect(ratio >= 3, "accent \(index) \(scheme) on its wash over \(fill.name): \(ratio)")
                }
            }
        }
    }

    /// One lemma, one colour, whichever spelling of the call a surface uses — and an inflection
    /// is a different key, which is why a surface must pass the lemma and never the surface form.
    @Test func theAccentIsKeyedByLemma() {
        #expect(ReadingPalette.accent(forLemma: "meet") == ReadingPalette.accent(for: "meet"))
        #expect(ReadingPalette.accent(forLemma: "Meet") == ReadingPalette.accent(forLemma: "meet"))
        // The pair from the audit: History drew *meeting* by its lemma, Saved by its surface form.
        #expect(ReadingPalette.index(for: "meet") != ReadingPalette.index(for: "meeting"))
        #expect(
            ReadingPalette.color(forLemma: "meet", in: .light, contrast: .standard)
                == ReadingPalette.accent(forLemma: "meet").color(in: .light))
    }
}

/// The tints of a status glyph and of a destructive control, against the same fills.
struct StatusTintContrastTests {
    private static let tints: [(name: String, tint: ReadingAccent)] = [
        ("caution", StatusPalette.caution), ("error", StatusPalette.error),
        ("neutral", StatusPalette.neutral), ("destructive", StatusPalette.destructive),
    ]

    /// 3:1 for a graphic; 4.5:1 with Increase Contrast on.
    @Test func everyStatusTintReadsAsAGlyphOnEveryFill() {
        var checked = 0
        for (name, tint) in Self.tints {
            for scheme in [ColorScheme.light, .dark] {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let bar = contrast == .increased ? 4.5 : 3.0
                    for fill in CardFills.all(in: scheme) {
                        let ratio = WCAG.contrast(tint.color(in: scheme, contrast: contrast), fill.color)
                        checked += 1
                        #expect(ratio >= bar, "\(name) \(scheme) \(contrast) on \(fill.name): \(ratio)")
                    }
                }
            }
        }
        #expect(checked == 48)
    }

    /// **The positive control**, and the reason the view exists: system orange, as it was used for
    /// status text, does not reach even the glyph bar on a light card.
    @Test func systemOrangeWouldHaveFailed() {
        var ratio = 0.0
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            ratio = WCAG.contrast(NSColor.systemOrange, NSColor(CardSurface.fill(for: .light, hovering: false)))
        }
        #expect(ratio > 1 && ratio < 3, "system orange on a white card measured \(ratio)")
    }

    /// Every kind of status has a symbol that exists, a tint from the table above, and a name
    /// VoiceOver can say — and an error does not look like a caution.
    @Test func everyKindIsDrawnAndNamed() {
        for kind in StatusLabel.Kind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind)")
            #expect(Self.tints.contains { $0.tint == kind.tint }, "\(kind) is tinted outside the tested set")
            #expect(!String(localized: kind.spokenName).isEmpty)
        }
        #expect(Set(StatusLabel.Kind.allCases.map(\.symbol)).count == StatusLabel.Kind.allCases.count,
                "two kinds share a symbol, so only the tint tells them apart")
        #expect(StatusLabel.Kind.error.tint != StatusLabel.Kind.caution.tint)
    }

    /// Both card edges are lines a reader can see once they ask for contrast. The neutral edge
    /// at 12% is about 1.3:1, which is a hint; increased, it has to reach the glyph bar.
    @Test func bordersStrengthenWithIncreasedContrast() {
        #expect(ContrastAdaptation.neutralBorderOpacity(.increased) > ContrastAdaptation.neutralBorderOpacity(.standard))
        #expect(ContrastAdaptation.accentBorderOpacity(.increased) > ContrastAdaptation.accentBorderOpacity(.standard))
        #expect(ContrastAdaptation.neutralBorderOpacity(.standard) == Token.Opacity.border)
        #expect(ContrastAdaptation.accentBorderOpacity(.standard) == Token.Opacity.accentBorder)
        for (scheme, ink) in [(ColorScheme.light, Color.black), (.dark, .white)] {
            for fill in CardFills.all(in: scheme) {
                let edge = WCAG.blend(ink, at: ContrastAdaptation.neutralBorderOpacity(.increased), over: fill.color)
                #expect(WCAG.contrast(edge, NSColor(fill.color)) >= 3, "\(scheme) on \(fill.name)")
                let faint = WCAG.blend(ink, at: ContrastAdaptation.neutralBorderOpacity(.standard), over: fill.color)
                #expect(WCAG.contrast(faint, NSColor(fill.color)) < 3, "the control: the ordinary edge is a hint")
            }
        }
    }
}
