import Foundation
import Testing

/// The Reading History panel's surface, read from its source.
///
/// `ImageRenderer` draws glass and a `ScrollView` as one flat tone, so nothing about the panel's
/// material, its header or what scrolls under it can be checked in pixels — and whether an
/// animation consults Reduce Motion is not a pixel at all. Each check here is for a defect that was
/// silent when it was found (2026-10-01): the code compiled, the suite was green, and the reader
/// got the wrong thing.
struct HistoryDrawerSurfaceTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The source with its comments taken out, so a sentence *about* a removed call cannot stand
    /// in for the call — or be mistaken for its return.
    private func code(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var views: String { get throws { try code("Sources/XiaolaiDictUI/HistoryDrawerViews.swift") } }
    private var card: String { get throws { try code("Sources/XiaolaiDictUI/ReadingCardComponents.swift") } }
    private var controller: String { get throws { try code("Sources/XiaolaiDict/HistoryDrawer.swift") } }

    /// The part of `source` from `start` up to `end`, required rather than defaulted: a renamed
    /// landmark must fail here, not leave an empty string that contains nothing objectionable.
    private func section(of source: String, from start: String, to end: String) throws -> Substring {
        let from = try #require(source.range(of: start), "no `\(start)` to read from")
        let upTo = try #require(source.range(of: end, range: from.upperBound..<source.endIndex), "no `\(end)` after it")
        return source[from.lowerBound..<upTo.lowerBound]
    }

    // MARK: - One animation owns the panel's arrival

    /// **The view carries no implicit animation of `revealed`.** It did —
    /// `.animation(.easeOut(…), value: model.revealed)` — and that replaced the controller's
    /// springs on the one view they were meant for, so the motion the comments described was never
    /// the motion on screen.
    @Test func nothingInTheViewAnimatesRevealedBehindTheControllersBack() throws {
        let root = try section(of: try views, from: "public struct HistoryDrawerRootView", to: "struct HistoryDrawerSurface")
        #expect(!root.contains(".animation("), "an implicit animation is back on the panel's root")
        #expect(!root.contains("motionAwareAnimation("), "an implicit animation is back on the panel's root")
        // And the slide is not a slide for a reader who asked for less motion.
        #expect(root.contains("MotionPreference.travel(parked.width, reduceMotion: reduceMotion)"))
        #expect(root.contains("MotionPreference.travel(parked.height, reduceMotion: reduceMotion)"))
    }

    @Test func theControllerAnimatesRevealedWithTheOneDefinition() throws {
        let source = try controller
        #expect(source.contains("withAnimation(DrawerMotion.open(reduceMotion: self.reduceMotion()))"))
        #expect(source.contains("withAnimation(DrawerMotion.close(reduceMotion: reduceMotion()))"))
        #expect(!source.contains("Animation.spring("), "the controller has a spring of its own again")
        #expect(source.contains("MotionPreference.systemReduceMotion"))
    }

    // MARK: - Every animation here consults Reduce Motion

    /// A bare `.animation(` or `withAnimation(.` is an animation nobody asked the setting about.
    @Test(arguments: [
        "Sources/XiaolaiDictUI/HistoryDrawerViews.swift",
        "Sources/XiaolaiDictUI/ReadingCardComponents.swift",
        "Sources/XiaolaiDictUI/HistoryDrawerModel.swift",
        "Sources/XiaolaiDict/HistoryDrawer.swift",
    ])
    func everyAnimationGoesThroughTheMotionPreference(path: String) throws {
        let source = try code(path)
        // What is left once the helper's own name is taken out is an animation written without it.
        #expect(!source.replacingOccurrences(of: "MotionPreference.animation(", with: "").contains(".animation("),
                "\(path): an animation that ignores Reduce Motion")
        for call in source.components(separatedBy: "withAnimation(").dropFirst() {
            #expect(call.hasPrefix("MotionPreference.animation(") || call.hasPrefix("DrawerMotion."),
                    "\(path): withAnimation(\(call.prefix(40))… does not ask about Reduce Motion")
        }
        #expect(!source.contains("scaleEffect(") || source.contains("MotionPreference.scale("),
                "\(path): a scale that ignores Reduce Motion")
    }

    /// The positive control: the surface does animate, so the check above has something to pass.
    @Test func thereAreAnimationsForThatCheckToFind() throws {
        #expect(try views.contains("withAnimation(MotionPreference.animation("))
        #expect(try views.contains("motionAwareAnimation("))
        #expect(try card.contains("withAnimation(MotionPreference.animation("))
    }

    // MARK: - Glass

    /// **Regular glass, and no choice of another.** The Frosted/Clear setting put secondary text
    /// on clear glass with no dimming layer and competed with the system's own control.
    @Test func thePanelIsRegularGlassAndNothingElse() throws {
        let surface = try section(of: try views, from: "struct HistoryDrawerSurface", to: "extension HistoryDrawerModel")
        #expect(surface.contains(".glassEffect(.regular, in: shape)"))
        #expect(surface.components(separatedBy: ".glassEffect(").count - 1 == 1, "glass inside glass")
        #expect(!surface.contains("drawerGlass"))
        // No shadow of its own stacked on the system's, and no rule drawn by hand under the header.
        #expect(!surface.contains(".shadow("), "a custom shadow is stacked on the glass's own")
        #expect(!surface.contains("Divider()"), "a hand-drawn rule is back under the header")
        #expect(surface.contains(".safeAreaBar(edge: .top"))
    }

    /// The setting is gone from the whole tree, not merely unread here.
    @Test func noSourceFileKnowsAboutAChoiceOfGlass() throws {
        var scanned = 0
        for directory in ["Sources/XiaolaiDictUI", "Sources/XiaolaiDict"] {
            let files = try FileManager.default
                .contentsOfDirectory(at: Self.root.appending(path: directory), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
            for file in files {
                scanned += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("DrawerGlass") && !source.contains("drawerGlass"),
                        "\(file.lastPathComponent) still refers to the drawer's glass setting")
            }
        }
        #expect(scanned > 20, "the scan found \(scanned) files, which is not the source tree")
    }

    // MARK: - Names and counts

    @Test func theSurfaceIsCalledReadingHistory() throws {
        let source = try views
        #expect(source.contains("Text(\"Reading History\")"))
        #expect(!source.contains("Read recently"))
    }

    /// "Undo discarding 1 readings" was the commonest case.
    @Test func theUndoCountInflects() throws {
        let source = try views
        #expect(source.contains("IconButton(.undo, title: \"Undo Discarding ^[\\(receipt.affected) Reading](inflect: true)\")"))
        #expect(source.contains("Text(\"^[\\(receipt.affected) reading](inflect: true) discarded\")"))
        #expect(!source.contains("readings\""), "a count is spelled plural by hand")
        // A row under the header, not an overlay on it.
        #expect(!(try section(of: source, from: "private var header", to: "private var contents")).contains(".overlay("))
    }

    /// **The header, each day and its tooltip count one unit — readings, and a reading is one
    /// lookup.** The drawer counted cards and called them readings while the Library's subtitle
    /// counted lookups under the same word: "10 readings" here over "72 readings" there, one
    /// history (E2E Mac, 2026-10-02). A card's own "×N" is in lookups, so the cards on screen
    /// now add up to their day and the days to the header.
    @Test func theHeaderAndTheDaysCountTheSameThing() throws {
        let source = try views
        #expect(source.contains("^[\\(model.totalLookups) reading](inflect: true) · ^[\\(model.days.count) day](inflect: true)"))
        #expect(source.contains(".help(Text(\"^[\\(count) reading](inflect: true)\"))"))
        #expect(source.contains("private var count: Int { day.lookups }"), "a day counts cards while the header counts lookups")
        #expect(!source.contains("model.totalEntries) reading"), "the header counts cards again")
        #expect(!source.contains("distinctWords"))
        #expect(!source.contains(" word]"), "something on the panel still counts words")
    }

    // MARK: - Headings, and one toggle per day

    @Test func headingsAreHeadingsAndADayHasOneToggle() throws {
        let source = try views
        #expect(source.components(separatedBy: ".accessibilityAddTraits(.isHeader)").count - 1 == 3,
                "the panel's title, a listed day and a piled day are the three headings")
        let pile = try section(of: source, from: "struct DayPileView", to: "private struct DayHeader")
        // One real button — the header — and no second one laid over the pile.
        #expect(!pile.contains("Button("), "the pile has a button of its own beside the header's")
        #expect(!pile.contains(".overlay"), "something is laid over the pile's cards again")
        #expect(pile.contains("DayHeader(day: day, disclosure:"))
        let header = try section(of: source, from: "private struct DayHeader", to: "#if DEBUG")
        #expect(header.components(separatedBy: "Button(").count - 1 == 1)
        #expect(header.contains(".frame(minHeight: Token.Target.minimum)"))
        #expect(header.contains("disclosure.action.image"), "Show All has no chevron")
    }

    // MARK: - The card

    /// The panel draws the shared card, and draws nothing of a card itself.
    @Test func thePanelDrawsTheSharedCard() throws {
        let source = try views
        #expect(source.contains("ReadingCardView(entry: entry, actions:"))
        #expect(source.contains("entry: card.entry, layer: card.layer,"))
        #expect(!source.contains("struct ReadingCardView"), "the panel has a card of its own again")
        #expect(try card.contains("struct ReadingCardView: View"))
    }

    /// **Discard is never hidden from assistive technology**, and nothing on the card is revealed
    /// only by a hover.
    @Test func noCardControlIsHiddenUnlessThePointerIsOverIt() throws {
        let source = try card
        #expect(!source.contains("accessibilityHidden(!hovering)"))
        #expect(!source.contains(".opacity(hovering"))
        // Discard wears its own symbol and no destructive role: it can be undone.
        #expect(source.contains("IconButton(.discardReading, size: scale.text.small, action: discard)"))
        #expect(!source.contains("role: .destructive"))
        #expect(!source.contains("archivebox"))
    }

    /// Every action on the card is in its context menu too, from the same handlers.
    @Test func theContextMenuCarriesEveryAction() throws {
        let source = try card
        #expect(source.contains(".contextMenu { if layer.showsContent { menu } }"))
        let menu = try section(of: source, from: "private var menu: some View", to: "private var sentenceLine")
        for action in [".sayAloud", ".hideMeaning : .showMeaning", ".openInDictionary", ".saveMeaning",
                       ".showInLibrary", ".restoreReading", ".discardReading"] {
            #expect(menu.contains(action), "the menu has no \(action)")
        }
        let row = try section(of: source, from: "private var actionRow: some View", to: "private var savedMark")
        for action in [".hideMeaning : .showMeaning", ".openInDictionary", ".saveMeaning",
                       ".showInLibrary", ".restoreReading", ".discardReading"] {
            #expect(row.contains(action), "the card has no \(action)")
        }
        #expect(row.contains("ReadingPronunciation(word: entry.surface, sentence: entry.sentence)"))
        #expect(menu.contains(".environment(\\.iconButtonShowsTitle, true)"), "a menu of bare icons")
    }

    /// No symbol name and no worded push button: an action is an `ActionSymbol`.
    @Test(arguments: [
        "Sources/XiaolaiDictUI/HistoryDrawerViews.swift",
        "Sources/XiaolaiDictUI/ReadingCardComponents.swift",
    ])
    func actionsAreNamedByTheOneTable(path: String) throws {
        // Previews are development tools and name nothing a reader sees.
        let source = try code(path).components(separatedBy: "#if DEBUG")[0]
        #expect(!source.contains("systemName:"), "\(path) spells a symbol's name itself")
        #expect(!source.contains("symbol: \""), "\(path) spells a symbol's name itself")
        #expect(!source.contains("Button(\""), "\(path) has a worded button")
        #expect(!source.contains(".tertiary"), "\(path) draws something readable in the disabled colour")
        #expect(!source.contains(".tint)"), "\(path) uses the tint as a text colour")
    }

    /// The headword is the form the reader met, in the lemma's colour, with contrast passed on.
    @Test func theCardShowsTheFormTheReaderMetInTheLemmasColour() throws {
        let source = try card
        #expect(source.contains("ReadingPalette.color(for: entry, in: scheme, contrast: contrast)"))
        #expect(source.contains("CardSurface.border(for: entry, layer: layer, in: scheme, contrast: contrast)"))
        #expect(source.contains("Text(verbatim: headword)"))
        #expect(source.contains("entry.surface.isEmpty ? entry.lemma : entry.surface"))
        // The sentence is the card's content, and is primary.
        let sentence = try section(of: source, from: "struct ReadingSentence", to: "struct BadgeCapsule")
        #expect(sentence.contains(".foregroundStyle(.primary)"))
    }

    /// A buried plate's invisible buttons lie in the sliver that shows; they take no click and no
    /// keyboard focus.
    @Test func aBuriedCardCannotBeClickedOrTabbedTo() throws {
        let source = try card
        #expect(source.contains(".allowsHitTesting(layer.showsContent)"))
        #expect(source.contains(".disabled(!layer.showsContent)"))
    }
}
