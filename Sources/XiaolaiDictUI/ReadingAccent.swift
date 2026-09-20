import XiaolaiDictCore
import SwiftUI

/// One word's colour on its card, defined once per appearance.
///
/// Both shades are written down rather than derived from one another, because a single
/// saturation and brightness cannot serve both: the depth that makes a hue read on a near-white
/// card is the same depth that makes it disappear on a dark one.
struct ReadingAccent: Equatable, Sendable {
    struct Shade: Equatable, Sendable {
        let saturation: Double
        let brightness: Double
    }

    /// 0..<1.
    let hue: Double
    let light: Shade
    let dark: Shade

    func color(in scheme: ColorScheme) -> Color {
        let shade = scheme == .dark ? dark : light
        return Color(hue: hue, saturation: shade.saturation, brightness: shade.brightness)
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
    static let accents: [ReadingAccent] = [
        .init(hue: 0.99, light: .init(saturation: 0.72, brightness: 0.80),
              dark: .init(saturation: 0.55, brightness: 0.95)),   // red
        // 0.10 rather than 0.08: at 0.08 the gap to red was 0.0899999…, which is the assertion's
        // floor and under it. There is slack between here and green and none between here and red,
        // so the colour moves — widening the bound to fit would only have hidden a real crowding.
        .init(hue: 0.10, light: .init(saturation: 0.85, brightness: 0.76),
              dark: .init(saturation: 0.68, brightness: 0.95)),   // orange
        .init(hue: 0.35, light: .init(saturation: 0.78, brightness: 0.62),
              dark: .init(saturation: 0.60, brightness: 0.85)),   // green
        .init(hue: 0.48, light: .init(saturation: 0.82, brightness: 0.64),
              dark: .init(saturation: 0.62, brightness: 0.88)),   // teal
        .init(hue: 0.58, light: .init(saturation: 0.78, brightness: 0.80),
              dark: .init(saturation: 0.58, brightness: 0.98)),   // blue
        .init(hue: 0.72, light: .init(saturation: 0.68, brightness: 0.80),
              dark: .init(saturation: 0.50, brightness: 0.98)),   // indigo
        .init(hue: 0.89, light: .init(saturation: 0.64, brightness: 0.82),
              dark: .init(saturation: 0.48, brightness: 0.98)),   // pink
    ]

    /// What a lookup that found nothing is drawn with. A miss keeps its grey: the colour is for
    /// telling words apart, not for decorating a failure.
    static let miss = Color.secondary.opacity(Token.Opacity.missAccent)

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
        return accents[index(for: entry.lemma)]
    }
}
