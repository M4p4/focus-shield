import SwiftUI

/// First-run wizard. Shows when the local root CA isn't installed in the
/// System keychain — without it, the proxy can't MITM HTTPS, so nothing
/// the rest of the app does is useful. Walks the user through it in one
/// click (which triggers the admin prompt) and dismisses on success.
struct OnboardingWindowView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome
    @State private var working = false
    @State private var error: String?

    enum Step {
        case welcome
        case installCert
        case done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text("Focus Shield")
                    .font(.title2).bold()
                Spacer()
            }

            Group {
                switch step {
                case .welcome:    welcomeStep
                case .installCert: installStep
                case .done:       doneStep
                }
            }

            Spacer()

            footerButtons
        }
        .padding(24)
        .frame(width: 480, height: 360)
    }

    // MARK: - steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Throttle or block the sites that distract you.")
                .font(.headline)
            Text("How it works:")
                .font(.subheadline).foregroundStyle(.secondary)
            bullet("A small proxy runs locally and inspects browser traffic.")
            bullet("Sites you mark as “Timed” unlock for N minutes per day.")
            bullet("Sites you mark as “Blocked” are blocked all day.")
            bullet("The proxy needs to intercept HTTPS, so you’ll install a local certificate next.")
        }
    }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install the local certificate")
                .font(.headline)
            Text("The proxy signs traffic with a private certificate that lives only on this Mac. To trust it, macOS will ask for your admin password once.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if state.caInstalled {
                Label("Certificate is installed.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("You're all set.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            Text("Click the shield in the menubar to flip Focus Shield ON. Open Settings to add the sites you want to limit.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.tertiary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - footer

    private var footerButtons: some View {
        HStack {
            if step == .welcome {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Continue") { step = .installCert }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if step == .installCert {
                Button("Back") { step = .welcome }
                Spacer()
                if state.caInstalled {
                    Button("Continue") { step = .done }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(working ? "Installing…" : "Install certificate") {
                        installNow()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Spacer()
                Button("Done") {
                    state.markOnboardingComplete()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func installNow() {
        error = nil
        working = true
        Task {
            do {
                try await state.installCertificate()
                await MainActor.run {
                    working = false
                    step = .done
                }
            } catch {
                await MainActor.run {
                    working = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
