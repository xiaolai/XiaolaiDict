import AppKit
import XiaolaiDictCore
import XiaolaiDictUI
import ScreenCaptureKit

/// Whether the history drawer actually appears, docked where it asked to be, **without taking
/// focus** — measured inside the running bundle rather than asserted from the source.
///
/// The focus question is the one that matters. The spike this drawer came from called
/// `NSApp.activate()` and made its panel key, and built Escape handling and click-away dismissal on
/// top of that. XiaolaiDict's panels must never do it: the reader is mid-sentence in another app. A unit
/// test can check that the code does not call `activate`; only a running bundle can check that
/// nothing else activated it either.
@MainActor
enum HistoryReport {
    /// How long the instrument will wait for the drawer to appear before calling it a failure.
    static let appearance: Duration = .seconds(3)

    /// Set before the scene starts, so the delegate knows to measure instead of just running.
    nonisolated(unsafe) static var isWanted = false

    /// Measures **the running app**, not a controller built for the occasion. It has to: a scene
    /// exists only inside the app that declares it. It is a better instrument for it — what it
    /// measures is what the reader gets.
    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
        // **Before anything else**: a run that never gets as far as measuring — no drawer, no
        // display — must not leave the last run's images to be copied as this one's. A deletion
        // that fails is carried into the report, because the file left behind is what gets looked
        // at.
        var evidenceProblems: [String] = []
        for name in ["black", "white", "stripes"] where FileManager.default.fileExists(atPath: evidence(name).path) {
            do { try FileManager.default.removeItem(at: evidence(name)) } catch {
                evidenceProblems.append("could not clear the last run's \(name) image: \(error)")
            }
        }
        let screens = NSScreen.screens.map(ScreenMetrics.init)
        let expected = DrawerPlacement.screen(under: UpPoint(NSEvent.mouseLocation), among: screens)
            .map { DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .right), on: $0) }

        app.toggleHistory()
        // Asks the compositor, not the controller. The controller's own answer is what once
        // reported a drawer that had never been drawn.
        let appeared = await Instrument.settle(until: appearance) { app.drawerIsDrawn && app.drawerModel.revealed }
        // Bounded, like every other wait here: a ledger read that never answers would otherwise
        // hold the whole report past any deadline the harness allows it.
        if let reload = app.drawerReload {
            _ = try? await withDeadline(.seconds(10)) { await reload.value }
        }

        // Read while it shows, because that is the only moment they can be true.
        let drawn = app.drawerIsDrawn
        let activatedUs = NSApp.isActive
        let claimedEscape = app.drawerHoldsEscape
        let frame = app.drawerWindowFrame
        let docked = expected.map { $0.windowRect.cg == frame } ?? false
        // After the focus reading, so nothing this does can be mistaken for the drawer's doing.
        // Read through the drawer's own rectangle, from the geometry it was actually placed with.
        let backdrop: BackdropOutcome
        if !drawn {
            backdrop = .unmeasured(([ "the drawer was not drawn" ] + evidenceProblems).joined(separator: "; "))
        } else if let geometry = app.drawerModel.geometry {
            backdrop = await measureBackdrop(
                behind: frame, through: glassRegion(window: frame, geometry: geometry),
                carrying: evidenceProblems)
        } else {
            backdrop = .unmeasured("the drawer is drawn but has no geometry to read it through")
        }
        // What the backdrop measurement depends on: the drawer above an ordinary window. Reported
        // so a reading can be checked against the stacking it assumed.
        let drawerLevel = app.drawerWindowLevel

        app.toggleHistory()
        let released = await Instrument.settle(until: .seconds(2)) { !app.drawerHoldsEscape && !app.drawerIsDrawn }

        let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "screens": screens.count,
            "appeared": appeared,
            "drawnOnScreen": drawn,
            "dockedWhereAsked": docked,
            "frame": NSStringFromRect(frame),
            "expectedFrame": expected.map { NSStringFromRect($0.windowRect.cg) } ?? "none",
            // False is the passing value. True means the drawer stole focus from whatever the
            // reader was reading, which is the whole reason this report exists.
            "activatedTheApp": activatedUs,
            "claimedEscapeWhileShown": claimedEscape,
            "releasedEscapeAfterClosing": released,
            "days": app.drawerModel.days.count,
            "entries": app.drawerModel.totalEntries,
            "problem": app.drawerModel.problem ?? "none",
            // Whether the drawer lets what is behind it through — the one property "glass" names,
            // and one nothing measured until the reader saw a flat grey panel on screen. Reported,
            // not folded into this process's exit status: it is its own assertion in e2e.sh.
            // "unmeasured" is a string on purpose, so a failed measurement can never read as a
            // measured `false`.
            "backdropShowsThrough": backdrop.reading.map { $0.showsThrough as Any } ?? "unmeasured",
            "backdropChangedFraction": backdrop.reading?.changedFraction ?? -1,
            "backdropProblem": backdrop.problem ?? "none",
            "drawerWindowLevel": drawerLevel,
            // The glass this instance loaded from the reader's settings, and how much of the
            // stripes' colour came through it. e2e.sh runs the report once per glass and compares:
            // a setting the drawer never reads would score the same both times.
            "drawerGlass": app.appearance.drawerGlass.rawValue,
            "stripesColour": backdrop.stripesColour ?? -1,
            "glassOverBlack": backdrop.reading?.glassOverBlack ?? -1,
            "backdropWindowLevel": NSWindow.Level.normal.rawValue,
            // The stripes are a picture to look at, not a score — so their failing is reported on
            // its own and never costs the black-and-white reading it did not take part in.
            "stripesProblem": backdrop.stripesProblem ?? "none",
            // The captures written to /tmp to be looked at, or why one was not. An image that
            // failed to write must not leave an older run's file standing in for it.
            "evidenceProblem": backdrop.evidenceProblem ?? "none",
        ]
        guard Instrument.write(report) else { return .internalError }
        return appeared && drawn && docked && !activatedUs && claimedEscape && released ? .success : .failure
    }

    // MARK: - What the drawer does to what is behind it

    /// Whether the drawer lets what is behind it through, from two captures of the same region.
    ///
    /// **Measured, because it was assumed.** The drawer is `glassEffect`, the Xcode canvas draws
    /// glass as flat grey by design, and a comment said to judge it in the running app — which no
    /// check ever did. The report confirmed the window was on screen and docked, and a flat grey
    /// panel would pass both. So: put black directly behind the drawer, capture it, put white
    /// there, capture again, and see how much of it changed.
    ///
    /// **It works** — measured 2026-09-21: the drawer's glass reads (133, 133, 133) over black and
    /// (240, 240, 240) over white. The reader saw a flat grey panel because the drawer docks over
    /// a black terminal, and frosted glass over uniform black is exactly that grey; a single-window
    /// screenshot renders it the same way, over nothing. A flat-looking drawer is a question about
    /// what is behind it before it is a question about the glass.
    ///
    /// **A share of the drawer, not all of it.** Cards are opaque and read the same over any
    /// backdrop, so a busy drawer is mostly cards; what must change is the glass between and around
    /// them. A few leaking pixels — a corner the inset missed — must not pass a panel that is
    /// otherwise flat, which is why the bar is a share and not "anything moved".
    struct BackdropReading: Sendable {
        /// A pixel "changed" if its luminance moved by more than this, 0–255: above antialiasing and
        /// the compositor's dithering, well below what a translucent surface does over black and
        /// white.
        static let changedBy = 24
        /// The share of the drawer that has to change for it to count as letting the backdrop
        /// through: above a leak, below the glass left visible between a drawer full of cards.
        static let glassShare = 0.05

        let changedFraction: Double
        var showsThrough: Bool { changedFraction >= Self.glassShare }
        /// How bright the glass is over black, 0–255: the median, over the black capture, of the
        /// pixels that changed with the backdrop — which are the glass, because cards do not change.
        /// **This is where frosted and clear differ**: measured 133 for frosted and 71 for clear, and
        /// a dark terminal behind the drawer is the case that made frosted look broken. Nil when
        /// nothing changed, which is no glass to read rather than a reading of zero.
        let glassOverBlack: Int?

        /// `black` and `white` are the same region's luminance, pixel for pixel, over each backdrop.
        init(black: [UInt8], white: [UInt8]) {
            precondition(black.count == white.count, "two captures of one region differ in size")
            let glass = zip(black, white).filter { abs(Int($0) - Int($1)) > Self.changedBy }.map(\.0)
            changedFraction = black.isEmpty ? 0 : Double(glass.count) / Double(black.count)
            glassOverBlack = glass.isEmpty ? nil : Int(glass.sorted()[glass.count / 2])
        }
    }

    /// Puts black, then white, directly behind the drawer and reads the drawer both times.
    ///
    /// The backdrop is an ordinary window at normal level, so it sits under the floating drawer and
    /// above whatever else is on screen; `orderFrontRegardless` shows it without activating XiaolaiDict.
    /// The region is the drawer inset from its edges, so the transparent corners of the window —
    /// which show the backdrop whether or not the glass works — are never counted.
    /// Measured, or not — never a default standing in for a reading.
    enum BackdropOutcome: Sendable {
        /// `stripesColour` is how much of the stripes' colour came through, 0–255: the mean spread
        /// between each pixel's strongest and weakest channel over the stripes capture. Opaque cards
        /// score near zero in any glass, so what separates two readings is the glass between them.
        case measured(BackdropReading, stripes: Stripes, evidenceProblem: String?)
        case unmeasured(String)

        /// The detailed backdrop, measured or not — apart from the reading, which does not need it.
        enum Stripes: Sendable {
            case measured(colour: Double)
            case unmeasured(String)
        }

        var reading: BackdropReading? {
            if case .measured(let reading, _, _) = self { return reading }
            return nil
        }
        var stripesColour: Double? {
            if case .measured(_, .measured(let colour), _) = self { return colour }
            return nil
        }
        var stripesProblem: String? {
            if case .measured(_, .unmeasured(let why), _) = self { return why }
            return nil
        }
        var evidenceProblem: String? {
            if case .measured(_, _, let problem) = self { return problem }
            return nil
        }
        var problem: String? {
            if case .unmeasured(let why) = self { return why }
            return nil
        }
    }

    /// One capture: its luminance, pixel for pixel, and how much colour it holds on average.
    struct Capture: Sendable {
        let luminance: [UInt8]
        let colour: Double

        /// The pixel arithmetic alone: luminance per pixel, and the mean spread between each pixel's
        /// strongest and weakest channel. Apart from the capture so it can be checked against an
        /// image whose answer is known; nil when the image cannot be drawn into a buffer.
        init?(image: CGImage) {
            let (w, h) = (image.width, image.height)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var luminance = [UInt8](repeating: 0, count: w * h)
            var spread = 0
            for p in 0..<(w * h) {
                let (r, g, b) = (Int(rgba[p * 4]), Int(rgba[p * 4 + 1]), Int(rgba[p * 4 + 2]))
                luminance[p] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
                spread += max(r, g, b) - min(r, g, b)
            }
            self.luminance = luminance
            colour = w * h == 0 ? 0 : Double(spread) / Double(w * h)
        }
    }

    /// Where the backdrop is read through: **the drawer itself, never the window around it.**
    ///
    /// The window is the drawer grown by `DrawerLayout.shadowMargin` for its shadow, and that margin
    /// is transparent — it shows the backdrop whether or not the glass works. The capture used to
    /// be the window inset by 24 points, which kept 24 of the margin's 48: on a 380-point drawer,
    /// 6.3% of the region, over the 5% the reading needs to call a drawer glass. An opaque drawer
    /// would have passed. Inset by the corner radius as well, so the transparent rounded corners
    /// are never counted either.
    static func glassRegion(window frame: CGRect, geometry: DrawerGeometry) -> CGRect {
        let drawer = CGRect(
            x: frame.minX + geometry.contentOrigin.x,
            y: frame.maxY - geometry.contentOrigin.y - geometry.contentSize.height,
            width: geometry.contentSize.width, height: geometry.contentSize.height)
        return drawer.insetBy(dx: geometry.cornerRadius, dy: geometry.cornerRadius)
    }

    /// Where each capture is kept to be looked at.
    private static func evidence(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/xiaolaidict-backdrop-\(name).png")
    }

    private static func measureBackdrop(
        behind frame: CGRect, through region: CGRect, carrying carried: [String]
    ) async -> BackdropOutcome {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return .unmeasured("no display under the drawer") }
        // Display-local and top-left, which is what ScreenCaptureKit's `sourceRect` means.
        let source = CGRect(
            x: region.minX - screen.frame.minX, y: screen.frame.maxY - region.maxY,
            width: region.width, height: region.height)
        let pixels = CGSize(width: region.width * screen.backingScaleFactor,
                            height: region.height * screen.backingScaleFactor)


        let backdrop = NSWindow(
            contentRect: frame.insetBy(dx: -40, dy: -40), styleMask: .borderless,
            backing: .buffered, defer: false)
        backdrop.level = .normal
        backdrop.isOpaque = true
        backdrop.ignoresMouseEvents = true
        backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary]
        defer { backdrop.orderOut(nil) }

        /// Shows the backdrop as `present` sets it, waits for the compositor to redraw the glass over
        /// it, and captures — one protocol for every backdrop, so the solid colours and the stripes
        /// cannot come to be measured differently.
        func capture(_ name: String, _ present: () -> Void) async throws -> (Capture, String?) {
            present()
            backdrop.orderFrontRegardless()
            backdrop.display()
            try? await Task.sleep(for: .milliseconds(400))
            // The instrument's own deadline, not the product's: the first capture after boot pays a
            // system-wide warm-up measured at nearly 15 s.
            let image = try await withDeadline(.seconds(30)) {
                try await screenImage(of: source, size: pixels, onDisplay: displayID)
            }
            guard let reading = Capture(image: image) else { throw BackdropError.unreadable }
            return (reading, keep(image, as: evidence(name)))
        }

        let black: (Capture, String?)
        let white: (Capture, String?)
        do {
            black = try await capture("black") { backdrop.backgroundColor = .black }
            white = try await capture("white") { backdrop.backgroundColor = .white }
        } catch {
            return .unmeasured("\(error)")
        }
        // **And over something with detail, to be looked at.** Black and white prove that light
        // passes through; they cannot show whether the drawer looks like glass, because over a
        // uniform colour nothing does. Kept as an image, not scored — and its failing is its own:
        // it cannot undo a reading it took no part in.
        let stripes: BackdropOutcome.Stripes
        var stripesEvidence: String?
        do {
            let (reading, problem) = try await capture("stripes") { backdrop.contentView = BackdropStripes() }
            stripes = .measured(colour: reading.colour)
            stripesEvidence = problem
        } catch {
            stripes = .unmeasured("\(error)")
        }
        let problems = carried + [black.1, white.1, stripesEvidence].compactMap { $0 }
        return .measured(
            BackdropReading(black: black.0.luminance, white: white.0.luminance),
            stripes: stripes, evidenceProblem: problems.isEmpty ? nil : problems.joined(separator: "; "))
    }

    /// The screen as composited — every window — over `source`.
    private nonisolated static func screenImage(
        of source: CGRect, size: CGSize, onDisplay displayID: CGDirectDisplayID
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw BackdropError.displayMissing
        }
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    /// Writes a capture as PNG, and answers why not when it could not be. **A measurement whose
    /// evidence cannot be looked at can only be believed** — the first reading this produced was
    /// implausible enough that it had to be looked at — so a failed write is reported, not dropped.
    private static func keep(_ image: CGImage, as url: URL) -> String? {
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return "could not create \(url.path)"
        }
        CGImageDestinationAddImage(file, image, nil)
        return CGImageDestinationFinalize(file) ? nil : "could not write \(url.path)"
    }

    private enum BackdropError: Error { case displayMissing, unreadable }

}

/// Bold diagonal bands of saturated colour: the detail a glass surface is judged against. Diagonal
/// so a blur shows as colours bleeding into each other along both axes; saturated so a frosted
/// surface's own tint cannot pass for what is behind it.
private final class BackdropStripes: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        let band: CGFloat = 48
        let rise = bounds.height
        var x = -rise, index = 0
        while x < bounds.width {
            context.setFillColor(colors[index % colors.count].cgColor)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x + band, y: 0))
            context.addLine(to: CGPoint(x: x + band + rise, y: rise))
            context.addLine(to: CGPoint(x: x + rise, y: rise))
            context.fillPath()
            x += band
            index += 1
        }
    }
}
