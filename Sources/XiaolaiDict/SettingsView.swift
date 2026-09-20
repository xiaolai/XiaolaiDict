import AppKit
import Observation
import SwiftUI

@Observable
@MainActor
final class SettingsModel {
    /// Empty until the first probe answers. A window that said "everything is fine" before it had
    /// asked would be the same false green tick this whole probe exists to remove.
    var report = PermissionsReport(states: [])
    private(set) var hasAsked = false

    func refresh() async {
        report = await .probe()
        hasAsked = true
    }
}

struct SettingsView: View {
    @State private var model = SettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(model.report.states) { PermissionRow(state: $0) }
            }
            .padding(20)
        }
        .frame(minWidth: 420, minHeight: 320)
        // macOS posts nothing when a permission changes, and the reader grants them in another app
        // and comes back. Polling is the only way to notice, and `.task` stops it when the window
        // goes away — which the hand-rolled controller had to remember to do itself.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Permissions")
                .font(.system(size: 15, weight: .semibold))
            // A verdict, not a list to add up. Both granted is the common case and deserves a
            // sentence rather than two ticks the reader has to interpret.
            Text(verdict)
                .font(.system(size: 11.5))
                .foregroundStyle(model.hasAsked && !model.report.allGranted
                                 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow: View {
    let state: PermissionState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: state.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(state.isGranted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                Text(state.permission.name).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 6)
                Text(state.isGranted ? "On" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(state.permission.blocks)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !state.isGranted {
                Text(state.permission.location)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Glass, which on macOS 26 and later is what a raised surface is made of — the rounded
        // rectangle with a hand-drawn hairline it replaces was the pre-26 idiom.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
