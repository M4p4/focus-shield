import Foundation
import Combine

/// Shared, observable runtime state for the menubar UI. Owns the IPC client
/// lifecycle: opens when enabled, closes when disabled. The proxy writes
/// usage updates over IPC every 5s which we mirror into @Published state.
@MainActor
final class AppState: ObservableObject {
    struct SiteRow: Identifiable {
        var id: String { domain }
        let domain: String
        let mode: String
        let limitSeconds: Int?
        let elapsedSeconds: Int
    }

    @Published var enabled: Bool = false
    @Published var proxyStatus: ProxyStatus = .stopped
    @Published var lastError: String? = nil
    @Published private(set) var siteRows: [SiteRow] = []
    @Published private(set) var activeGrants: [IPCClient.ActiveGrant] = []
    @Published private(set) var ipcConnected: Bool = false
    @Published private(set) var passwordRequired: Bool = false
    @Published private(set) var passwordIsSet: Bool = false
    @Published private(set) var caInstalled: Bool = false
    @Published private(set) var autostart: AutostartManager.AutostartStatus = .disabled

    /// True when any timed site has reached its daily quota.
    /// Drives the yellow menubar icon state.
    var anyAtQuota: Bool {
        siteRows.contains { row in
            row.mode == "timed" && (row.limitSeconds ?? 0) > 0 && row.elapsedSeconds >= (row.limitSeconds ?? 0)
        }
    }

    /// True when an action that mutates state needs a password prompt:
    /// the gate flag is on AND a password is actually configured.
    var passwordGateActive: Bool { passwordRequired && passwordIsSet }

    private let proxy: ProxyController
    private let systemProxy: SystemProxyManager
    private var ipc: IPCClient?
    private var activityMonitor: UserActivityMonitor?
    private var networkMonitor: NetworkChangeMonitor?
    private var currentConfig: IPCClient.ConfigPayload?
    private var currentUsage: [String: Int] = [:]
    @Published private(set) var userActive: Bool = true

    let dataDir: URL
    private let socketPath: String

