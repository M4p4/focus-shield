import Foundation

/// Installs and removes the local root CA in the macOS System keychain.
/// Uses `osascript ... with administrator privileges` so the user sees a
/// native admin password prompt instead of us asking for it ourselves.
enum CertificateInstaller {
    static let caCommonName = "Bad Habit Blocker Root CA"

    enum CertError: LocalizedError {
        case caNotFound(String)
        case scriptFailed(Int32, String)
        case proxyHelperFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .caNotFound(let path): return "CA file not found at \(path). Try clicking 'Reinstall root CA'."
            case .scriptFailed(let code, let out): return "Admin command failed (\(code)): \(out)"
            case .proxyHelperFailed(let code, let out): return "Could not generate CA (\(code)): \(out)"
            }
        }
    }

    /// Asks the bundled proxy binary to generate the CA if missing.
    /// Returns the CA file path. Synchronous because we use it right before
    /// the install step.
    static func generateCAIfNeeded(proxyBinary: URL, dataDir: URL) throws -> URL {
        let caPath = dataDir.appendingPathComponent("ca.pem")
        if FileManager.default.fileExists(atPath: caPath.path) {
            return caPath
        }
        let proc = Process()
        proc.executableURL = proxyBinary
        proc.arguments = ["-data-dir", dataDir.path, "-gen-ca"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw CertError.proxyHelperFailed(proc.terminationStatus, out)
        }
        return caPath
    }

    /// True if a cert with the same common name is currently in the
    /// System keychain. We don't try to verify trust policies — presence
    /// is enough for an onboarding hint ("looks like you've installed it").
    static func isInstalledInSystemKeychain() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-certificate", "-c", caCommonName, "/Library/Keychains/System.keychain"]
        let null = Pipe()
        proc.standardOutput = null
        proc.standardError = null
        do {
            try proc.run()
        } catch {
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Run the trust-install command with an admin prompt.
    static func installAndTrust(caPath: URL) throws {
        guard FileManager.default.fileExists(atPath: caPath.path) else {
            throw CertError.caNotFound(caPath.path)
        }
        // The shell command security expects, escaped for AppleScript.
        let shellCmd = "/usr/bin/security add-trusted-cert -d -r trustRoot " +
            "-k /Library/Keychains/System.keychain " + shellEscape(caPath.path)
        try runAdmin(shell: shellCmd, prompt: "Bad Habit Blocker wants to install its local certificate so it can intercept HTTPS for the blocked sites.")
    }

    /// Remove the cert from the keychain (admin prompt).
    static func uninstallFromKeychain() throws {
        let shellCmd = "/usr/bin/security delete-certificate -c " +
            shellEscape(caCommonName) + " /Library/Keychains/System.keychain"
        try runAdmin(shell: shellCmd, prompt: "Bad Habit Blocker wants to remove its local certificate from the System keychain.")
    }

    // MARK: -

    private static func runAdmin(shell: String, prompt: String) throws {
        // osascript -e 'do shell script "..." with administrator privileges
        //   with prompt "..."'
        let escapedShell = appleScriptEscape(shell)
        let escapedPrompt = appleScriptEscape(prompt)
        let script = "do shell script \"\(escapedShell)\" with administrator privileges with prompt \"\(escapedPrompt)\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw CertError.scriptFailed(proc.terminationStatus, out)
        }
    }

    private static func shellEscape(_ s: String) -> String {
        // Single-quoted; embed any literal quotes by closing/escaping.
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
