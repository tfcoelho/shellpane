import Foundation
import Testing
@testable import SFTPKit

/// Runs OpenSSH's own sftp-server as a child process, rooted in a fresh temp directory.
/// Real protocol, real server, no network and no ssh needed.
final class Fixture: @unchecked Sendable {  // immutable after init
    let root: URL
    let client: SFTPClient

    init() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // realpath(3), not resolvingSymlinksInPath: Foundation maps /private/var back to /var, the server doesn't.
        root = URL(fileURLWithPath: Darwin.realpath(dir.path, nil).map { String(cString: $0) } ?? dir.path)
        let transport = ProcessTransport(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"),
                                         arguments: ["-d", root.path, "-e"])
        client = SFTPClient(transport: transport)
        try await client.connect()
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func path(_ name: String) -> String { url(name).path }

    func write(_ name: String, bytes: Int) throws -> Data {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buf in
            for i in 0..<bytes { buf[i] = UInt8(truncatingIfNeeded: i &* 2_654_435_761 >> 7) }
        }
        try data.write(to: url(name))
        return data
    }

    deinit {
        client.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct WireTests {
    @Test func attributesRoundTrip() throws {
        let a = FileAttributes(size: 1 << 40, uid: 501, gid: 20, permissions: 0o100644, accessTime: 1, modificationTime: 1_760_000_000)
        var w = WireWriter()
        w.attributes(a)
        var r = WireReader(w.data)
        #expect(try r.attributes() == a)
        #expect(r.isAtEnd)
    }

    @Test func truncatedPacketThrows() {
        var r = WireReader(Data([0, 0, 0, 9, 1, 2]))
        #expect(throws: SFTPError.self) { try r.bytes() }
    }

    @Test func permissionString() {
        #expect(FileAttributes(permissions: 0o100754).permissionString == "rwxr-xr--")
        #expect(FileAttributes(permissions: 0o040700).fileType == .directory)
    }

    @Test func latin1NamesStillDecode() {
        #expect(RemoteName.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")  // ISO-8859-1 é
    }

    @Test func remotePaths() {
        #expect(RemotePath.join("/var/www", "a.txt") == "/var/www/a.txt")
        #expect(RemotePath.join("/", "etc") == "/etc")
        #expect(RemotePath.parent("/var/www/") == "/var")
        #expect(RemotePath.parent("/var") == "/")
        #expect(RemotePath.parent("/") == "/")
    }
}

@Suite struct SFTPClientTests {
    @Test func handshakeAndRealpath() async throws {
        let f = try await Fixture()
        #expect(f.client.serverVersion == 3)
        #expect(f.client.supportsPosixRename)
        #expect(try await f.client.realpath(".") == f.root.path)
    }

    @Test func listsFilesFoldersHiddenAndSymlinks() async throws {
        let f = try await Fixture()
        _ = try f.write("a.txt", bytes: 10)
        _ = try f.write(".hidden", bytes: 1)
        try FileManager.default.createDirectory(at: f.url("folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: f.path("link-to-folder"), withDestinationPath: "folder")
        try FileManager.default.createSymbolicLink(atPath: f.path("dangling"), withDestinationPath: "nowhere")

        let entries = try await f.client.list(f.root.path)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["a.txt", ".hidden", "folder", "link-to-folder", "dangling"])
        #expect(byName["a.txt"]?.attributes.size == 10)
        #expect(byName["a.txt"]?.path == f.path("a.txt"))
        #expect(byName["folder"]?.isDirectory == true)
        #expect(byName["link-to-folder"]?.attributes.fileType == .symlink)
        #expect(byName["link-to-folder"]?.isDirectory == true)
        #expect(byName["dangling"]?.targetType == nil)
        #expect(byName[".hidden"]?.isHidden == true)
    }

    @Test func listsAThousandEntriesAcrossReaddirBatches() async throws {
        let f = try await Fixture()
        for i in 0..<1000 { FileManager.default.createFile(atPath: f.path("f\(i)"), contents: nil) }
        #expect(try await f.client.list(f.root.path).count == 1000)
    }

    @Test func downloadIsByteIdenticalAndKeepsModificationTime() async throws {
        let f = try await Fixture()
        let original = try f.write("big.bin", bytes: 5 * 1024 * 1024 + 123)  // not a multiple of the chunk size
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: f.path("big.bin"))

        let dest = f.url("downloaded.bin")
        let last = LastProgress()
        try await f.client.download(f.path("big.bin"), to: dest) { done, total in last.set(done, total) }

        #expect(try Data(contentsOf: dest) == original)
        #expect(last.value?.0 == UInt64(original.count))
        #expect(last.value?.1 == UInt64(original.count))
        let got = try FileManager.default.attributesOfItem(atPath: dest.path)[.modificationDate] as? Date
        #expect(got == mtime)
        #expect(!FileManager.default.fileExists(atPath: dest.path + partialSuffix))
    }

    @Test func downloadEmptyFile() async throws {
        let f = try await Fixture()
        _ = try f.write("empty", bytes: 0)
        try await f.client.download(f.path("empty"), to: f.url("empty-copy"))
        #expect(try Data(contentsOf: f.url("empty-copy")).isEmpty)
    }

    @Test func downloadReplacesExistingLocalFile() async throws {
        let f = try await Fixture()
        let original = try f.write("new.txt", bytes: 100)
        _ = try f.write("dest.txt", bytes: 5000)
        try await f.client.download(f.path("new.txt"), to: f.url("dest.txt"))
        #expect(try Data(contentsOf: f.url("dest.txt")) == original)
    }

    @Test func downloadMissingFileFailsAndLeavesNothing() async throws {
        let f = try await Fixture()
        await #expect(throws: SFTPError.self) {
            try await f.client.download(f.path("nope"), to: f.url("nope-copy"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.path("nope-copy")))
        #expect(!FileManager.default.fileExists(atPath: f.path("nope-copy" + partialSuffix)))
    }

    @Test func uploadIsByteIdenticalAndLeavesNoPartFile() async throws {
        let f = try await Fixture()
        let original = try f.write("local.bin", bytes: 3 * 1024 * 1024 + 7)
        try await f.client.upload(f.url("local.bin"), to: f.path("remote.bin"))
        #expect(try Data(contentsOf: f.url("remote.bin")) == original)
        #expect(!FileManager.default.fileExists(atPath: f.path("remote.bin" + partialSuffix)))
    }

    @Test func uploadOverwritesExistingRemoteFile() async throws {
        let f = try await Fixture()
        _ = try f.write("remote.txt", bytes: 9000)
        let original = try f.write("local.txt", bytes: 10)
        try await f.client.upload(f.url("local.txt"), to: f.path("remote.txt"))
        #expect(try Data(contentsOf: f.url("remote.txt")) == original)
    }

    /// BUG-002: "<name>.shellpane-part" went past the 255-byte name limit for long names.
    @Test func longFileNamesTransferBothWays() async throws {
        let f = try await Fixture()
        let long = String(repeating: "é", count: 121) + ".txt"   // 246 bytes in UTF-8: name + ".shellpane-part" would be 257
        #expect(long.utf8.count == 246)
        let original = try f.write("up-src", bytes: 70_000)
        try await f.client.upload(f.url("up-src"), to: f.path(long))
        #expect(try Data(contentsOf: f.url(long)) == original)
        try FileManager.default.createDirectory(at: f.url("down"), withIntermediateDirectories: false)
        try await f.client.download(f.path(long), to: f.url("down").appendingPathComponent(long))
        #expect(try Data(contentsOf: f.url("down").appendingPathComponent(long)) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.path("down")) == [long])
    }

    @Test func partialNamesStayWithinTheLimit() {
        #expect(partialName(for: "a.txt") == "a.txt" + partialSuffix)
        let long = String(repeating: "x", count: 250)
        #expect(partialName(for: long).utf8.count <= 255)
        #expect(partialName(for: long) != partialName(for: String(repeating: "x", count: 249) + "y"))
        let emoji = String(repeating: "☕️", count: 40)   // multi-byte: must not be cut mid-character
        #expect(partialName(for: emoji).utf8.count <= 255)
        #expect(String(data: Data(partialName(for: emoji).utf8), encoding: .utf8) != nil)
    }

    @Test func fileOperations() async throws {
        let f = try await Fixture()
        try await f.client.mkdir(f.path("dir"))
        _ = try f.write("dir/a", bytes: 3)
        try await f.client.rename(f.path("dir/a"), to: f.path("dir/b"))
        #expect(FileManager.default.fileExists(atPath: f.path("dir/b")))
        await #expect(throws: SFTPError.self) { try await f.client.rmdir(f.path("dir")) }  // not empty
        try await f.client.remove(f.path("dir/b"))
        try await f.client.rmdir(f.path("dir"))
        #expect(!FileManager.default.fileExists(atPath: f.path("dir")))
    }

    @Test func chmodViaSetstat() async throws {
        let f = try await Fixture()
        _ = try f.write("script.sh", bytes: 1)
        try await f.client.setstat(f.path("script.sh"), FileAttributes(permissions: 0o755))
        #expect(try await f.client.stat(f.path("script.sh")).permissionString == "rwxr-xr-x")
    }

    @Test func missingPathIsNoSuchFile() async throws {
        let f = try await Fixture()
        do {
            _ = try await f.client.list(f.path("missing"))
            Issue.record("expected an error")
        } catch let SFTPError.status(code, _, path) {
            #expect(code == .noSuchFile)
            #expect(path == f.path("missing"))
        }
    }

    @Test func lockedFolderIsPermissionDenied() async throws {
        let f = try await Fixture()
        try FileManager.default.createDirectory(at: f.url("locked"), withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.path("locked"))
        do {
            _ = try await f.client.list(f.path("locked"))
            Issue.record("expected an error")
        } catch let SFTPError.status(code, _, _) {
            #expect(code == .permissionDenied)
        }
    }

    @Test func requestsFailCleanlyWhenTheServerDies() async throws {
        let f = try await Fixture()
        kill(f.client.transport.processIdentifier, SIGKILL)
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: SFTPError.self) { _ = try await f.client.realpath(".") }
        #expect(f.client.isClosed)
    }

    @Test func manyConcurrentRequests() async throws {
        let f = try await Fixture()
        for i in 0..<50 { _ = try f.write("f\(i)", bytes: i) }
        let sizes = try await withThrowingTaskGroup(of: UInt64?.self) { group in
            for i in 0..<50 { group.addTask { try await f.client.stat(f.path("f\(i)")).size } }
            return try await group.reduce(into: [UInt64]()) { $0.append($1 ?? 0) }
        }
        #expect(sizes.sorted() == (0..<50).map(UInt64.init))
    }
}

