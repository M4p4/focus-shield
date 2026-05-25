import SwiftUI

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var pendingAction: PendingAction? = nil

    enum PendingAction: Identifiable {
        case disable
        case quit
        var id: String {
            switch self { case .disable: return "disable"; case .quit: return "quit" }
        }
    }

    /// Ticks 1Hz so the active-bypass countdown updates between IPC
    /// pushes. SwiftUI re-renders the view body each tick because `tick`
    /// is @State.
    @State private var tick = Date()
    private let secondTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if !state.activeGrants.isEmpty {
                sectionDivider
                bypassSection
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            if !state.siteRows.isEmpty {
                sectionDivider
                sitesSection
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            sectionDivider

            // Menu-style action rows (Settings, Quit). Mimics native
            // NSMenu items: hover highlight, right-aligned shortcut.
            VStack(spacing: 1) {
                MenuRow(label: "Open Settings…", shortcut: "⌘,") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
                MenuRow(label: "Quit Focus Shield", shortcut: "⌘Q") {
                    handleQuit()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 5)
        }
        .frame(width: 290)
        .onAppear { state.refreshFromProxy() }
        .onReceive(secondTimer) { now in
            tick = now
            state.refreshFromProxy()
        }
        .sheet(item: $pendingAction) { action in
            PasswordPrompt(mode: .verify(prompt: promptText(for: action))) { result in
                guard let result else { return }
                applyAction(action, password: result.new)
            }
        }
    }

    // MARK: - sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("Focus Shield")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { state.enabled },
                    set: { handleToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let err = state.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
    }

    /// Yellow strip listing every site currently under a temporary
    /// "unlock anyway" grant, with a live countdown to expiry.
    private var bypassSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark.fill")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 11))
                Text("UNLOCKED")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }
            VStack(spacing: 4) {
                ForEach(state.activeGrants, id: \.domain) { grant in
                    bypassRow(grant)
                }
            }
        }
    }

    @ViewBuilder
    private func bypassRow(_ grant: IPCClient.ActiveGrant) -> some View {
        let remaining = max(0, Int(grant.expiresAt.timeIntervalSince(tick)))
        HStack(spacing: 8) {
            Text(grant.domain)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(remainingLabel(seconds: remaining))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(remaining < 30 ? .red : .orange)
        }
    }

    private func remainingLabel(seconds: Int) -> String {
        if seconds <= 0 { return "expiring…" }
        let m = seconds / 60
        let s = seconds % 60
        if m == 0 { return "\(s)s left" }
        return String(format: "%dm %02ds left", m, s)
    }

    private var sitesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            VStack(spacing: 6) {
                ForEach(state.siteRows) { row in
                    siteRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func siteRow(_ row: AppState.SiteRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.domain)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(rightLabel(row))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(rightLabelColor(row))
            }
            if row.mode == "timed", let limit = row.limitSeconds, limit > 0 {
                ProgressView(value: Double(min(row.elapsedSeconds, limit)), total: Double(limit))
                    .progressViewStyle(.linear)
                    .tint(row.elapsedSeconds >= limit ? .red : .accentColor)
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    // MARK: - actions

    private func handleToggle(_ on: Bool) {
        if !on && state.passwordGateActive {
            pendingAction = .disable
        } else {
            state.setEnabled(on)
        }
    }

    private func handleQuit() {
        if state.passwordGateActive {
            pendingAction = .quit
        } else {
            state.shutdownOnQuit()
            NSApplication.shared.terminate(nil)
        }
    }

    private func promptText(for action: PendingAction) -> String {
        switch action {
        case .disable: return "Enter your password to turn off Focus Shield."
        case .quit:    return "Enter your password to quit."
        }
    }

    private func applyAction(_ action: PendingAction, password: String) {
        switch action {
        case .disable:
            state.setEnabled(false, password: password)
        case .quit:
            Task {
                let ok = await state.verifyPassword(password)
                await MainActor.run {
                    if ok {
                        state.shutdownOnQuit()
                        NSApplication.shared.terminate(nil)
                    } else {
                        state.lastError = "Wrong password."
                    }
                }
            }
        }
    }

    // MARK: - status helpers

    private func rightLabel(_ row: AppState.SiteRow) -> String {
        switch row.mode {
        case "blocked": return "blocked"
        case "timed":
            if let limit = row.limitSeconds {
                return "\(fmt(row.elapsedSeconds)) / \(fmt(limit))"
            }
            return fmt(row.elapsedSeconds)
        default:
            return row.mode
        }
    }

    private func rightLabelColor(_ row: AppState.SiteRow) -> Color {
        if row.mode == "blocked" { return .red }
        if let limit = row.limitSeconds, limit > 0, row.elapsedSeconds >= limit {
            return .red
        }
        return .secondary
    }

    private func fmt(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m == 0 { return "\(s)s" }
        return String(format: "%dm %02ds", m, s)
    }

    private var statusColor: Color {
        if !state.enabled { return .secondary }
        switch state.proxyStatus {
        case .running: return state.ipcConnected ? .green : .yellow
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        if !state.enabled { return "Off" }
        switch state.proxyStatus {
        case .running:
            if !state.ipcConnected { return "Active — connecting…" }
            return state.userActive ? "Active — tracking" : "Active — paused (no browser focus)"
        case .stopped: return "Off"
        case .failed(let m): return "Failed: \(m)"
        }
    }
}

// MARK: - MenuRow

/// A button styled to feel like a native NSMenuItem: full-width hit area,
/// hover highlight in the system accent color, optional right-aligned
/// shortcut hint. Keeps the menubar popover looking like macOS instead of
/// a generic SwiftUI window.
private struct MenuRow: View {
    let label: String
    let shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(hovering ? Color.white : Color.primary)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(keyboardShortcut)
    }

    /// Translate the visual shortcut hint into an actual keyEquivalent so
    /// pressing the keys actually fires the action. Only handles the
    /// "⌘<letter>" / "⌘," shape we use here.
    private var keyboardShortcut: KeyboardShortcut? {
        guard let s = shortcut, s.hasPrefix("⌘"), let ch = s.dropFirst().first else { return nil }
        // Lowercase the letter; comma stays as-is.
        let key = KeyEquivalent(Character(ch.lowercased()))
        return KeyboardShortcut(key)
    }
}
