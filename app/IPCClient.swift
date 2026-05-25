import Foundation
import Darwin

private let isoFracFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoBaseFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Newline-delimited JSON over a Unix domain socket. Each line is one
/// message: either an inbound event (no `id`) or a reply to a request
/// (matching `id`). M4 doesn't need request/response correlation —
/// AppState only consumes push events — but the protocol shape supports
/// it once M5 starts using update_rules / set_enabled from the UI.
final class IPCClient {
    struct Message: Decodable {
        let type: String?
        let id: String?
        let ok: Bool?
        let error: String?
        let result: Result?

        struct Result: Decodable {
            let usage: [String: Int]?
            let config: ConfigPayload?
            let passwordIsSet: Bool?
            let valid: Bool?
            let activeGrants: [ActiveGrant]?
        }
    }

    struct ActiveGrant: Decodable {
        let domain: String
        let expiresAt: Date
    }

    struct ConfigPayload: Decodable {
        let enabled: Bool
        let rules: [RulePayload]
        let passwordRequired: Bool?
    }

    struct RulePayload: Codable {
        let id: String
        let domain: String
        let matchSubdomains: Bool
        let mode: String
        let dailyLimitSeconds: Int?
    }

    private let socketPath: String
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "focusshield.ipc.write")
    private var inbox = Data()
    private let pendingLock = NSLock()
    private var pending: [String: CheckedContinuation<Message, Error>] = [:]

    var onMessage: ((Message) -> Void)?
    var onDisconnect: (() -> Void)?

    enum IPCError: LocalizedError {
        case proxyError(String)
        case disconnected
        var errorDescription: String? {
            switch self {
            case .proxyError(let m): return m
            case .disconnected: return "IPC disconnected"
            }
        }
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Connect with a short retry window — the app spawns the proxy and
    /// immediately wants to attach, but the socket takes a few ms to appear.
    func connect(timeout: TimeInterval = 2.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastErr: Error?
        while Date() < deadline {
            do {
                try doConnect()
                startReading()
                return
            } catch {
                lastErr = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw lastErr ?? POSIXError(.ECONNREFUSED)
    }

    func close() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        // Fail any in-flight awaiters so the UI doesn't hang.
        pendingLock.lock()
        let pendingNow = pending
        pending.removeAll()
        pendingLock.unlock()
        for (_, cont) in pendingNow {
            cont.resume(throwing: IPCError.disconnected)
        }
    }

    func send<E: Encodable>(_ message: E) throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0a) // '\n'
        let fdSnapshot = fd
        guard fdSnapshot >= 0 else {
            throw POSIXError(.ENOTCONN)
        }
        writeQueue.async {
            data.withUnsafeBytes { raw in
                _ = Darwin.send(fdSnapshot, raw.baseAddress, raw.count, 0)
            }
        }
    }

    /// Send a request and await the matching response (by id). The proxy
    /// always echoes the id back, so we route the response to the right
    /// awaiter. Errors from the proxy ({ok:false, error:...}) throw.
    func sendAwait<E: Encodable>(_ message: E, id: String, timeout: TimeInterval = 5.0) async throws -> Message {
        let msgTask = Task<Message, Error> {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Message, Error>) in
                pendingLock.lock()
                pending[id] = cont
                pendingLock.unlock()
                do {
                    try self.send(message)
                } catch {
                    pendingLock.lock()
                    pending.removeValue(forKey: id)
                    pendingLock.unlock()
                    cont.resume(throwing: error)
                }
            }
        }

        // Race the response against a timeout.
        let timeoutTask = Task { () -> Message in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.cancelPending(id: id, error: IPCError.proxyError("IPC timeout"))
            throw IPCError.proxyError("IPC timeout")
        }
        defer { timeoutTask.cancel() }
        return try await msgTask.value
    }

    private func cancelPending(id: String, error: Error) {
        pendingLock.lock()
        let cont = pending.removeValue(forKey: id)
        pendingLock.unlock()
        cont?.resume(throwing: error)
    }

    // MARK: - private

    private func doConnect() throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < maxPath else {
            Darwin.close(s)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                for (i, b) in pathBytes.enumerated() {
                    dst[i] = CChar(bitPattern: b)
                }
                dst[pathBytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(s, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let err = errno
            Darwin.close(s)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }
        self.fd = s
    }

    private func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .utility))
        readSource = src
        let fdSnapshot = fd
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.recv(fdSnapshot, &buf, buf.count, 0)
            if n <= 0 {
                self.close()
                self.onDisconnect?()
                return
            }
            self.inbox.append(buf, count: n)
            self.drainLines()
        }
        src.setCancelHandler {}
        src.resume()
    }

    private func drainLines() {
        while let nlIndex = inbox.firstIndex(of: 0x0a) {
            let lineData = inbox.subdata(in: 0..<nlIndex)
            inbox.removeSubrange(0...nlIndex)
            guard !lineData.isEmpty else { continue }
            let dec = JSONDecoder()
            // Go's time.Time marshals as RFC3339 with nanoseconds. Swift's
            // built-in .iso8601 strategy doesn't accept fractional seconds,
            // so we plug in a custom decoder that tolerates both shapes.
            dec.dateDecodingStrategy = .custom { decoder in
                let s = try decoder.singleValueContainer().decode(String.self)
                if let d = isoFracFormatter.date(from: s) { return d }
                if let d = isoBaseFormatter.date(from: s) { return d }
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "unrecognized RFC3339: \(s)"
                )
            }
            guard let msg = try? dec.decode(Message.self, from: lineData) else { continue }

            // Route to the awaiter if this is a response to a tracked
            // request. Push events have no id (or an unknown one) and
            // fall through to onMessage.
            if let id = msg.id, !id.isEmpty {
                pendingLock.lock()
                let cont = pending.removeValue(forKey: id)
                pendingLock.unlock()
                if let cont {
                    if msg.ok == false {
                        cont.resume(throwing: IPCError.proxyError(msg.error ?? "unknown error"))
                    } else {
                        cont.resume(returning: msg)
                    }
                    continue
                }
            }
            onMessage?(msg)
        }
    }
}

// MARK: - request encoders

extension IPCClient {
    struct GetUsageRequest: Encodable { let type = "get_usage"; let id: String }
    struct GetConfigRequest: Encodable { let type = "get_config"; let id: String }
    struct SetUserActiveRequest: Encodable { let type = "set_user_active"; let id: String; let active: Bool }

    /// Mutators carry an optional password for the IPC-side gate when
    /// passwordRequired is on. Empty string ⇒ no password sent (proxy
    /// rejects with "password required" if the gate is active).
    struct SetEnabledRequest: Encodable {
        let type = "set_enabled"
        let id: String
        let enabled: Bool
        let password: String
    }
    struct UpdateRulesRequest: Encodable {
        let type = "update_rules"
        let id: String
        let rules: [RulePayload]
        let password: String
    }
    struct SetPasswordRequiredRequest: Encodable {
        let type = "set_password_required"
        let id: String
        let enabled: Bool
        let password: String  // current password (only needed when disabling)
    }

    struct VerifyPasswordRequest: Encodable {
        let type = "verify_password"
        let id: String
        let password: String
    }
    struct SetPasswordRequest: Encodable {
        let type = "set_password"
        let id: String
        let currentPassword: String
        let newPassword: String
    }
}
