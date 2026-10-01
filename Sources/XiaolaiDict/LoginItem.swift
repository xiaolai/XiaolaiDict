import ServiceManagement
import XiaolaiDictUI

/// **Opening at login, through the system's own login-item service.**
///
/// `SMAppService.mainApp` registers the running bundle itself — no helper, nothing installed —
/// and the reader sees and can undo it in System Settings › General › Login Items. It is in the
/// app target because it answers for the bundle that is running; Settings is handed three
/// closures and never imports this.
@MainActor
enum LoginItem {
    static var choice: LoginItemChoice {
        LoginItemChoice(
            status: { status },
            set: { set($0) },
            openSystemSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    /// **`.notFound` is "off", not "broken".** The service answers `.notFound` for a main app
    /// that has never been registered, as well as for one it cannot find, so reading it as an
    /// error would disable the switch on exactly the Mac where nobody has used it yet. A bundle
    /// that genuinely cannot be registered says so when `register()` throws, and that reason is
    /// what the reader is shown.
    static var status: LoginItemChoice.Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    /// Nil when it took; otherwise the system's own reason, for the reader.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
