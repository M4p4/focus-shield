import Foundation

enum ProxyStatus: Equatable {
    case stopped
    case running(pid: Int32)
    case failed(String)
}

/// Spawns and supervises the bundled bhb-proxy Go binary. Logs to a file
/// in the data dir. Supervises: if the proxy exits while we expected it
/// to be running, restart it. After too many crashes in a short window,
/// give up and surface a failure so the app can disable the system proxy
/// — losing the internet is worse than losing blocking.
final class ProxyController {
    let binaryURL: URL
    private let dataDir: URL
    private let logURL: URL

    private var process: Process?
    private var logHandle: FileHandle?

    /// True between start() and stop() — i.e. "user wants this running".
    /// An exit while supervising is unexpected and triggers a restart.
    private var supervising = false

    private let crashWindow: TimeInterval = 30
    private let maxCrashes = 3
    private var recentCrashes: [Date] = []

    var statusHandler: ((ProxyStatus) -> Void)?
    /// Fires when supervision gives up. Callers should disable system
    /// proxy so the user can browse normally.
    var onSupervisionFailure: ((String) -> Void)?

    init() throws {
        let bundled = Bundle.main.url(forResource: "bhb-proxy", withExtension: nil)
        let repoLocal = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/bhb-proxy")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            self.binaryURL = bundled
        } else if FileManager.default.isExecutableFile(atPath: repoLocal.path) {
            self.binaryURL = repoLocal
        } else {
            throw NSError(domain: "BHB", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "bhb-proxy binary not found in app bundle or build/"
            ])
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        self.dataDir = home
            .appendingPathComponent("Library/Application Support/BadHabitBlocker", isDirectory: true)
        let logsDir = dataDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logURL = logsDir.appendingPathComponent("proxy.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
    }

    /// User-initiated start. After this, exits are treated as crashes.
    func start() throws {
        supervising = true
        try launchOnce()
    }

    /// User-initiated stop. Disables supervision so the impending exit
    /// is recorded as normal, not a crash.
    func stop() {
        supervising = false
        guard let p = process, p.isRunning else {
            process = nil
            statusHandler?(.stopped)
            return
        }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
            self?.process = nil
            try? self?.logHandle?.close()
            self?.logHandle = nil
            self?.statusHandler?(.stopped)
        }
    }

    var dataDirectory: URL { dataDir }

    // MARK: - private

    private func launchOnce() throws {
        if let existing = process, existing.isRunning {
            return
        }
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["-data-dir", dataDir.path]

        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        let header = "\n----- bhb-proxy launched at \(Date()) -----\n"
        if let data = header.data(using: .utf8) { handle.write(data) }
        proc.standardOutput = handle
        proc.standardError = handle

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.handleExit(p)
            }
        }

        try proc.run()
        self.process = proc
        self.logHandle = handle
        statusHandler?(.running(pid: proc.processIdentifier))
    }

    private func handleExit(_ p: Process) {
        try? logHandle?.close()
        logHandle = nil
        process = nil

        if !supervising {
            // Normal stop — already reported by stop() above.
            return
        }

        let now = Date()
        recentCrashes.append(now)
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < crashWindow }

        let msg = "proxy exited unexpectedly (status=\(p.terminationStatus)) — restart #\(recentCrashes.count)"
        statusHandler?(.failed(msg))

        if recentCrashes.count > maxCrashes {
            supervising = false
            let detail = "proxy crashed \(recentCrashes.count) times in \(Int(crashWindow))s — giving up"
            statusHandler?(.failed(detail))
            onSupervisionFailure?(detail)
            return
        }

        // Quick backoff so we don't spin if the proxy fails at startup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.supervising else { return }
            do {
                try self.launchOnce()
            } catch {
                self.statusHandler?(.failed("restart failed: \(error.localizedDescription)"))
                self.supervising = false
                self.onSupervisionFailure?("restart failed: \(error.localizedDescription)")
            }
        }
    }
}
