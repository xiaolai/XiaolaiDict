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

/// XiaolaiDict's settings window, whose first job is to make the permissions visible.
///
/// **This window activates XiaolaiDict, and the panel rule does not apply to it.** A panel must never take
/// focus because it arrives while the reader is mid-sentence in another app; this window arrives
/// only because the reader chose it from the menu, and a settings window that cannot be typed in or
/// clicked into would be useless.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsModel()
    private var watching: Task<Void, Never>?

    /// macOS posts nothing when a permission changes, and the reader grants them in another app and
    /// comes back — so the window asks again while it is open. Polling is the only way to notice,
    /// and it stops the moment the window closes.
    static let refreshInterval: Duration = .seconds(1)

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Accessory apps have no Dock icon and do not come forward on their own.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
        startWatching()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "XiaolaiDict Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        return window
    }

    private func startWatching() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self, self.window?.isVisible == true else { return }
                await self.model.refresh()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        watching?.cancel()
        watching = nil
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(model.report.states) { PermissionRow(state: $0) }
            }
            .padding(20)
        }
        .frame(minWidth: 420, minHeight: 320)
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
