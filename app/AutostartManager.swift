import Foundation
import ServiceManagement
import AppKit

/// Thin wrapper around SMAppService for "launch at login" on macOS 13+.
/// SMAppService.mainApp targets the app bundle the user double-clicked; on
/// first enable macOS may put us in .requiresApproval until the user
/// confirms in System Settings → Login Items. We surface that state in the
/// UI instead of silently failing.
enum AutostartManager {
    enum AutostartStatus: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unsupported
        case error(String)

        var humanLabel: String {
            switch self {
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            case .requiresApproval: return "Needs approval in System Settings"
            case .unsupported: return "Unsupported on this macOS version"
            case .error(let m): return "Error: \(m)"
            }
        }
    }

    static func current() -> AutostartStatus {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ on: Bool) -> Result<AutostartStatus, Error> {
        guard #available(macOS 13.0, *) else {
            return .failure(NSError(domain: "BHB", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Requires macOS 13 or later."
            ]))
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(current())
        } catch {
            return .failure(error)
        }
    }

    static func openLoginItemsSettings() {
        // macOS 13+ pane URL.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

