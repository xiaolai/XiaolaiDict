import SwiftUI

extension EnvironmentValues {
    /// True inside a menu, where a row has to be read: an `IconButton` there shows its title beside
    /// its icon. Everywhere else it is the icon alone.
    @Entry var iconButtonShowsTitle = false
}

/// **An icon-only control that is named and can be hit.** One component, because these were two
/// properties everybody had to remember and seven of eight call sites did not.
///
/// What it fixes, both measured 2026-09-25:
///
/// - **No accessibility name.** Seven of the eight icon buttons on the lookup card and the history
///   card drew a bare `Image(systemName:)`. `.help()` gives VoiceOver a *hint*, not a name, so the
///   control announced itself as a button and nothing more. `revealButton` alone got it right, with a
///   `Label` + `.labelStyle(.iconOnly)` — which is exactly what this is.
/// - **A target the size of the glyph.** No padding and no `contentShape`, so the clickable region was
///   the symbol's own box: 13 to 19 pt (`NSImage.SymbolConfiguration` at `text.body`, per symbol), six
///   of them 6 pt apart, against macOS's 28 pt default. On a history card the *destructive* trash sat
///   6 pt from open-in-Dictionary at 14 × 16 pt.
///
/// **The floor is a minimum, never a size.** `Token.Target.minimum` does not scale — a reader asking
/// for larger text is not asking for a larger mouse — but the glyph does, so a symbol wider than the
/// floor at `TextSize.large` keeps its own width. `contentShape` is what makes the frame *hittable*
/// rather than merely occupied: without it the padding is transparent to the hit test and the target
/// is the glyph again, which is the failure this component exists to prevent, arrived at one modifier
/// short.
///
/// `title` is a `LocalizedStringKey` and `help` a `Text` on purpose. Both are the shapes the compiler
/// extracts: `Text(someString)` takes the *verbatim* overload, which is how the card's tooltips came
/// to be English in a translated build while the drawer's copies of the same sentences were
/// translated.
///
/// ## What it does for the reader who cannot hover, or cannot tell by colour (2026-10-02)
///
/// - **The shortcut is in the tooltip, and is the shortcut.** `shortcut:` both binds the key and
///   names it — "Forgot (1)" — so the tooltip cannot name a key the button does not answer to.
///   Review's Space, 1, 2, S and T were bound and written down nowhere a reader could find.
/// - **A destructive control is red.** `.plain` ignores `role`, so `role: .destructive` used to
///   change nothing on screen: the trash and the speaker were the same grey.
/// - **Show Borders draws one.** A bare glyph has no edge to show, which is the case that setting
///   exists for.
/// - **VoiceOver hears the name once.** `.help(_:)` is the tooltip *and* the element's `AXHelp`,
///   which VoiceOver reads after the name: measured from a second process with the Accessibility
///   API, a button labelled *Say it aloud* with `.help("Say it aloud")` reported
///   `AXDescription = AXHelp = "Say it aloud"`, and the same button followed by
///   `.accessibilityHint(Text(""))` reported an empty `AXHelp`. So the spoken hint is set
///   separately from the tooltip: what the tooltip adds to the name, and nothing where it adds
///   nothing.
struct IconButton: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.iconButtonShowsTitle) private var showsTitle
    /// The name: the accessibility label, the menu row's words, and the start of the tooltip.
    let name: Text
    let symbol: String
    /// Where the tooltip says more than the name does — the voice a word will be spoken in, why a
    /// control is refusing. Nil where the name is the whole story, and then the name is the tooltip,
    /// so a pointer still gets an answer.
    var help: Text?
    /// What pressing it will mean, said after the name: "Skip — Still due today…". For a button
    /// that wore its name as a label and kept this as its tooltip; as an icon it needs both, name
    /// first, or the pointer is told the consequence of an action it has not been told the name of.
    var hint: Text?
    /// The key that presses it. Bound here and named in the tooltip from the same value.
    var shortcut: KeyboardShortcut?
    /// The type size the glyph is set at. `text.body` on the lookup card, `text.small` on a history
    /// card, which is why it is a parameter rather than a constant here.
    var size: CGFloat?
    var role: ButtonRole?
    var isEnabled = true
    let action: () -> Void

    init(
        title: LocalizedStringKey, symbol: String, help: Text? = nil, hint: LocalizedStringKey? = nil,
        shortcut: KeyboardShortcut? = nil, size: CGFloat? = nil, role: ButtonRole? = nil,
        isEnabled: Bool = true, action: @escaping () -> Void
    ) {
        name = Text(title)
        self.symbol = symbol
        self.help = help
        self.hint = hint.map { Text($0) }
        self.shortcut = shortcut
        self.size = size
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }

    /// **The usual way in**: the action's own symbol, name and role, from the one table.
    ///
    /// `title:` replaces the name where the call site knows more than the table does — a count,
    /// the word being acted on — and the symbol still comes from the action, so a counted
    /// *Discard 3 Readings* cannot drift onto a different glyph from *Discard*.
    init(
        _ kind: ActionSymbol, title: LocalizedStringKey? = nil, help: Text? = nil,
        hint: LocalizedStringKey? = nil, shortcut: KeyboardShortcut? = nil, size: CGFloat? = nil,
        isEnabled: Bool = true, action: @escaping () -> Void
    ) {
        name = title.map { Text($0) } ?? Text(kind.title)
        symbol = kind.symbol
        self.help = help
        self.hint = hint.map { Text($0) }
        self.shortcut = shortcut
        self.size = size
        role = kind.role
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        if showsTitle {
            // **A menu row, which is read.** The actions a footer offers as icons are offered by the
            // right-click menu too, from one builder, and a menu of bare glyphs is not a menu. The
            // menu draws the role and the key equivalent itself.
            Button(role: role, action: action) { label }
                .keyboardShortcut(shortcut)
                .disabled(!isEnabled)
        } else {
            icon
        }
    }

    private var label: some View {
        Label { name } icon: { Image(systemName: symbol) }
    }

    /// The name, with its key after it where it has one: "Forgot (1)".
    private var namedWithShortcut: Text {
        guard let shortcut else { return name }
        return Text("\(name) (\(Text(verbatim: ShortcutLabel.text(for: shortcut))))")
    }

    private var tooltip: Text {
        if let help { return help }
        guard let hint else { return namedWithShortcut }
        return Text("\(namedWithShortcut) — \(hint)")
    }

    /// What VoiceOver says after the name: only what the tooltip adds to it. Empty rather than
    /// absent, because absent leaves `.help`'s copy of the name in place to be read a second time.
    /// The key is not here — `keyboardShortcut` gives it to Accessibility itself.
    private var spokenHint: Text { help ?? hint ?? Text(verbatim: "") }

    /// Red where pressing it destroys something, and only while it can be pressed: a disabled
    /// control takes whatever its surroundings give a disabled one.
    private var tint: Color? {
        guard role == .destructive, isEnabled else { return nil }
        return StatusPalette.destructive.color(in: scheme, contrast: contrast)
    }

    private var icon: some View {
        Button(role: role, action: action) {
            label
                .labelStyle(.iconOnly)
                .font(.system(size: size ?? scale.text.body))
                .modifier(Tinted(tint: tint))
                // Both bounds, and the floor is the *minimum* of each: a glyph wider than the floor
                // keeps its width, and one narrower is padded out to it.
                .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
                // Without this the padding is transparent to the hit test and the target is the glyph
                // again — the frame would look right and click wrong.
                .contentShape(Rectangle())
                .showBordersEdge()
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .disabled(!isEnabled)
        .help(tooltip)
        .accessibilityHint(spokenHint)
    }
}

