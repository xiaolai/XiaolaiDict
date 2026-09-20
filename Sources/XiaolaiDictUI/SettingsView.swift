import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
public final class SettingsModel {
    /// Empty until the first probe answers. A window that said "everything is fine" before it had
    /// asked would be the same false green tick this whole probe exists to remove.
    var report = PermissionsReport(states: [])
    private(set) var hasAsked = false

    public init() {}

    public func refresh() async {
        show(await .probe())
    }

    /// Takes a report from wherever it came. Previews use it to show a state this machine is not
    /// in — a permission being *off* is what the window has to be designed around, and asking the
    /// system can only ever show how this Mac happens to be set up.
    public func show(_ report: PermissionsReport) {
        self.report = report
        hasAsked = true
    }
}

public struct SettingsView: View {
    @Environment(\.scale) private var scale
    @State private var model: SettingsModel
    /// Optional so a preview can show the window without one. The picker is the only thing that
    /// needs it, and a preview of the permission rows should not have to build an `Appearance`.
    private var appearance: Appearance?

    public init(model: SettingsModel = SettingsModel(), appearance: Appearance? = nil) {
        _model = State(initialValue: model)
        self.appearance = appearance
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scale.space.section) {
                header
                if let appearance { ReadingRow(appearance: appearance) }
                ForEach(model.report.states) { PermissionRow(state: $0) }
            }
            .padding(scale.space.pad)
        }
        .frame(minWidth: Token.Panel.settingsMinWidth, minHeight: Token.Panel.settingsMinHeight)
        // macOS posts nothing when a permission changes, and the reader grants them in another app
        // and comes back. Polling is the only way to notice, and `.task` stops it when the window
        // goes away — which the hand-rolled controller had to remember to do itself.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: Token.Timing.permissionPoll)
            }
        }
    }

    /// Asking costs a ScreenCaptureKit round trip, so there is a moment before the answer. Saying
    /// so beats showing a verdict that is merely the empty state.
    private var verdict: String {
        guard model.hasAsked else { return "Checking…" }
        return model.report.allGranted ? "XiaolaiDict has everything it needs." : (model.report.menuWarning ?? "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            Text("Permissions")
                .font(.system(size: scale.text.display, weight: .semibold))
            // A verdict, not a list to add up. Both granted is the common case and deserves a
            // sentence rather than two ticks the reader has to interpret.
            Text(verdict)
                .font(.system(size: scale.text.body))
                .foregroundStyle(model.hasAsked && !model.report.allGranted
                                 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the reader chooses how XiaolaiDict's surfaces read.
///
/// macOS has no system-wide UI text size, so without this there is no way to change it at all —
/// and XiaolaiDict's surfaces are prose someone is trying to recall from, not chrome. The other two are
/// here for the same reason: what a card shows, and how it marks the word, are reading decisions
/// rather than implementation ones.
private struct ReadingRow: View {
    @Environment(\.scale) private var scale
    @Bindable var appearance: Appearance

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                Image(systemName: "textformat.size").foregroundStyle(.secondary)
                Text("Reading").font(.system(size: scale.text.heading, weight: .medium))
            }

            // A segmented picker rather than a slider: every step is a size the drawer has been
            // looked at, and a free number would let the reader build a layout nobody designed.
            Picker("Text size", selection: $appearance.textSize) {
                ForEach(TextSize.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Mark the word", selection: $appearance.emphasis) {
                ForEach(WordEmphasis.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Set in the chosen size and marked the chosen way, so the controls show what they do
            // rather than describing it.
            Text(specimenText)
                .foregroundStyle(.secondary)
                .lineSpacing(appearance.scale.text.leading)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Name the app a word was read in", isOn: $appearance.showsPlaceName)
                .font(.system(size: scale.text.label))
                .toggleStyle(.checkbox)

            Toggle("Show the time a word was looked up", isOn: $appearance.showsTime)
                .font(.system(size: scale.text.label))
                .toggleStyle(.checkbox)
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: scale.radius.panel, style: .continuous))
    }

    private var specimenText: AttributedString {
        var text = AttributedString("The quick brown fox jumps over the lazy dog.")
        if let marked = text.range(of: "jumps") {
            let chosen = appearance.emphasis
            var font = Font.system(size: appearance.scale.text.body, weight: chosen.weight)
            if chosen.isItalic { font = font.italic() }
            text[marked].font = font
            text[marked].foregroundColor = ReadingPalette.accents[
                ReadingPalette.index(for: "jumps")].color(in: .light)
        }
        return text
    }
}

private struct PermissionRow: View {
    @Environment(\.scale) private var scale
    let state: PermissionState

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.stack) {
            HStack(spacing: scale.space.inline) {
                Image(systemName: state.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.isGranted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                Text(state.permission.name).font(.system(size: scale.text.heading, weight: .medium))
                Spacer(minLength: scale.space.inline)
                Text(state.isGranted ? "On" : "Off")
                    .font(.system(size: scale.text.body, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(state.permission.blocks)
                .font(.system(size: scale.text.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !state.isGranted {
                Text(state.permission.location)
                    .font(.system(size: scale.text.label))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                HStack(spacing: scale.space.stack) {
                    // Asks macOS to prompt. It will do so only the first time ever, which is why
                    // the button beside it exists and why the list is named above.
                    Button("Ask macOS…") { state.permission.request() }
                        .buttonStyle(.glassProminent)
                    Button("Open Settings…") { NSWorkspace.shared.open(state.permission.settingsURL) }
                        .buttonStyle(.glass)
                }
                .controlSize(.small)
            }
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Glass, which on macOS 26 and later is what a raised surface is made of — the rounded
        // rectangle with a hand-drawn hairline it replaces was the pre-26 idiom.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: scale.radius.panel, style: .continuous))
    }
}


// MARK: - Previews

#if DEBUG
@MainActor private func settingsModel(_ states: [PermissionState]) -> SettingsModel {
    let model = SettingsModel()
    model.show(PermissionsReport(states: states))
    return model
}

/// The state worth designing against: something is off, so the row carries what stops working,
/// where to grant it, and the two buttons. The happy state is the one that needs no thought.
#Preview("A permission is off") {
    SettingsView(model: settingsModel([
        PermissionState(permission: .accessibility, isGranted: true),
        PermissionState(permission: .screenRecording, isGranted: false),
    ]))
}

#Preview("Both off") {
    SettingsView(model: settingsModel(Permission.allCases.map {
        PermissionState(permission: $0, isGranted: false)
    }))
}

#Preview("Everything granted") {
    SettingsView(model: settingsModel(Permission.allCases.map {
        PermissionState(permission: $0, isGranted: true)
    }))
}
#endif
