import Foundation

/// Wraps `networksetup` to point all network services at our local proxy and
/// to clear those settings on disable. We apply to every listed service rather
/// than guessing which is active — setting on inactive services is harmless
/// and survives Wi-Fi ⇄ Ethernet switches without extra plumbing.
final class SystemProxyManager {
    enum SystemProxyError: LocalizedError {
        case commandFailed(String, Int32, String)
        var errorDescription: String? {
            switch self {
            case .commandFailed(let cmd, let code, let out):
                return "\(cmd) failed (exit \(code)): \(out)"
            }
        }
    }

    /// Per-service errors are collected but never abort the loop — VPN
    /// tunnels and pseudo-interfaces (iPhone USB, Thunderbolt Bridge) often
    /// reject setwebproxy, but we still want Wi-Fi / Ethernet to succeed.
    /// Throws only if *no* service accepted the change.
    func enable(host: String, port: Int) throws {
        let services = try listNetworkServices()
        let bypass = [
            "localhost",
            "127.0.0.1",
            "*.local",
            "169.254/16",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
        ]
        var ok = 0
        var failures: [String] = []
        for svc in services {
            do {
                try run(["-setwebproxy", svc, host, "\(port)"])
                try run(["-setsecurewebproxy", svc, host, "\(port)"])
                try run(["-setproxybypassdomains", svc] + bypass)
                ok += 1
            } catch {
                failures.append("\(svc): \(error.localizedDescription)")
            }
        }
        if ok == 0 {
            throw SystemProxyError.commandFailed(
                "setwebproxy (all services)", 1,
                failures.joined(separator: "; "))
        }
    }

    func disable() throws {
        let services = try listNetworkServices()
        for svc in services {
            // Best-effort: don't abort the loop if a service can't be cleared.
            _ = try? run(["-setwebproxystate", svc, "off"])
            _ = try? run(["-setsecurewebproxystate", svc, "off"])
        }
    }

    // MARK: -

    private func listNetworkServices() throws -> [String] {
        let output = try captureOutput(["-listallnetworkservices"])
        // First line is a banner about disabled services prefixed with `*`.
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("An asterisk") }
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        return try captureOutput(args)
    }

    /// Reports whether any active network service still has its web/secure
    /// proxy pointing at the given host:port. Used at startup to detect
    /// orphan settings from a crash / force-quit.
    func isProxyConfigured(host: String, port: Int) -> Bool {
        guard let services = try? listNetworkServices() else { return false }
        let needle = host
        let portStr = "\(port)"
        for svc in services {
            for cmd in ["-getwebproxy", "-getsecurewebproxy"] {
                guard let out = try? captureOutput([cmd, svc]) else { continue }
                // Output is multi-line k:v; Enabled: Yes only counts if both
                // the server matches and the state is enabled.
                var enabled = false, hostMatch = false, portMatch = false
                for line in out.split(separator: "\n") {
                    let t = String(line).trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("Enabled:") {
                        enabled = t.lowercased().contains("yes")
                    } else if t.hasPrefix("Server:") {
                        hostMatch = t.contains(needle)
                    } else if t.hasPrefix("Port:") {
                        portMatch = t.contains(portStr)
                    }
                }
                if enabled && hostMatch && portMatch { return true }
            }
        }
        return false
    }

    private func captureOutput(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw SystemProxyError.commandFailed("networksetup " + args.joined(separator: " "), proc.terminationStatus, out)
        }
        return out
    }
}
