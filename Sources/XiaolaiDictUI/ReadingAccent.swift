import AppKit
import XiaolaiDictCore
import SwiftUI

/// One word's colour on its card, defined once per appearance **and per contrast setting**.
///
/// The shades are written down rather than derived from one another, because a single
/// saturation and brightness cannot serve both appearances: the depth that makes a hue read on a
/// near-white card is the same depth that makes it disappear on a dark one. The increased-contrast
/// pair is written down for the same reason — "the same colour, darker" is a decision per hue,
/// and blue needs far more of it than green does.
struct ReadingAccent: Equatable, Sendable {
    struct Shade: Equatable, Sendable {
        let saturation: Double
        let brightness: Double
    }

    /// 0..<1.
    let hue: Double
    let light: Shade
    let dark: Shade
    /// What the reader gets with Increase Contrast on: at least 7:1 against every card fill,
    /// where the ordinary shades are held to 4.5:1.
    let lightIncreased: Shade
    let darkIncreased: Shade

    func shade(in scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Shade {
        switch (scheme, contrast) {
        case (.dark, .increased): darkIncreased
        case (.dark, _): dark
        case (_, .increased): lightIncreased
        case (_, _): light
        }
    }

    /// The colour to draw with. Pass `@Environment(\.colorSchemeContrast)` — the default is for
    /// the callers that predate it, and a caller that leaves it out ignores Increase Contrast.
    func color(in scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) -> Color {
        let shade = shade(in: scheme, contrast: contrast)
        return Color(hue: hue, saturation: shade.saturation, brightness: shade.brightness)
    }

    /// The same four shades as one colour that follows the appearance it is drawn in, for the
    /// places that have no environment to read: AppKit, and a `static let`.
    var dynamicColor: Color {
        let accent = self
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // Asked of the workspace, not of the appearance. AppKit has high-contrast appearance
            // names, and it does not hand them to a colour's provider: measured 2026-10-02, drawing
            // under `NSAppearance(named: .accessibilityHighContrastAqua)` the provider was given
            // plain `aqua`. So the name cannot say whether Increase Contrast is on; this can.
            let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let shade = accent.shade(in: dark ? .dark : .light, contrast: increased ? .increased : .standard)
            return NSColor(hue: accent.hue, saturation: shade.saturation, brightness: shade.brightness, alpha: 1)
        })
    }
}

/// The colours the drawer tells words apart by.
enum ReadingPalette {
    /// **Seven curated colours, not a free hue.**
    ///
    /// This replaced `hue = hash % 360`, which had the shape of a solution and did not work: a free
    /// hue puts two words in the same drawer three degrees apart and calls them distinguishable, it
    /// lands some words on a yellow that vanishes against a light card, and its fixed brightness
    /// was written for one appearance. Seven is few enough that every pair is far apart — the gap
    /// is asserted, not eyeballed — and repeats at a distance cost nothing, because the colour was
    /// never an identifier. It is an aid to scanning.
    ///
    /// **Legibility is asserted too, since 2026-10-02.** The gap was and the contrast was not: five
    /// of the seven light shades measured under 4.5:1 on a white card (orange 3.29, teal 3.12,
    /// green 3.49, pink 3.99, blue 4.16), and three dark ones on the hover fill (indigo 3.29, red
    /// 3.44, pink 4.37) — for the marked word, which is regular-weight italic at body size.
    /// Every shade below reaches 4.5:1 on the worst fill of its appearance (light hover 0.945,
    /// dark hover 0.26) and every increased shade 7:1; `PaletteContrastTests` computes all of it.
    /// What that costs is stated rather than hidden: light orange is now nearer brown, and the
    /// dark increased shades of red, indigo and pink are pale enough to resemble one another.
    /// The colour was never an identifier, and a reader who asked for contrast asked for this.
    static let accents: [ReadingAccent] = [
        .init(hue: 0.99, light: .init(saturation: 0.72, brightness: 0.77),
              dark: .init(saturation: 0.41, brightness: 0.98),
              lightIncreased: .init(saturation: 0.72, brightness: 0.57),
              darkIncreased: .init(saturation: 0.17, brightness: 0.98)),   // red
        // 0.10 rather than 0.08: at 0.08 the gap to red was 0.0899999…, which is the assertion's
        // floor and under it. There is slack between here and green and none between here and red,
        // so the colour moves — widening the bound to fit would only have hidden a real crowding.
        .init(hue: 0.10, light: .init(saturation: 0.85, brightness: 0.58),
              dark: .init(saturation: 0.68, brightness: 0.95),
              lightIncreased: .init(saturation: 0.85, brightness: 0.43),
              darkIncreased: .init(saturation: 0.38, brightness: 0.98)),   // orange
        .init(hue: 0.35, light: .init(saturation: 0.78, brightness: 0.49),
              dark: .init(saturation: 0.60, brightness: 0.85),
              lightIncreased: .init(saturation: 0.78, brightness: 0.36),
              darkIncreased: .init(saturation: 0.60, brightness: 0.98)),   // green
        .init(hue: 0.48, light: .init(saturation: 0.82, brightness: 0.47),
              dark: .init(saturation: 0.62, brightness: 0.88),
              lightIncreased: .init(saturation: 0.82, brightness: 0.35),
              darkIncreased: .init(saturation: 0.62, brightness: 0.98)),   // teal
        .init(hue: 0.58, light: .init(saturation: 0.78, brightness: 0.70),
              dark: .init(saturation: 0.56, brightness: 0.98),
              lightIncreased: .init(saturation: 0.78, brightness: 0.51),
              darkIncreased: .init(saturation: 0.24, brightness: 0.98)),   // blue
        .init(hue: 0.72, light: .init(saturation: 0.68, brightness: 0.80),
              dark: .init(saturation: 0.35, brightness: 0.98),
              lightIncreased: .init(saturation: 0.68, brightness: 0.67),
              darkIncreased: .init(saturation: 0.15, brightness: 0.98)),   // indigo
        .init(hue: 0.89, light: .init(saturation: 0.64, brightness: 0.70),
              dark: .init(saturation: 0.44, brightness: 0.98),
              lightIncreased: .init(saturation: 0.64, brightness: 0.52),
              darkIncreased: .init(saturation: 0.18, brightness: 0.98)),   // pink
    ]

