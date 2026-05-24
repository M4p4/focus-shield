import AppKit
import CoreGraphics

/// Reports whether the user is "actively using a browser" — i.e. the input
/// idle time is short AND macOS's frontmost app is a browser. Used by the
/// proxy tracker to ignore traffic from backgrounded YouTube tabs that
/// keep heartbeating even when the user isn't watching.
///
/// Polled rather than event-driven: NSWorkspace activation notifications
/// only fire on app switches, and input idle requires polling anyway, so
/// a single timer covers both. The interval matches the proxy's 5s flush
/// cadence — finer would just be wasted IPC traffic.
final class UserActivityMonitor {
    static let pollInterval: TimeInterval = 5.0
    static let idleThresholdSeconds: TimeInterval = 30.0

    /// Bundle identifiers we consider "a browser". Anything not in this
    /// list is treated as non-browser (we'd rather miss tracking on an
    /// obscure browser than over-count for, say, Slack pulling in a link
    /// preview).
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "company.thebrowser.Browser",        // Arc
        "company.thebrowser.dia",            // Dia
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Beta",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "org.chromium.Chromium",
        "com.duckduckgo.macos.browser",
        "com.kagi.kagimacOS",
    ]

    private var timer: Timer?
    private var lastReported: Bool?
    let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        // Tick once immediately so the proxy gets a baseline before any
        // requests can sneak through with the default-true gate.
        evaluate()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastReported = nil
    }

    private func evaluate() {
        let active = isBrowserFrontmost() && !isUserIdle()
        if lastReported != active {
            lastReported = active
            onChange(active)
        }
    }

    private func isBrowserFrontmost() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.browserBundleIDs.contains(id)
    }

    /// Seconds since the most recent HID event of any kind. Returns the
    /// shorter of mouse and keyboard idle times — CGEventSource doesn't
    /// expose "any HID" directly, so we sample both.
    private func isUserIdle() -> Bool {
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let scroll = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)
        let leftClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let mostRecent = [mouse, key, scroll, leftClick].min() ?? .greatestFiniteMagnitude
        return mostRecent > Self.idleThresholdSeconds
    }
}
