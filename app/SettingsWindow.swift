import SwiftUI

enum RuleMode: String, CaseIterable, Identifiable {
    case off, timed, blocked
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .timed: return "Timed"
        case .blocked: return "Blocked"
        }
    }
}

/// Editable mirror of a rule. Decoupled from IPCClient.RulePayload so the
/// form can hold UI-only state (e.g. a minutes string mid-typing).
struct DraftRule: Identifiable {
    var id: String
    var domain: String
    var mode: RuleMode
    var dailyLimitMinutes: Int

    static func new() -> DraftRule {
        DraftRule(id: UUID().uuidString, domain: "", mode: .timed, dailyLimitMinutes: 30)
    }

    init(id: String, domain: String, mode: RuleMode, dailyLimitMinutes: Int) {
        self.id = id
        self.domain = domain
        self.mode = mode
        self.dailyLimitMinutes = dailyLimitMinutes
    }

    init(payload: IPCClient.RulePayload) {
        self.id = payload.id
        self.domain = payload.domain
        self.mode = RuleMode(rawValue: payload.mode) ?? .off
        self.dailyLimitMinutes = max(1, (payload.dailyLimitSeconds ?? 0) / 60)
    }

    func toPayload() -> IPCClient.RulePayload {
        IPCClient.RulePayload(
            id: id,
            domain: domain.trimmingCharacters(in: .whitespaces).lowercased(),
            matchSubdomains: true,
            mode: mode.rawValue,
            dailyLimitSeconds: mode == .timed ? max(60, dailyLimitMinutes * 60) : nil
        )
    }
}

struct SettingsWindowView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            SitesTab(state: state)
                .tabItem { Label("Sites", systemImage: "list.bullet") }
            SecurityTab(state: state)
                .tabItem { Label("Security", systemImage: "lock") }
            GeneralTab(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutTab(state: state)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 380, idealHeight: 440)
    }
}

struct SecurityTab: View {
    @ObservedObject var state: AppState
    @State private var error: String? = nil
    @State private var info: String? = nil

