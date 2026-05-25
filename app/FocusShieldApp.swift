import SwiftUI
import AppKit

/// Catches every termination path (Cmd+Q from any window, Apple menu →
/// Quit, sigterm from the dock) and runs cleanup. The popover Quit button
/// calls AppState.shutdownOnQuit directly, but anything else would leave
/// the macOS system proxy pointing at our address with no proxy listening —
/// which manifests as "no website loads anywhere."
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        state?.shutdownOnQuit()
    }
}

@main
struct FocusShieldApp: App {
    @StateObject private var state: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        do {
            let proxy = try ProxyController()
            let sys = SystemProxyManager()

            // Self-heal: if a previous run was force-quit while enabled,
            // the system proxy still points at us. Clear it now so the
            // user can browse normally until they toggle ON again.
            if sys.isProxyConfigured(host: "127.0.0.1", port: 8888) {
                NSLog("[FocusShield] orphan system proxy detected on startup — clearing")
                try? sys.disable()
            }

            let appState = AppState(proxy: proxy, systemProxy: sys)
            _state = StateObject(wrappedValue: appState)
        } catch {
            fatalError("FocusShield init failed: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: state, appDelegate: appDelegate)
        } label: {
            Image(systemName: state.enabled ? "shield.fill" : "shield")
                .foregroundStyle(iconTint)
        }
        .menuBarExtraStyle(.window)

        Window("Focus Shield — Settings", id: "settings") {
            SettingsWindowView(state: state)
        }
        .defaultSize(width: 620, height: 440)

        Window("Welcome — Focus Shield", id: "onboarding") {
            OnboardingWindowView(state: state)
        }
        .defaultSize(width: 480, height: 360)
        .windowResizability(.contentSize)
    }

    private var iconTint: Color {
        if !state.enabled { return .primary }
        return state.anyAtQuota ? .yellow : .green
    }
}

/// Small wrapper so we can use the SwiftUI `openWindow` environment value
/// (which requires being inside a View) to open the onboarding wizard on
/// first launch. Subsequent re-renders see caInstalled=true and skip.
private struct MenuBarContent: View {
    @ObservedObject var state: AppState
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var onboardingShown = false

    var body: some View {
        MenuBarView(state: state)
            .onAppear {
                appDelegate.state = state
                if state.needsOnboarding && !onboardingShown {
                    onboardingShown = true
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                }
            }
    }
}
