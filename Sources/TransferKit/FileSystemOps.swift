import Foundation
import SFTPKit

/// The operations a transfer or a file command needs, on either side. Local and remote look the same to callers.
public protocol FileSystemOps: Sendable {
    var isRemote: Bool { get }
    /// Identifies the filesystem: two ops with the same id can rename between each other (a cheap move).
    var identity: String { get }
    func list(_ path: String) async throws -> [FileEntry]
    /// nil when nothing is there. Does not follow symlinks.
    func lstat(_ path: String) async throws -> FileAttributes?
    func mkdir(_ path: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func setModificationTime(_ path: String, _ time: UInt32) async throws
}

public struct LocalOps: FileSystemOps {
    public init() {}
    public var isRemote: Bool { false }
    public var identity: String { "local" }

    public func list(_ path: String) async throws -> [FileEntry] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(atPath: path).map { name in
            let full = RemotePath.join(path, name)
            var entry = FileEntry(name: name, path: full, attributes: Self.attributes(full) ?? FileAttributes())
            if entry.attributes.fileType == .symlink {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir) { entry.targetType = isDir.boolValue ? .directory : .regular }
            }
            return entry
        }
    }

    public func lstat(_ path: String) async throws -> FileAttributes? { Self.attributes(path) }

    static func attributes(_ path: String) -> FileAttributes? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        var a = FileAttributes()
        a.size = (attrs[.size] as? NSNumber)?.uint64Value
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        let type: UInt32 = switch attrs[.type] as? FileAttributeType {
        case .typeDirectory?: 0o040000
        case .typeSymbolicLink?: 0o120000
        case .typeRegular?: 0o100000
        default: 0
        }
        a.permissions = type | perms
        if let d = attrs[.modificationDate] as? Date { a.modificationTime = UInt32(clamping: Int(d.timeIntervalSince1970)) }
        return a
    }

    public func mkdir(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }

    public func removeFile(_ path: String) async throws { try FileManager.default.removeItem(atPath: path) }
    public func removeDirectory(_ path: String) async throws { try FileManager.default.removeItem(atPath: path) }

    /// Refuses to replace another item. On a case-insensitive disk, "a.txt" → "A.txt" finds "itself"
    /// at the new name; that's the same file (same inode), so the case-only rename is allowed.
    public func rename(_ from: String, to: String) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to) {
            let a = (try? fm.attributesOfItem(atPath: from))?[.systemFileNumber] as? NSNumber
            let b = (try? fm.attributesOfItem(atPath: to))?[.systemFileNumber] as? NSNumber
            guard let a, a == b else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to]) }
        }
        try fm.moveItem(atPath: from, toPath: to)
    }

    public func setModificationTime(_ path: String, _ time: UInt32) async throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(time))], ofItemAtPath: path)
    }

    /// Local deletes go to the Trash, so they can be undone in Finder.
    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}

public struct RemoteOps: FileSystemOps {
    public let client: SFTPClient
    public let identity: String

    /// - identity: something stable per server session, e.g. the favorite id.
    public init(client: SFTPClient, identity: String) {
        self.client = client
        self.identity = "remote:" + identity
    }

    public var isRemote: Bool { true }
    public func list(_ path: String) async throws -> [FileEntry] { try await client.list(path) }

    public func lstat(_ path: String) async throws -> FileAttributes? {
        do {
            return try await client.lstat(path)
        } catch SFTPError.status(.noSuchFile, _, _) {
            return nil
        }
    }

    public func mkdir(_ path: String) async throws { try await client.mkdir(path) }
    public func removeFile(_ path: String) async throws { try await client.remove(path) }
    public func removeDirectory(_ path: String) async throws { try await client.rmdir(path) }

    public func setModificationTime(_ path: String, _ time: UInt32) async throws {
        try await client.setstat(path, FileAttributes(accessTime: time, modificationTime: time))
    }

    /// SFTP v3 rename refuses to overwrite, which is what a rename should do. The exception is a
    /// case-only rename on a case-insensitive server (macOS): it fails as "exists" although it's the same file.
    /// If no entry spelled exactly like the new name is in the folder, it is the same file: use the atomic rename.
    public func rename(_ from: String, to: String) async throws {
        do {
            try await client.rename(from, to: to)
        } catch {
            let fromName = (from as NSString).lastPathComponent, toName = (to as NSString).lastPathComponent
            guard RemotePath.parent(from) == RemotePath.parent(to), fromName != toName,
                  fromName.lowercased() == toName.lowercased() else { throw error }
            let names = try await client.list(RemotePath.parent(from)).map(\.name)
            guard !names.contains(toName) else { throw error }
            try await client.posixRename(from, to: to)
        }
    }
}

public enum FileNames {
    /// "report.pdf" taken → "report 2.pdf", "report 3.pdf"… Folders and dotfiles keep their whole name as the stem.
    public static func uniqueName(_ name: String, isTaken: @Sendable (String) async throws -> Bool) async rethrows -> String {
        guard try await isTaken(name) else { return name }
        let ns = name as NSString
        let ext = name.hasPrefix(".") && !name.dropFirst().contains(".") ? "" : ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if try await !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// Names a person can type that a filesystem won't take.
    public static func validationError(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A name can't be empty." }
        if trimmed == "." || trimmed == ".." { return "“\(trimmed)” is reserved." }
        if name.contains("/") { return "Names can't contain “/”." }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) { return "Names can't contain that character." }
        return nil
    }
}
