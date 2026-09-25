/// How a captured word was obtained, and how far to trust it. Every capture carries one, so a
/// degraded capture can never render — or be recorded — as confidently as a clean one.
public struct CaptureQuality: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable {
        /// `AXSelectedText` with `AXSelectedTextRange`: Cocoa text views, most native apps.
        case accessibilityTextRange
        /// `AXSelectedTextMarkerRange`: WebKit and Chromium pages.
        case accessibilityTextMarkers
        /// `AXBoundsForRange` per word of the element under the pointer — the third dialect, and
        /// the only one Chromium answers. It answers neither `AXRangeForPosition` (unsupported)
        /// nor `AXTextMarkerForPosition` (advertised, returns nil), so scanning bounds took Chrome
        /// from **0 of 64 probes to 62 of 64** (the screen-word spike, finding 2).
        case accessibilityBoundsScan
        /// Read off the pixels with Vision, where no app exposes its text at all — a terminal, a
        /// canvas, an image. Costs 250–570 ms warm against 1–9 ms for Accessibility, and unlike
        /// the others it can be **wrong rather than absent**, which is why its confidence is the
        /// recogniser's own and not 1.
        case opticalRecognition
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
    /// text reports the recogniser's own confidence in the line the word came from.
    public let confidence: Double

    /// **Below this, a capture is worth telling the reader about.**
    ///
    /// Measured 2026-09-25 across a 12×16 grid of points on a 5120×1440 desktop — 20 optical
    /// reads over a terminal and a chat window:
    ///
    ///     1.0   15   ███████████████
    ///     0.5    4   ████
    ///     0.3    1   █
    ///
    /// **Nothing landed between 0.5 and 1.0**, so the number is picked from an empty gap rather
    /// than fitted to a boundary — 0.8 and 0.99 would behave identically on every sample. That is
    /// the whole reason it can be stated at all from twenty readings.
    ///
    /// The two misreads in that set are both under it: `xiaolai` read as "xaiolai" and `Linode` as
    /// "Linodeo", at 0.5. Every 1.0 read was correct — *New*, *Agentic*, *wiki*, *Show*, *Find*,
    /// *to*. Low confidence does not mean wrong (`git`, `4` and `16` were right at 0.5); it means
    /// doubt, which is what a caveat is for.
    ///
    /// **Twenty samples, and the labels are a reading of the words rather than ground truth**
    /// against what was on the screen. The gap is wide enough that the threshold survives being
    /// wrong about a few of them; a distribution that later shows values in between would not.
    public static let doubtful = 0.9

    /// Whether this capture is one to say something about: read off the pixels *and* doubted.
    /// Source alone is not enough — three quarters of optical reads come back at full confidence,
    /// and warning about those trains the reader to ignore the warning that matters.
    public var isDoubtful: Bool {
        source == .opticalRecognition && confidence < Self.doubtful
    }
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
