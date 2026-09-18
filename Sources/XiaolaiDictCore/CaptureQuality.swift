/// How a captured word was obtained, and how far to trust it. Every capture carries one, so a
/// degraded capture can never render — or be recorded — as confidently as a clean one.
public struct CaptureQuality: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable {
        /// `AXSelectedText` with `AXSelectedTextRange`: Cocoa text views, most native apps.
        case accessibilityTextRange
        /// `AXSelectedTextMarkerRange`: WebKit and Chromium pages.
        case accessibilityTextMarkers
    }

    /// What the context — the sentence recorded with the word — amounts to.
    public enum Context: String, Sendable, CaseIterable {
        /// The whole sentence, or run of sentences, around the selection.
        case complete
        /// The sentence around the selection, but the text that could be read ended inside it: it
        /// may go on past what was captured.
        case mayBeCut
        /// The app exposed no surrounding text, or none consistent with the selection. The
        /// context is the selection itself.
        case missing
    }

    public let source: Source
    /// 0...1. Accessibility hands over the app's own characters, so its captures are 1; recognised
    /// text (OCR, Milestone 2) will report less.
    public let confidence: Double
    public let context: Context

    /// Nil when `confidence` is outside 0...1 — including NaN.
    public init?(source: Source, confidence: Double, context: Context) {
        guard (0...1).contains(confidence) else { return nil }
        self.source = source
        self.confidence = confidence
        self.context = context
    }

    /// An Accessibility capture: the app's own characters, so full confidence.
    public static func accessibility(_ source: Source, context: Context) -> CaptureQuality {
        CaptureQuality(uncheckedSource: source, confidence: 1, context: context)
    }

    private init(uncheckedSource source: Source, confidence: Double, context: Context) {
        self.source = source
        self.confidence = confidence
        self.context = context
    }
}
