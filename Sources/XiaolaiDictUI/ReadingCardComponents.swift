import Foundation
import SwiftUI
import XiaolaiDictCore

/// Shared paper, edge and lift. Callers retain their own content and pile sizing.
struct ReadingCardChrome: ViewModifier {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    let accent: Color
    var hovering = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: scale.radius.card, style: .continuous)
        content
            .background(shape.fill(CardSurface.fill(for: scheme, hovering: hovering)))
            .overlay(shape.strokeBorder(accent, lineWidth: Token.Stroke.hairline))
            .compositingGroup()
            .shadow(color: .black.opacity(Token.Opacity.cardShadow), radius: scale.shadow.cardRadius, y: scale.shadow.cardOffset)
            .contentShape(shape)
    }
}

struct ReadingPronunciation: View {
    @Environment(\.scale) private var scale
    let word: String
    let sentence: String
    var help: Text? = nil
    var say: (() -> Void)? = nil
    var body: some View {
        IconButton(title: "Say it aloud", symbol: "speaker.wave.2",
                   help: help ?? Speech.sayItAloudHelp(for: word, in: sentence), size: scale.text.small) {
            if let say { say() } else { Speech.say(word, in: sentence) }
        }
        .foregroundStyle(.tertiary)
    }
}

struct ReadingSentence: View {
    @Environment(\.scale) private var scale
    let sentence: String
    let ranges: [NSRange]
    let accent: Color
    var emphasis: WordEmphasis = CardOptions().emphasis
    var truncated = false
    var body: some View {
        SentenceWindowText(windows: SentenceExcerpt.windows(sentence: sentence, marks: ranges),
                           fullSentence: sentence, style: styled)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func styled(_ window: SentenceExcerpt) -> AttributedString {
        var text = MarkedSentence.text(window.text, marking: window.marks, size: scale.text.body,
                                       emphasis: emphasis, accent: accent)
        if truncated { text.append(AttributedString("…")) }
        return text
    }
}
