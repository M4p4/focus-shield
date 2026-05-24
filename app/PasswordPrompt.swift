import SwiftUI

/// A reusable modal sheet for collecting a password (or a new-password +
/// confirmation pair). Decoupled from any specific action — the caller
/// receives the entered string(s) via the result callback.
struct PasswordPrompt: View {
    enum Mode {
        case verify(prompt: String)              // single password field
        case create(prompt: String)              // new + confirm
        case change(prompt: String)              // current + new + confirm
    }

    let mode: Mode
    /// Result is the password(s) the user entered:
    /// - .verify: (current: "", new: typed)   // we put input into `new` slot for simplicity
    /// - .create: (current: "", new: typed)
    /// - .change: (current: typedCurrent, new: typedNew)
    /// `nil` ⇒ cancelled.
    let onResult: ((current: String, new: String)?) -> Void

    @State private var current: String = ""
    @State private var new: String = ""
    @State private var confirm: String = ""
    @State private var error: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(promptText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                if case .change = mode {
                    labelled("Current password") {
                        SecureField("", text: $current)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                switch mode {
                case .verify:
                    labelled("Password") {
                        SecureField("", text: $new)
                            .textFieldStyle(.roundedBorder)
                    }
                case .create, .change:
                    labelled("New password") {
                        SecureField("", text: $new)
                            .textFieldStyle(.roundedBorder)
                    }
                    labelled("Confirm") {
                        SecureField("", text: $confirm)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onResult(nil)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private func labelled(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private var title: String {
        switch mode {
        case .verify: return "Password required"
        case .create: return "Set a password"
        case .change: return "Change password"
        }
    }

    private var promptText: String {
        switch mode {
        case .verify(let p), .create(let p), .change(let p): return p
        }
    }

    private func submit() {
        switch mode {
        case .verify:
            guard !new.isEmpty else { error = "Enter your password."; return }
            onResult((current: "", new: new))
            dismiss()
        case .create:
            guard !new.isEmpty else { error = "Enter a password."; return }
            guard new == confirm else { error = "Passwords don't match."; return }
            onResult((current: "", new: new))
            dismiss()
        case .change:
            guard !current.isEmpty else { error = "Enter the current password."; return }
            guard !new.isEmpty else { error = "Enter a new password."; return }
            guard new == confirm else { error = "Passwords don't match."; return }
            onResult((current: current, new: new))
            dismiss()
        }
    }
}
