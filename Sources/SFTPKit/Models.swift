import Foundation

public struct FileAttributes: Sendable, Equatable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modificationTime: UInt32?

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil,
                accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modificationTime = modificationTime
    }

    public var fileType: FileType {
        guard let p = permissions else { return .unknown }
        switch p & 0o170000 {
        case 0o040000: return .directory
        case 0o100000: return .regular
        case 0o120000: return .symlink
        default: return .other
        }
    }

    public var modificationDate: Date? {
        modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// "rwxr-xr-x"
    public var permissionString: String {
        guard let p = permissions else { return "" }
        let chars: [Character] = ["r", "w", "x"]
        return String((0..<9).map { i in p & (1 << (8 - i)) != 0 ? chars[i % 3] : "-" })
    }
}

public enum FileType: Sendable, Equatable {
    case directory, regular, symlink, other, unknown
}

public struct FileEntry: Sendable, Equatable, Identifiable {
    public var name: String
    /// The name exactly as the server sent it. Use this, not `name`, when talking to the server.
    public var rawName: Data
    public var path: String
    public var attributes: FileAttributes
    /// For symlinks: the type of what the link points to, when known.
    public var targetType: FileType?

    public var id: String { path }

    public init(name: String, rawName: Data? = nil, path: String, attributes: FileAttributes, targetType: FileType? = nil) {
        self.name = name
        self.rawName = rawName ?? Data(name.utf8)
        self.path = path
        self.attributes = attributes
        self.targetType = targetType
    }

    public var isDirectory: Bool {
        attributes.fileType == .directory || (attributes.fileType == .symlink && targetType == .directory)
    }

    public var isHidden: Bool { name.hasPrefix(".") }
}

public enum StatusCode: UInt32, Sendable {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
    case badMessage = 5, noConnection = 6, connectionLost = 7, unsupported = 8
}

public enum SFTPError: Error, Sendable, Equatable, LocalizedError {
    case status(StatusCode, message: String, path: String?)
    case badMessage(String)
    case unexpectedResponse(String)
    case connectionClosed(detail: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .status(code, message, path):
            let subject = path.map { "“\(($0 as NSString).lastPathComponent)”" } ?? "The item"
            switch code {
            case .noSuchFile: return "\(subject) doesn't exist on the server."
            case .permissionDenied: return "You don't have permission to access \(subject)."
            case .unsupported: return "The server doesn't support this operation."
            default: return message.isEmpty ? "The server reported an error (\(code))." : message
            }
        case let .badMessage(m): return "The server sent something unexpected: \(m)"
        case let .unexpectedResponse(m): return "The server sent an unexpected reply: \(m)"
        case let .connectionClosed(detail): return detail.isEmpty ? "The connection closed." : detail
        case .cancelled: return "Cancelled."
        }
    }
}

public struct OpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = OpenFlags(rawValue: 0x01)
    public static let write = OpenFlags(rawValue: 0x02)
    public static let append = OpenFlags(rawValue: 0x04)
    public static let create = OpenFlags(rawValue: 0x08)
    public static let truncate = OpenFlags(rawValue: 0x10)
    public static let exclusive = OpenFlags(rawValue: 0x20)
}

public struct RemoteHandle: Sendable, Hashable {
    let raw: Data
}

public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        if dir.isEmpty { return name }
        return dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    /// What someone typed into the path bar, as an absolute path: "~" and "~/x" from `home`, relative paths
    /// from `current`, "." and ".." worked out, repeated and trailing slashes dropped. With `acceptsHostPrefix`
    /// (a server pane), a pasted "host:/path" or "user@host:/path" counts as its path; as in scp, a relative
    /// path after "host:" starts from the home folder. Doesn't touch the disk.
    public static func resolve(_ typed: String, from current: String, home: String, acceptsHostPrefix: Bool = false) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = current
        if acceptsHostPrefix, !text.hasPrefix("/"), !text.hasPrefix("~"),
           let colon = text.firstIndex(of: ":"), !text[..<colon].contains("/") {
            text = String(text[text.index(after: colon)...])
            base = home
        }
        if text.isEmpty { text = base }
        if text == "~" { text = home }
        else if text.hasPrefix("~/") { text = join(home, String(text.dropFirst(2))) }
        else if !text.hasPrefix("/") { text = join(base, text) }
        var parts: [Substring] = []
        for part in text.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
