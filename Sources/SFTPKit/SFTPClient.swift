import Foundation

/// An SFTP v3 client over any `ProcessTransport`. Requests are pipelined: many can be in flight,
/// replies are matched by request id. Safe to call from any task.
public final class SFTPClient: @unchecked Sendable {
    public let transport: ProcessTransport
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Reply, Error>] = [:]
    private var versionWaiter: CheckedContinuation<(UInt32, [String: String]), Error>?
    private var closedError: SFTPError?
    public private(set) var serverVersion: UInt32 = 0
    public private(set) var extensions: [String: String] = [:]

    /// Largest read/write we ask for. 32 KB is what every SFTP server accepts.
    public static let chunkSize: UInt32 = 32 * 1024
    /// Outstanding reads/writes per file transfer. OpenSSH's `sftp` uses 64.
    public static let pipelineDepth = 64

    struct Reply {
        let type: PacketType
        var reader: WireReader
    }

    public init(transport: ProcessTransport) {
        self.transport = transport
        transport.onPacket = { [weak self] in self?.handle(packet: $0) }
        transport.onClose = { [weak self] in self?.fail(with: .connectionClosed(detail: $0)) }
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedError != nil
    }

    /// Starts the process and does the SFTP handshake.
    public func connect() async throws {
        try transport.start()
        let (version, ext) = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(UInt32, [String: String]), Error>) in
            lock.lock()
            if let closedError {
                lock.unlock()
                c.resume(throwing: closedError)
                return
            }
            versionWaiter = c
            lock.unlock()
            var w = WireWriter()
            w.byte(PacketType.initialize.rawValue)
            w.uint32(3)
            do { try transport.send(w.framed()) } catch { takeVersionWaiter()?.resume(throwing: error) }
        }
        guard version >= 3 else { throw SFTPError.unexpectedResponse("server speaks SFTP version \(version)") }
        lock.withLock {
            serverVersion = version
            extensions = ext
        }
    }

    public func close() {
        transport.close()
    }

    // MARK: - Plumbing

    private func takeVersionWaiter() -> CheckedContinuation<(UInt32, [String: String]), Error>? {
        lock.lock(); defer { lock.unlock() }
        let w = versionWaiter
        versionWaiter = nil
        return w
    }

    private func handle(packet: Data) {
        var r = WireReader(packet)
        do {
            guard let type = PacketType(rawValue: try r.byte()) else { return }
            if type == .version {
                let version = try r.uint32()
                var ext: [String: String] = [:]
                while !r.isAtEnd { ext[try r.string()] = try r.string() }
                takeVersionWaiter()?.resume(returning: (version, ext))
                return
            }
            let id = try r.uint32()
            lock.lock()
            let c = pending.removeValue(forKey: id)
            lock.unlock()
            c?.resume(returning: Reply(type: type, reader: r))
        } catch {
            fail(with: .badMessage("unreadable packet"))
            transport.close()
        }
    }

    private func fail(with error: SFTPError) {
        lock.lock()
        if closedError == nil { closedError = error }
        let waiters = pending
        pending.removeAll()
        let version = versionWaiter
        versionWaiter = nil
        lock.unlock()
        for c in waiters.values { c.resume(throwing: error) }
        version?.resume(throwing: error)
    }

    private func request(_ type: PacketType, path: String? = nil, _ build: (inout WireWriter) -> Void) async throws -> Reply {
        var w = WireWriter()
        w.byte(type.rawValue)
        let id = lock.withLock {
            defer { nextID &+= 1 }
            return nextID
        }
        w.uint32(id)
        build(&w)
        let packet = w.framed()
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Reply, Error>) in
            lock.lock()
            if let closedError {
                lock.unlock()
                c.resume(throwing: closedError)
                return
            }
            pending[id] = c
            lock.unlock()
            do {
                try transport.send(packet)
            } catch {
                lock.lock()
                let waiter = pending.removeValue(forKey: id)
                lock.unlock()
                waiter?.resume(throwing: error)
            }
        }
        if reply.type == .status {
            var r = reply.reader
            let code = StatusCode(rawValue: try r.uint32()) ?? .failure
            let message = (try? r.string()) ?? ""
            if code == .ok || code == .eof { return reply }
            throw SFTPError.status(code, message: message, path: path)
        }
        return reply
    }

    private func expectStatusOK(_ reply: Reply) throws {
        guard reply.type == .status else { throw SFTPError.unexpectedResponse("\(reply.type) instead of status") }
    }

    private func isEOF(_ reply: Reply) -> Bool {
        guard reply.type == .status else { return false }
        var r = reply.reader
        return (try? r.uint32()) == StatusCode.eof.rawValue
    }

    // MARK: - Operations

    public func realpath(_ path: String) async throws -> String {
        var reply = try await request(.realpath, path: path) { $0.string(path) }
        guard reply.type == .name, try reply.reader.uint32() >= 1 else {
            throw SFTPError.unexpectedResponse("realpath returned \(reply.type)")
        }
        return try reply.reader.string()
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        try await attrs(.stat, path)
    }

    public func lstat(_ path: String) async throws -> FileAttributes {
        try await attrs(.lstat, path)
    }

    private func attrs(_ type: PacketType, _ path: String) async throws -> FileAttributes {
        var reply = try await request(type, path: path) { $0.string(path) }
        guard reply.type == .attrs else { throw SFTPError.unexpectedResponse("\(type) returned \(reply.type)") }
        return try reply.reader.attributes()
    }

    public func fstat(_ handle: RemoteHandle) async throws -> FileAttributes {
        var reply = try await request(.fstat) { $0.string(handle.raw) }
        guard reply.type == .attrs else { throw SFTPError.unexpectedResponse("fstat returned \(reply.type)") }
        return try reply.reader.attributes()
    }

    public func open(_ path: String, flags: OpenFlags, attributes: FileAttributes = FileAttributes()) async throws -> RemoteHandle {
        var reply = try await request(.open, path: path) {
            $0.string(path)
            $0.uint32(flags.rawValue)
            $0.attributes(attributes)
        }
        guard reply.type == .handle else { throw SFTPError.unexpectedResponse("open returned \(reply.type)") }
        return RemoteHandle(raw: try reply.reader.bytes())
    }

    public func close(_ handle: RemoteHandle) async throws {
        try expectStatusOK(try await request(.close) { $0.string(handle.raw) })
    }

    /// nil at end of file. May return fewer bytes than asked for.
    public func read(_ handle: RemoteHandle, offset: UInt64, length: UInt32) async throws -> Data? {
        var reply = try await request(.read) {
            $0.string(handle.raw)
            $0.uint64(offset)
            $0.uint32(length)
        }
        if isEOF(reply) { return nil }
        guard reply.type == .data else { throw SFTPError.unexpectedResponse("read returned \(reply.type)") }
        return try reply.reader.bytes()
    }

    public func write(_ handle: RemoteHandle, offset: UInt64, data: Data) async throws {
        try expectStatusOK(try await request(.write) {
            $0.string(handle.raw)
            $0.uint64(offset)
            $0.string(data)
        })
    }

    /// Lists a directory, without "." and "..". Symlinks get their target type filled in.
    public func list(_ path: String) async throws -> [FileEntry] {
        var reply = try await request(.opendir, path: path) { $0.string(path) }
        guard reply.type == .handle else { throw SFTPError.unexpectedResponse("opendir returned \(reply.type)") }
        let handle = RemoteHandle(raw: try reply.reader.bytes())
        var entries: [FileEntry] = []
        do {
            while true {
                var batch = try await request(.readdir, path: path) { $0.string(handle.raw) }
                if isEOF(batch) { break }
                guard batch.type == .name else { throw SFTPError.unexpectedResponse("readdir returned \(batch.type)") }
                let count = try batch.reader.uint32()
                for _ in 0..<count {
                    let raw = try batch.reader.bytes()
                    _ = try batch.reader.bytes()  // longname: ls -l style, not parsed
                    let attrs = try batch.reader.attributes()
                    let name = RemoteName.decode(raw)
                    if name == "." || name == ".." { continue }
                    entries.append(FileEntry(name: name, rawName: raw, path: RemotePath.join(path, name), attributes: attrs))
                }
            }
        } catch {
            try? await close(handle)
            throw error
        }
        try? await close(handle)

        // Resolve symlink targets in parallel; a dangling link just stays a link.
        let links = entries.indices.filter { entries[$0].attributes.fileType == .symlink }
        if !links.isEmpty {
            let types = await withTaskGroup(of: (Int, FileType?).self) { group in
                for i in links {
                    let p = entries[i].path
                    group.addTask { (i, try? await self.stat(p).fileType) }
                }
                var result: [Int: FileType] = [:]
                for await (i, t) in group { if let t { result[i] = t } }
                return result
            }
            for (i, t) in types { entries[i].targetType = t }
        }
        return entries
    }

    public func mkdir(_ path: String, permissions: UInt32? = nil) async throws {
        try expectStatusOK(try await request(.mkdir, path: path) {
            $0.string(path)
            $0.attributes(FileAttributes(permissions: permissions))
        })
    }

    public func rmdir(_ path: String) async throws {
        try expectStatusOK(try await request(.rmdir, path: path) { $0.string(path) })
    }

    public func remove(_ path: String) async throws {
        try expectStatusOK(try await request(.remove, path: path) { $0.string(path) })
    }

    /// Fails if `to` exists (SFTP v3 semantics). Use `posixRename` to overwrite.
    public func rename(_ from: String, to: String) async throws {
        try expectStatusOK(try await request(.rename, path: from) {
            $0.string(from)
            $0.string(to)
        })
    }

    public var supportsPosixRename: Bool {
        lock.lock(); defer { lock.unlock() }
        return extensions["posix-rename@openssh.com"] != nil
    }

    /// Atomic rename that replaces `to` (OpenSSH extension). Falls back to remove + rename.
    public func posixRename(_ from: String, to: String) async throws {
        if supportsPosixRename {
            try expectStatusOK(try await request(.extended, path: from) {
                $0.string("posix-rename@openssh.com")
                $0.string(from)
                $0.string(to)
            })
        } else {
            try? await remove(to)
            try await rename(from, to: to)
        }
    }

    public func setstat(_ path: String, _ attributes: FileAttributes) async throws {
        try expectStatusOK(try await request(.setstat, path: path) {
            $0.string(path)
            $0.attributes(attributes)
        })
    }

    public func readlink(_ path: String) async throws -> String {
        var reply = try await request(.readlink, path: path) { $0.string(path) }
        guard reply.type == .name, try reply.reader.uint32() >= 1 else {
            throw SFTPError.unexpectedResponse("readlink returned \(reply.type)")
        }
        return try reply.reader.string()
    }
}