    @State private var showCreatePrompt = false
    @State private var showChangePrompt = false
    @State private var showDisablePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Require password for bypass and disabling", isOn: Binding(
                get: { state.passwordRequired },
                set: { handleToggle($0) }
            ))
            .toggleStyle(.switch)
            .padding(.bottom, 4)

            Text("When on, your password is needed to disable Bad Habit Blocker, edit rules, and use the “unlock anyway” button on the block page.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if state.passwordIsSet {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("A password is set.")
                    Spacer()
                    Button("Change password") { showChangePrompt = true }
                }
            } else {
                HStack {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text("No password set yet.")
                    Spacer()
                    Button("Set password") { showCreatePrompt = true }
                }
            }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else if let info {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Text("Forgot your password? You can wipe everything (config, usage, secret) from the About tab’s “Reset everything” action — coming in M9.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showCreatePrompt) {
            PasswordPrompt(mode: .create(prompt: "Choose a password.")) { result in
                guard let result else { return }
                Task { await setNewPassword(current: "", new: result.new) }
            }
        }
        .sheet(isPresented: $showChangePrompt) {
            PasswordPrompt(mode: .change(prompt: "Enter your current password and a new one.")) { result in
                guard let result else { return }
                Task { await setNewPassword(current: result.current, new: result.new) }
            }
        }
        .sheet(isPresented: $showDisablePrompt) {
            PasswordPrompt(mode: .verify(prompt: "Enter your current password to turn off the gate.")) { result in
                guard let result else { return }
                Task { await disableGate(currentPassword: result.new) }
            }
        }
    }

    private func handleToggle(_ on: Bool) {
        error = nil; info = nil
        if on {
            // Enabling: a password must exist. Prompt for one first.
            if state.passwordIsSet {
                Task { await enableGate() }
            } else {
                showCreatePrompt = true
            }
        } else {
            // Disabling: require the current password.
            if state.passwordIsSet {
                showDisablePrompt = true
            } else {
                Task { await disableGate(currentPassword: "") }
            }
        }
    }

    private func setNewPassword(current: String, new: String) async {
        do {
            try await state.setPassword(current: current, new: new)
            info = "Password saved."
            // If the toggle is on but the gate wasn't active (no pw set),
            // enabling becomes possible — auto-flip ON for convenience.
            if !state.passwordRequired {
                try await state.setPasswordRequired(true, currentPassword: "")
                info = "Password saved and gate turned on."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func enableGate() async {
        do {
            try await state.setPasswordRequired(true, currentPassword: "")
            info = "Gate turned on."
        } catch { self.error = error.localizedDescription }
    }

    private func disableGate(currentPassword: String) async {
        do {
            try await state.setPasswordRequired(false, currentPassword: currentPassword)
            info = "Gate turned off."
        } catch { self.error = error.localizedDescription }
    }
}

struct GeneralTab: View {
    @ObservedObject var state: AppState
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Autostart
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.autostart == .enabled },
                    set: { state.setAutostart($0) }
                ))
                .toggleStyle(.switch)
                Spacer()
                Text(state.autostart.humanLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.autostart == .requiresApproval {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("macOS needs you to approve this in System Settings.")
                        .font(.caption)
                    Button("Open Login Items…") {
                        AutostartManager.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            // Certificate
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local root certificate")
                    if state.caInstalled {
                        Label("Installed in System keychain", systemImage: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(working ? "Working…" : "Reinstall root CA") {
                    error = nil
                    working = true
                    Task {
                        do { try await state.reinstallCertificate() }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }
                .disabled(working)
            }
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AboutTab: View {
    @ObservedObject var state: AppState
    @State private var showResetConfirm = false
    @State private var showPasswordPrompt = false
    @State private var resetting = false
    @State private var error: String?
    @State private var info: String?

    private let version: String = Bundle.main
        .infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Bad Habit Blocker").font(.title2).bold()
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)

            Button("Open logs folder") {
                let logs = state.dataDir.appendingPathComponent("logs", isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([logs])
            }

            Divider()

            Text("Reset")
                .font(.headline)
            Text("Stops Bad Habit Blocker, removes the local certificate from your keychain, disables Launch at Login, clears system proxy settings, and deletes config / usage / password. The app stays installed — drag it to the Trash to remove the binary.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) {
                attemptReset()
            } label: {
                Text(resetting ? "Resetting…" : "Reset everything…")
            }
            .disabled(resetting)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
            if let info {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Reset everything?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                if state.passwordGateActive {
                    showPasswordPrompt = true
                } else {
                    performReset()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This wipes your config, usage, password, and removes the trusted certificate. The app stays on disk. This cannot be undone.")
        }
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPrompt(mode: .verify(prompt: "Enter your password to confirm the reset.")) { result in
                guard let result else { return }
                Task {
                    let ok = await state.verifyPassword(result.new)
                    await MainActor.run {
                        if ok {
                            performReset()
                        } else {
                            error = "Wrong password — reset cancelled."
                        }
                    }
                }
            }
        }
    }

    private func attemptReset() {
        error = nil; info = nil
        showResetConfirm = true
    }

    private func performReset() {
        resetting = true
        Task {
            do {
                try await state.resetEverything()
                await MainActor.run {
                    resetting = false
                    info = "Everything has been reset. Drag the app to Trash to finish removing it."
                }
            } catch {
                await MainActor.run {
                    resetting = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private struct PlaceholderTab: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title2).bold()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct SitesTab: View {
    @ObservedObject var state: AppState
    @State private var drafts: [DraftRule] = []
    @State private var saveError: String? = nil
    @State private var saveStatus: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if drafts.isEmpty {
                emptyState
            } else {
                rulesList
            }

            Divider()
            footer
        }
        .onAppear { if !loaded { reload() } }
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPrompt(mode: .verify(prompt: "Confirm the change with your password.")) { result in
                guard let result, let payloads = pendingPayloads else {
                    pendingPayloads = nil
                    return
                }
                pendingPayloads = nil
                commit(payloads, password: result.new)
            }
        }
    }

    // MARK: - sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tracked sites")
                    .font(.headline)
                Text("Subdomains and known CDN hosts are matched automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                drafts.append(DraftRule.new())
            } label: {
                Label("Add site", systemImage: "plus")
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No sites yet")
                .foregroundStyle(.secondary)
            Button("Add your first site") {
                drafts.append(DraftRule.new())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rulesList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach($drafts) { $draft in
                    SiteRow(draft: $draft) {
                        drafts.removeAll { $0.id == draft.id }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack {
            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if !saveStatus.isEmpty {
                Text(saveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") { reload() }
            Button("Save") { save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
        }
        .padding(12)
    }

    // MARK: - logic

    private var isValid: Bool {
        // Every draft must have a non-empty domain (cheap client-side guard).
        drafts.allSatisfy { !$0.domain.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func reload() {
        do {
            let cfg = try ConfigStore.load(dataDir: state.dataDir)
            drafts = cfg.rules.map { DraftRule(payload: $0) }
            loaded = true
            saveStatus = ""
            saveError = nil
        } catch {
            saveError = "Load failed: \(error.localizedDescription)"
        }
    }

    @State private var showPasswordPrompt = false
    @State private var pendingPayloads: [IPCClient.RulePayload]?

    private func save() {
        let payloads = drafts.map { $0.toPayload() }
        if state.passwordGateActive {
            pendingPayloads = payloads
            showPasswordPrompt = true
        } else {
            commit(payloads, password: "")
        }
    }

    private func commit(_ payloads: [IPCClient.RulePayload], password: String) {
        state.saveRules(payloads, password: password) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    saveError = nil
                    saveStatus = "Saved"
                case .failure(let err):
                    saveError = err.localizedDescription
                    saveStatus = ""
                }
            }
        }
    }
}


private struct SiteRow: View {
    @Binding var draft: DraftRule
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("example.com", text: $draft.domain)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180)

            Picker("", selection: $draft.mode) {
                ForEach(RuleMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            if draft.mode == .timed {
                HStack(spacing: 4) {
                    TextField("", value: $draft.dailyLimitMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("min/day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Spacer to keep delete button column-aligned regardless of mode.
                Spacer().frame(width: 120)
            }

            Spacer()

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
    }
}