    /// What a lookup that found nothing is drawn with. A miss keeps its grey: the colour is for
    /// telling words apart, not for decorating a failure.
    ///
    /// **A grey that can be read.** It was `secondary` at 45%, which measured 1.71:1 on a light
    /// card and 2.2:1 on a dark one while being used as the headword's own colour in the Library.
    /// A miss is quieter than a word, not invisible: 4.5:1 like any other text, 7:1 increased.
    static let missAccent = ReadingAccent(
        hue: 0, light: .init(saturation: 0, brightness: 0.42), dark: .init(saturation: 0, brightness: 0.69),
        lightIncreased: .init(saturation: 0, brightness: 0.31), darkIncreased: .init(saturation: 0, brightness: 0.86))

    /// The miss grey for a caller with no scheme in hand. It follows the appearance it is drawn in;
    /// a view that has the environment should prefer `color(for:in:contrast:)`.
    static let miss = missAccent.dynamicColor

    /// Which accent a word gets, and the same one every time the drawer opens on any machine.
    ///
    /// FNV-1a rather than `Hasher`, whose seed changes per process — that would give every word a
    /// new colour on each launch, which reads as a bug rather than as a shuffle.
    static func index(for word: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in word.lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(accents.count))
    }

    /// Nil where the lookup found nothing, so the caller has to decide what a failure looks like
    /// rather than being handed a colour that says "this is a word like the others".
    static func accent(for entry: ReadingEntry) -> ReadingAccent? {
        guard entry.result == .found else { return nil }
        return accent(forLemma: entry.lemma)
    }

    /// **The accent of a word, keyed by its lemma — and by nothing else.**
    ///
    /// The key is the dictionary form: `meet` for *meeting*, *met* and *meets*. Every surface has
    /// to hand in the same key or the same reading changes colour between them, which is what
    /// happened: History keyed by lemma and drew *meeting* pink, Saved keyed by the surface form
    /// and drew the same reading orange, one click apart (measured 2026-10-01). So a row, a card
    /// and an inspector each carry an `accentKey` that is the lemma, and pass it here. Case does
    /// not matter; inflection does.
    static func accent(forLemma key: String) -> ReadingAccent {
        accents[index(for: key)]
    }

    /// The older spelling of `accent(forLemma:)`. It takes the same key and gives the same answer;
    /// the label is what was missing, because "word" is what let a surface form be passed.
    static func accent(for word: String) -> ReadingAccent {
        accent(forLemma: word)
    }

    /// The colour of a lemma, in one call: what a view writes when it has the environment.
    static func color(forLemma key: String, in scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        accent(forLemma: key).color(in: scheme, contrast: contrast)
    }

    /// The colour of a ledger row: its lemma's accent, or the miss grey where nothing was found.
    static func color(for entry: ReadingEntry, in scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        (accent(for: entry) ?? missAccent).color(in: scheme, contrast: contrast)
    }
}

/// The colours of a status glyph — the mark in front of a caution, an error, a guess.
///
/// Here rather than in `Token` for the reason the word accents are: a colour that has to hold a
/// contrast against the card is four written shades, not one value. **Held to 3:1**, the bar for a
/// graphic, because these tint a symbol and never text: the words beside the symbol are in the
/// ordinary label colour, which is the whole point — system orange as *text* measured about 2.2:1
/// on a light card (2026-10-01) and was carrying "this failed to save". Increased shades reach
/// 4.5:1. `StatusTintContrastTests` computes them.
enum StatusPalette {
    /// Something the reader should look at before going on. Amber.
    static let caution = ReadingAccent(
        hue: 0.09, light: .init(saturation: 0.95, brightness: 0.78), dark: .init(saturation: 0.70, brightness: 0.98),
        lightIncreased: .init(saturation: 0.95, brightness: 0.63), darkIncreased: .init(saturation: 0.70, brightness: 0.98))
    /// Something failed — and the colour of a control that destroys. Red.
    static let error = ReadingAccent(
        hue: 0.01, light: .init(saturation: 0.80, brightness: 0.85), dark: .init(saturation: 0.60, brightness: 0.98),
        lightIncreased: .init(saturation: 0.80, brightness: 0.79), darkIncreased: .init(saturation: 0.43, brightness: 0.98))
    /// Information that is not a warning: practice that schedules nothing. No hue at all.
    static let neutral = ReadingAccent(
        hue: 0, light: .init(saturation: 0, brightness: 0.50), dark: .init(saturation: 0, brightness: 0.60),
        lightIncreased: .init(saturation: 0, brightness: 0.42), darkIncreased: .init(saturation: 0, brightness: 0.69))
    /// A control that deletes or removes. The same red as an error on purpose: one red, one
    /// meaning — "this is the dangerous one".
    static let destructive = error
}
