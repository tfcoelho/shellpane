import Darwin
import Foundation

/// What ssh is asking for, sent from the shellpane-askpass helper over a Unix socket.
public struct AskpassRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A password or key passphrase. Answer with the secret.
        case secret
        /// A yes/no question, e.g. "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        case hostKey
        /// SSH_ASKPASS_PROMPT=confirm (e.g. ssh-agent confirm). Any answer = yes, nil = no.
        case confirm
        /// SSH_ASKPASS_PROMPT=none: a notice such as "touch your security key". No answer needed.
        case notice
    }

    public var prompt: String
    public var hint: String
    /// Identifies the connection attempt that's asking (SHELLPANE_ASKPASS_TOKEN), so the app knows
    /// which server, and which saved password, a prompt belongs to.
    public var token: String?

    public init(prompt: String, hint: String, token: String? = nil) {
        self.prompt = prompt
        self.hint = hint
        self.token = token
    }

    public var kind: Kind {
        switch hint {
        case "confirm": return .confirm
        case "none": return .notice
        default: return prompt.contains("(yes/no") ? .hostKey : .secret
        }
    }

    /// SHA256 fingerprint from a host-key prompt, if there is one.
    public var fingerprint: String? {
        guard let r = prompt.range(of: #"SHA256:[A-Za-z0-9+/=]+"#, options: .regularExpression) else { return nil }
        return String(prompt[r])
    }
}

struct AskpassReply: Codable {
    var answer: String?
}

/// Listens on a private Unix socket for the shellpane-askpass helper. One per app (or per test).
/// The handler answers each prompt: return the secret / "yes", or nil to cancel.
public final class AskpassServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AskpassRequest) async -> String?

    public let socketPath: String
    private let directory: String
    private let listenFD: Int32
    private let handler: Handler

    public init(handler: @escaping Handler) throws {
        // mkdtemp in the per-user temp dir (already 0700) keeps the path well under sun_path's 104 bytes.
        var template = Array((NSTemporaryDirectory() + "shellpane-XXXXXX").utf8CString)
        guard let dir = mkdtemp(&template) else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        directory = String(cString: dir)
        chmod(directory, 0o700)
        socketPath = directory + "/askpass.sock"
        self.handler = handler

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw POSIXError(.init(rawValue: err) ?? .EIO)
        }
        chmod(socketPath, 0o600)
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "askpass"
        thread.start()
    }

    /// Environment for the ssh process: the user's own (SSH_AUTH_SOCK matters) plus askpass wiring.
    public func environment(helper: URL, token: String? = nil,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["SHELLPANE_ASKPASS_TOKEN"] = token
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["SHELLPANE_ASKPASS_SOCKET"] = socketPath
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"  // older OpenSSH only uses askpass when DISPLAY is set
        return env
    }

    public func close() {
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        unlink(socketPath)
        rmdir(directory)
    }

    deinit { close() }

    private func acceptLoop() {
        while true {
            let conn = accept(listenFD, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                return
            }
            // Only processes running as this user may ask.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(conn, &uid, &gid) == 0, uid == getuid() else { Darwin.close(conn); continue }
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                Self.serve(conn, handler: handler)
            }
        }
    }

    private static func serve(_ conn: Int32, handler: @escaping Handler) {
        defer { Darwin.close(conn) }
        guard let line = readLine(conn),
              let request = try? JSONDecoder().decode(AskpassRequest.self, from: line) else { return }
        let box = AnswerBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.answer = await handler(request)
            done.signal()
        }
        done.wait()
        guard var data = try? JSONEncoder().encode(AskpassReply(answer: box.answer)) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
    }

    private final class AnswerBox: @unchecked Sendable { var answer: String? }

    static func readLine(_ fd: Int32, limit: Int = 64 * 1024) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }
}
