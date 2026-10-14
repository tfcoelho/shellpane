import Foundation

/// Runs a child process that speaks SFTP on stdin/stdout: `/usr/bin/ssh … -s host sftp` in the app,
/// `/usr/libexec/sftp-server` in tests. Packets are framed by a uint32 length.
public final class ProcessTransport: @unchecked Sendable {
    public typealias ExitDescriber = @Sendable (_ status: Int32, _ stderr: String) -> String

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let describeExit: ExitDescriber
    private let lock = NSLock()
    /// Pipe writes over PIPE_BUF (512 bytes) aren't atomic: concurrent senders would interleave packets.
    private let sendLock = NSLock()
    private var stderrBuffer = Data()
    private var finished = false

    var onPacket: (@Sendable (Data) -> Void)?
    var onClose: (@Sendable (String) -> Void)?

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil,
                currentDirectory: URL? = nil,
                describeExit: @escaping ExitDescriber = ProcessTransport.defaultDescription) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.describeExit = describeExit
    }

    public static let defaultDescription: ExitDescriber = { status, stderr in
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The connection closed (exit code \(status))." : text
    }

    /// Everything the process has written to stderr so far.
    public var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Writing to a pipe whose reader has died raises SIGPIPE, which kills the whole app by default.
    /// Ignore it once per process; the failed write then surfaces as an error instead.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    func start() throws {
        _ = Self.ignoreSIGPIPE
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            if self.stderrBuffer.count < 256 * 1024 { self.stderrBuffer.append(chunk) }
            self.lock.unlock()
        }
        try process.run()
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "SFTP reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func send(_ packet: Data) throws {
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done else { throw SFTPError.connectionClosed(detail: "The connection is closed.") }
        do {
            try sendLock.withLock { try stdinPipe.fileHandleForWriting.write(contentsOf: packet) }
        } catch {
            throw SFTPError.connectionClosed(detail: "The connection closed while sending.")
        }
    }

    public func close() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func readLoop() {
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        outer: while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
                guard length <= 34 * 1024 * 1024 else { break outer }  // garbage on stdout: not an SFTP server
                guard buffer.count >= 4 + length else { break }
                let start = buffer.startIndex
                let body = Data(buffer[(start + 4)..<(start + 4 + length)])
                buffer.removeSubrange(start..<(start + 4 + length))
                onPacket?(body)
            }
        }
        finish()
    }

    private func finish() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Pick up anything left in the pipe after the process exited.
        let rest = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
        lock.lock()
        if let rest { stderrBuffer.append(rest) }
        finished = true
        let text = String(decoding: stderrBuffer, as: UTF8.self)
        lock.unlock()
        onClose?(describeExit(process.terminationStatus, text))
    }
}