/// A colour where there is one, and **no modifier at all** where there is not — so a button with
/// no tint of its own goes on taking the style its call site gave it, exactly as before.
private struct Tinted: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        if let tint { content.foregroundStyle(tint) } else { content }
    }
}

/// How a key is written in a tooltip: the platform's own glyphs, modifiers in the platform's order.
enum ShortcutLabel {
    static func text(for shortcut: KeyboardShortcut) -> String {
        var written = ""
        // Control, Option, Shift, Command — the order every macOS menu draws them in.
        if shortcut.modifiers.contains(.control) { written += "⌃" }
        if shortcut.modifiers.contains(.option) { written += "⌥" }
        if shortcut.modifiers.contains(.shift) { written += "⇧" }
        if shortcut.modifiers.contains(.command) { written += "⌘" }
        return written + key(shortcut.key)
    }

    private static func key(_ key: KeyEquivalent) -> String {
        switch key {
        // A word, because the glyph for it is a blank. The menus say "Space" too.
        case .space: String(localized: "Space")
        case .return: "↩"
        case .escape: "⎋"
        case .delete: "⌫"
        case .tab: "⇥"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        default: String(key.character).uppercased()
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Named, and 28 pt whether the glyph is") {
    HStack(spacing: 0) {
        IconButton(.sayAloud) {}
        IconButton(.openInDictionary) {}
        IconButton(.forgot, shortcut: KeyboardShortcut("1", modifiers: [])) {}
        IconButton(.deletePermanently) {}
        IconButton(.copy, isEnabled: false) {}
    }
    .foregroundStyle(.secondary)
    .border(.red.opacity(0.3))
    .padding()
}
#endif