final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (UInt64, UInt64?)?
    var value: (UInt64, UInt64?)? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ done: UInt64, _ total: UInt64?) { lock.lock(); _value = (done, total); lock.unlock() }
}

@Suite struct TypedPathTests {
    func r(_ t: String, remote: Bool = false) -> String {
        RemotePath.resolve(t, from: "/var/www/site", home: "/home/me", acceptsHostPrefix: remote)
    }

    @Test func absoluteAndRelative() {
        #expect(r("/etc/nginx") == "/etc/nginx")
        #expect(r("logs") == "/var/www/site/logs")
        #expect(r("./logs/") == "/var/www/site/logs")
        #expect(r("..") == "/var/www")
        #expect(r("../../..") == "/")
        #expect(r("../../../..") == "/")          // can't go above the top
        #expect(r("//var///log/") == "/var/log")
        #expect(r("  /tmp  ") == "/tmp")
    }

    @Test func home() {
        #expect(r("~") == "/home/me")
        #expect(r("~/.ssh") == "/home/me/.ssh")
        #expect(r("~/a/../b") == "/home/me/b")
    }

    @Test func pastedHostPrefixOnlyOnServers() {
        #expect(r("web-1:/var/log", remote: true) == "/var/log")
        #expect(r("deploy@web-1:/srv/app", remote: true) == "/srv/app")
        #expect(r("web-1:", remote: true) == "/home/me")
        #expect(r("web-1:logs", remote: true) == "/home/me/logs")                 // as in scp: from the home folder
        #expect(r("notes:today", remote: false) == "/var/www/site/notes:today")  // on the Mac, a colon is just a character
        #expect(r("a/b:c", remote: true) == "/var/www/site/a/b:c")               // a slash before the colon: not a host
    }
}