    init(proxy: ProxyController, systemProxy: SystemProxyManager) {
        self.proxy = proxy
        self.systemProxy = systemProxy
        self.dataDir = proxy.dataDirectory
        self.socketPath = proxy.dataDirectory
            .appendingPathComponent("proxy.sock").path
        self.proxy.statusHandler = { [weak self] status in
            Task { @MainActor in self?.proxyStatus = status }
        }
        // If the proxy keeps crashing, supervision gives up and signals
        // here so we can disable the system proxy — losing the internet
        // is worse than losing blocking.
        self.proxy.onSupervisionFailure = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.lastError = "Proxy failure: \(msg). System proxy disabled."
                try? self.systemProxy.disable()
                self.disconnectIPC()
                self.enabled = false
            }
        }
        // Sample environment state at boot. Onboarding triggers off
        // caInstalled; Settings reflects autostart.
        self.caInstalled = CertificateInstaller.isInstalledInSystemKeychain()
        self.autostart = AutostartManager.current()
    }

    var proxyBinaryURL: URL { proxy.binaryURL }

    /// Flip the on/off toggle. Enabling never needs a password (you can
    /// always turn protection ON). Disabling needs the current password
    /// when the gate is active — the caller must pass it; if the gate is
    /// active and password is empty, the call no-ops with an error. The
    /// menubar view handles the prompting and re-calls with the password.
    func setEnabled(_ on: Bool, password: String = "") {
        lastError = nil
        if on {
            do {
                try proxy.start()
                try systemProxy.enable(host: "127.0.0.1", port: 8888)
                enabled = true
                connectIPCAsync()
                startNetworkMonitoring()
            } catch {
                lastError = error.localizedDescription
                try? systemProxy.disable()
                proxy.stop()
                disconnectIPC()
                enabled = false
            }
        } else {
            if passwordGateActive && password.isEmpty {
                lastError = "Password required to disable."
                return
            }
            // Verify before tearing anything down.
            if passwordGateActive {
                Task {
                    let ok = await verifyPassword(password)
                    await MainActor.run {
                        if ok {
                            self.tearDown()
                        } else {
                            self.lastError = "Wrong password."
                        }
                    }
                }
                return
            }
            tearDown()
        }
    }

    private func tearDown() {
        stopNetworkMonitoring()
        disconnectIPC()
        do {
            try systemProxy.disable()
        } catch {
            lastError = error.localizedDescription
        }
        proxy.stop()
        enabled = false
        siteRows = []
        activeGrants = []
    }

    private func startNetworkMonitoring() {
        let m = NetworkChangeMonitor()
        m.onChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                // Reapply on the (potentially new) active services. Idempotent.
                do {
                    try self.systemProxy.enable(host: "127.0.0.1", port: 8888)
                } catch {
                    self.lastError = "Reapply on network change: \(error.localizedDescription)"
                }
            }
        }
        m.start()
        networkMonitor = m
    }

    private func stopNetworkMonitoring() {
        networkMonitor?.stop()
        networkMonitor = nil
    }

    func shutdownOnQuit() {
        disconnectIPC()
        try? systemProxy.disable()
        proxy.stop()
    }

    /// Persist rules and, if the proxy is up, push them via IPC so blocking
    /// behavior updates without restart. If the proxy isn't running we just
    /// write the file — the next toggle-on will pick it up. When the
    /// password gate is active, `password` must be the current password.
    func saveRules(_ rules: [IPCClient.RulePayload], password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // Local file write happens FIRST and unconditionally — that way
        // a wrong password (rejected by the proxy below) doesn't lose
        // unsaved edits. But we only commit if the proxy accepts the
        // change to keep file and runtime in lock-step.
        let runProxyUpdate: () async throws -> Void = { [weak self] in
            guard let self, let ipc = self.ipc, self.ipcConnected else { return }
            let id = UUID().uuidString
            _ = try await ipc.sendAwait(
                IPCClient.UpdateRulesRequest(id: id, rules: rules, password: password),
                id: id
            )
        }

        Task {
            do {
                if ipc != nil && ipcConnected {
                    try await runProxyUpdate()
                }
                var cfg = (try? ConfigStore.load(dataDir: dataDir)) ?? ConfigFile()
                cfg.rules = rules
                try ConfigStore.save(cfg, dataDir: dataDir)
                currentConfig = IPCClient.ConfigPayload(
                    enabled: cfg.enabled, rules: rules, passwordRequired: cfg.passwordRequired
                )
                rebuildRows()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Set or change the password. Empty `currentPassword` means "first time
    /// setting it." Throws if the proxy rejects (e.g. wrong current).
    func setPassword(current: String, new: String) async throws {
        guard let ipc, ipcConnected else { throw IPCClient.IPCError.disconnected }
        let id = UUID().uuidString
        _ = try await ipc.sendAwait(
            IPCClient.SetPasswordRequest(id: id, currentPassword: current, newPassword: new),
            id: id
        )
        passwordIsSet = true
    }

    /// Turn the password gate on or off. When disabling, `currentPassword`
    /// must be the existing one — the proxy refuses to clear without it.
    func setPasswordRequired(_ on: Bool, currentPassword: String) async throws {
        guard let ipc, ipcConnected else { throw IPCClient.IPCError.disconnected }
        let id = UUID().uuidString
        _ = try await ipc.sendAwait(
            IPCClient.SetPasswordRequiredRequest(id: id, enabled: on, password: currentPassword),
            id: id
        )
        passwordRequired = on
        if !on {
            passwordIsSet = false
        }
    }

    // MARK: - onboarding / autostart / reset

    var needsOnboarding: Bool {
        !caInstalled
    }

    /// Triggered by the onboarding wizard. Generates the CA via the proxy
    /// helper (one-shot), then runs the trust-install command. macOS shows
    /// its own admin prompt.
    func installCertificate() async throws {
        let caPath = try CertificateInstaller.generateCAIfNeeded(
            proxyBinary: proxyBinaryURL, dataDir: dataDir
        )
        try await Task.detached(priority: .userInitiated) {
            try CertificateInstaller.installAndTrust(caPath: caPath)
        }.value
        caInstalled = CertificateInstaller.isInstalledInSystemKeychain()
    }

    /// Called by the Reinstall button on the General tab. Same as install
    /// but always re-runs the security cmd even when the cert is present
    /// — useful if trust got revoked manually.
    func reinstallCertificate() async throws {
        let caPath = try CertificateInstaller.generateCAIfNeeded(
            proxyBinary: proxyBinaryURL, dataDir: dataDir
        )
        try await Task.detached(priority: .userInitiated) {
            try CertificateInstaller.installAndTrust(caPath: caPath)
        }.value
        caInstalled = CertificateInstaller.isInstalledInSystemKeychain()
    }

    /// Final step of the wizard — nothing on disk to mark; we infer
    /// onboarding completion from caInstalled. Hook for future state.
    func markOnboardingComplete() { /* no-op; presence of CA is enough */ }

    func setAutostart(_ on: Bool) {
        switch AutostartManager.setEnabled(on) {
        case .success(let status):
            autostart = status
        case .failure(let err):
            lastError = "Autostart: \(err.localizedDescription)"
            autostart = AutostartManager.current()
        }
    }

    /// Reset everything: stop proxy, disable system proxy, wipe data dir,
    /// remove CA from keychain (admin prompt), disable autostart. Keeps
    /// the .app binary on disk so the user can delete it themselves.
    /// The caller is expected to confirm + (if gate active) verify password.
    func resetEverything() async throws {
        // 1. Tear down runtime state.
        tearDown()

        // 2. Disable autostart (best-effort, user can also do via System Settings).
        _ = AutostartManager.setEnabled(false)
        autostart = AutostartManager.current()

        // 3. Remove CA from keychain (admin prompt).
        try await Task.detached(priority: .userInitiated) {
            try CertificateInstaller.uninstallFromKeychain()
        }.value
        caInstalled = false

        // 4. Wipe the data dir. Done last so a failed keychain removal
        // doesn't leave us with secrets-already-deleted but cert-still-trusted.
        let fm = FileManager.default
        if fm.fileExists(atPath: dataDir.path) {
            try fm.removeItem(at: dataDir)
        }
        passwordRequired = false
        passwordIsSet = false
        currentConfig = nil
        currentUsage = [:]
        siteRows = []
    }

    /// Pull a fresh usage snapshot from the proxy. The proxy normally pushes
    /// every 5s; the menubar view calls this on open and on each 1Hz tick
    /// while the popover is visible so the TODAY counters don't look frozen.
    /// No-ops cleanly if IPC isn't up.
    func refreshFromProxy() {
        guard let ipc, ipcConnected else { return }
        try? ipc.send(IPCClient.GetUsageRequest(id: "menu-refresh"))
    }

    /// Verifies a password without changing state. Used by Quit / menubar
    /// gating where we just need a yes/no.
    func verifyPassword(_ password: String) async -> Bool {
        guard let ipc, ipcConnected else { return false }
        let id = UUID().uuidString
        do {
            let resp = try await ipc.sendAwait(
                IPCClient.VerifyPasswordRequest(id: id, password: password),
                id: id
            )
            return resp.result?.valid ?? false
        } catch {
            return false
        }
    }

    // MARK: - IPC plumbing

    private func connectIPCAsync() {
        let client = IPCClient(socketPath: socketPath)
        self.ipc = client

        client.onMessage = { [weak self] msg in
            Task { @MainActor in self?.handleIPCMessage(msg) }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.ipcConnected = false
            }
        }

        // The proxy was spawned a few ms ago; connect with retries.
        Task.detached(priority: .utility) {
            do {
                try client.connect(timeout: 3.0)
                await MainActor.run { [weak self] in
                    self?.ipcConnected = true
                    self?.startActivityMonitoring()
                }
                try client.send(IPCClient.GetConfigRequest(id: "init-cfg"))
                try client.send(IPCClient.GetUsageRequest(id: "init-usage"))
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "IPC connect failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func disconnectIPC() {
        activityMonitor?.stop()
        activityMonitor = nil
        ipc?.close()
        ipc = nil
        ipcConnected = false
    }

    /// Start polling user activity once IPC is up. The monitor only fires
    /// the callback on transitions, so we won't spam the proxy.
    private func startActivityMonitoring() {
        let monitor = UserActivityMonitor { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                self.userActive = active
                guard let ipc = self.ipc, self.ipcConnected else { return }
                try? ipc.send(IPCClient.SetUserActiveRequest(id: UUID().uuidString, active: active))
            }
        }
        monitor.start()
        activityMonitor = monitor
    }

    private func handleIPCMessage(_ msg: IPCClient.Message) {
        if let usage = msg.result?.usage {
            currentUsage = usage
        }
        if let cfg = msg.result?.config {
            currentConfig = cfg
            passwordRequired = cfg.passwordRequired ?? false
        }
        if let isSet = msg.result?.passwordIsSet {
            passwordIsSet = isSet
        }
        if let grants = msg.result?.activeGrants {
            activeGrants = grants
        }
        rebuildRows()
    }

    private func rebuildRows() {
        guard let cfg = currentConfig else {
            siteRows = []
            return
        }
        siteRows = cfg.rules.map { r in
            SiteRow(
                domain: r.domain,
                mode: r.mode,
                limitSeconds: r.dailyLimitSeconds,
                elapsedSeconds: currentUsage[r.domain] ?? 0
            )
        }
    }
}
