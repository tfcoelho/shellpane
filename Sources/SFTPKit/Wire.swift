import Foundation

// SFTP v3 wire format (draft-ietf-secsh-filexfer-02): big-endian integers,
// strings as uint32 length + raw bytes.

struct WireWriter {
    private(set) var data = Data()

    mutating func byte(_ v: UInt8) { data.append(v) }

    mutating func uint32(_ v: UInt32) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func uint64(_ v: UInt64) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ bytes: Data) {
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func string(_ s: String) { string(Data(s.utf8)) }

    mutating func attributes(_ a: FileAttributes) {
        var flags: UInt32 = 0
        if a.size != nil { flags |= AttrFlag.size }
        if a.uid != nil && a.gid != nil { flags |= AttrFlag.uidgid }
        if a.permissions != nil { flags |= AttrFlag.permissions }
        if a.accessTime != nil && a.modificationTime != nil { flags |= AttrFlag.acmodtime }
        uint32(flags)
        if let size = a.size { uint64(size) }
        if let uid = a.uid, let gid = a.gid { uint32(uid); uint32(gid) }
        if let p = a.permissions { uint32(p) }
        if let at = a.accessTime, let mt = a.modificationTime { uint32(at); uint32(mt) }
    }

    /// Prefix with the uint32 packet length.
    func framed() -> Data {
        var out = Data(capacity: data.count + 4)
        withUnsafeBytes(of: UInt32(data.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}

struct WireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, data.endIndex - offset >= n else { throw SFTPError.badMessage("truncated packet") }
        defer { offset += n }
        return data[offset..<offset + n]
    }

    mutating func byte() throws -> UInt8 { try take(1).first! }

    mutating func uint32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytes() throws -> Data {
        let n = try uint32()
        guard n <= 64 * 1024 * 1024 else { throw SFTPError.badMessage("string too long: \(n)") }
        return Data(try take(Int(n)))
    }

    mutating func string() throws -> String { RemoteName.decode(try bytes()) }

    mutating func attributes() throws -> FileAttributes {
        let flags = try uint32()
        var a = FileAttributes()
        if flags & AttrFlag.size != 0 { a.size = try uint64() }
        if flags & AttrFlag.uidgid != 0 { a.uid = try uint32(); a.gid = try uint32() }
        if flags & AttrFlag.permissions != 0 { a.permissions = try uint32() }
        if flags & AttrFlag.acmodtime != 0 { a.accessTime = try uint32(); a.modificationTime = try uint32() }
        if flags & AttrFlag.extended != 0 {
            let count = try uint32()
            for _ in 0..<count { _ = try bytes(); _ = try bytes() }
        }
        return a
    }
}

enum AttrFlag {
    static let size: UInt32 = 0x0000_0001
    static let uidgid: UInt32 = 0x0000_0002
    static let permissions: UInt32 = 0x0000_0004
    static let acmodtime: UInt32 = 0x0000_0008
    static let extended: UInt32 = 0x8000_0000
}

enum PacketType: UInt8 {
    case initialize = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6, lstat = 7, fstat = 8
    case setstat = 9, fsetstat = 10, opendir = 11, readdir = 12, remove = 13
    case mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18
    case readlink = 19, symlink = 20
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
    case extended = 200, extendedReply = 201
}

/// SFTP filenames are bytes. Decode as UTF-8, fall back to Latin-1 so any name can be shown,
/// and keep the raw bytes when the name has to go back to the server.
public enum RemoteName {
    public static func decode(_ bytes: Data) -> String {
        String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
    }
}
