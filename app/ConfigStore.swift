import Foundation

/// Disk-level access to config.json. The proxy is the canonical writer
/// when it's running (via IPC update_rules); ConfigStore is the fallback
/// path for editing rules while the proxy is stopped.
struct ConfigFile: Codable {
    var version: Int = 1
    var enabled: Bool = true
    var resetHour: Int = 0
    var passwordRequired: Bool = false
    var rules: [IPCClient.RulePayload] = []
}

enum ConfigStore {
    static func path(dataDir: URL) -> URL {
        dataDir.appendingPathComponent("config.json")
    }

    static func load(dataDir: URL) throws -> ConfigFile {
        let url = path(dataDir: dataDir)
        if !FileManager.default.fileExists(atPath: url.path) {
            return ConfigFile()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ConfigFile.self, from: data)
    }

    /// Atomic write: encode → temp file → rename. Matches the proxy's
    /// SaveConfig so we don't ever leave a half-written file on disk.
    static func save(_ cfg: ConfigFile, dataDir: URL) throws {
        let url = path(dataDir: dataDir)
        let tmp = url.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cfg)
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
