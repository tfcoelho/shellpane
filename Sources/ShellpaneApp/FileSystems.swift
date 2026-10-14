import Foundation
import ShellpaneUI
import SFTPKit
import SSHProcess
import TransferKit

/// A live SFTP session to one server, shared by every pane showing it.
final class RemoteSession: @unchecked Sendable {
    /// The favorite id, or "alias:…"/"adhoc:…" for unsaved servers. Same key = same server.
    let key: String
    let label: String
    let target: SSHTarget
    let client: SFTPClient
    let colour: ConnectionColour
    let home: String
    /// Opens a fresh session to the same server (with the same saved credentials). Set by ConnectionManager.
    var reopen: (@MainActor () async throws -> RemoteSession)?

    init(key: String, label: String, target: SSHTarget, client: SFTPClient, colour: ConnectionColour, home: String) {
        self.key = key
        self.label = label
        self.target = target
        self.client = client
        self.colour = colour
        self.home = home
    }

    var isAlive: Bool { !client.isClosed }

    var ops: RemoteOps { RemoteOps(client: client, identity: key) }

    /// This session if it's alive, otherwise a reconnected one.
    @MainActor func live() async throws -> RemoteSession {
        if isAlive { return self }
        guard let reopen else { throw SFTPError.connectionClosed(detail: "The connection to \(label) closed.") }
        return try await reopen()
    }
}

/// What a pane is showing.
enum Location {
    case local(String)
    case remote(RemoteSession, String)

    var path: String {
        switch self {
        case let .local(p), let .remote(_, p): p
        }
    }

    var session: RemoteSession? {
        if case let .remote(s, _) = self { return s }
        return nil
    }

    func with(path: String) -> Location {
        switch self {
        case .local: .local(path)
        case let .remote(s, _): .remote(s, path)
        }
    }

    var parent: String {
        RemotePath.parent(path)
    }

    func child(_ name: String) -> String {
        RemotePath.join(path, name)
    }

    var ops: FileSystemOps {
        switch self {
        case .local: LocalOps()
        case let .remote(s, _): s.ops
        }
    }

    /// Short name for a tab: the folder, with the server for remote ones.
    var displayTitle: String {
        let folder = (path as NSString).lastPathComponent.isEmpty ? "/" : (path as NSString).lastPathComponent
        return session.map { "\(folder) — \($0.label)" } ?? folder
    }

    var displayName: String {
        switch self {
        case let .local(p): (p as NSString).lastPathComponent.isEmpty ? "/" : (p as NSString).lastPathComponent
        case let .remote(s, p): "\(s.label):\(p)"
        }
    }

    /// The same place, on a live connection (reconnecting if needed).
    @MainActor func live() async throws -> Location {
        switch self {
        case .local: self
        case let .remote(s, p): .remote(try await s.live(), p)
        }
    }

    func list() async throws -> [FileEntry] {
        switch self {
        case let .local(path):
            return try await Task.detached(priority: .userInitiated) { try LocalFS.list(path) }.value
        case let .remote(session, path):
            return try await session.client.list(path)
        }
    }
}

enum LocalFS {
    static func list(_ path: String) throws -> [FileEntry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        return names.map { entry(at: RemotePath.join(path, $0)) }
    }

    /// One item, as a row: its own attributes (not following a link), and what a link points to.
    static func entry(at full: String) -> FileEntry {
        let fm = FileManager.default
        let name = (full as NSString).lastPathComponent
        let attrs = (try? fm.attributesOfItem(atPath: full)) ?? [:]  // does not follow symlinks
        var a = FileAttributes()
        a.size = (attrs[.size] as? NSNumber)?.uint64Value
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        let typeBits: UInt32
        switch attrs[.type] as? FileAttributeType {
        case .typeDirectory?: typeBits = 0o040000
        case .typeSymbolicLink?: typeBits = 0o120000
        case .typeRegular?: typeBits = 0o100000
        default: typeBits = 0
        }
        a.permissions = typeBits | perms
        if let date = attrs[.modificationDate] as? Date { a.modificationTime = UInt32(clamping: Int(date.timeIntervalSince1970)) }
        var entry = FileEntry(name: name, path: full, attributes: a)
        if a.fileType == .symlink {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir) { entry.targetType = isDir.boolValue ? .directory : .regular }
        }
        return entry
    }

    /// Listing that returns nothing instead of throwing (self-test and best-effort callers).
    static func listSafe(_ path: String) -> [FileEntry] {
        ((try? list(path)) ?? []).sorted { $0.name < $1.name }
    }

    static func freeSpace(at path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
