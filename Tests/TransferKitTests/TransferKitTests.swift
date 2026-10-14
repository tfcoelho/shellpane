import Foundation
import SFTPKit
import Testing
@testable import TransferKit

/// A temp root with "local" and "server" folders; the server side is reached through OpenSSH's sftp-server.
final class TransferFixture: @unchecked Sendable {
    let root: URL
    let client: SFTPClient
    let remote: RemoteOps
    let local = LocalOps()

    init() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shellpane-xfer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: Darwin.realpath(dir.path, nil).map { String(cString: $0) } ?? dir.path)
        for d in ["local", "server"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        client = try await Self.connect(root)
        remote = RemoteOps(client: client, identity: "test")
    }

    static func connect(_ root: URL) async throws -> SFTPClient {
        let c = SFTPClient(transport: ProcessTransport(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"),
                                                       arguments: ["-d", root.path, "-e"]))
        try await c.connect()
        return c
    }

    func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }

    /// Test setup: a failure here is a broken test, so it traps instead of throwing.
    @discardableResult
    func write(_ rel: String, _ text: String, mtime: TimeInterval? = nil) -> String {
        let url = root.appendingPathComponent(rel)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
        if let mtime { try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path) }
        return url.path
    }

    func read(_ rel: String) -> String? { try? String(contentsOfFile: path(rel), encoding: .utf8) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: path(rel)) }

    func entry(_ rel: String) async throws -> FileEntry {
        let p = path(rel)
        let attrs = try await local.lstat(p)!
        return FileEntry(name: (p as NSString).lastPathComponent, path: p, attributes: attrs)
    }

    func remoteEntry(_ rel: String) async throws -> FileEntry {
        let p = path(rel)
        return FileEntry(name: (p as NSString).lastPathComponent, path: p, attributes: try await client.lstat(p))
    }

    deinit {
        client.close()
        try? FileManager.default.removeItem(at: root)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _conflicts: [String] = []
    private var _last = BatchProgress()
    var conflicts: [String] { lock.withLock { _conflicts } }
    var last: BatchProgress { lock.withLock { _last } }
    func conflict(_ c: Conflict) { lock.withLock { _conflicts.append(c.name) } }
    func progress(_ p: BatchProgress) { lock.withLock { _last = p } }
}

func batch(_ sources: [FileEntry], mode: TransferBatch.Mode = .copy, from: FileSystemOps, to: FileSystemOps, into folder: String,
           decide: ConflictDecision = .init(.skip), rec: Recorder = Recorder()) -> TransferBatch {
    TransferBatch(mode: mode, sources: sources, from: from, to: to, destinationFolder: folder,
                  resolver: { c in rec.conflict(c); return decide }, onProgress: { rec.progress($0) })
}

@Suite struct TransferBatchTests {
    @Test func uploadsAFolderTreeIncludingEmptyFolders() async throws {
        let f = try await TransferFixture()
        f.write("local/site/index.html", "<h1>hi</h1>")
        f.write("local/site/css/app.css", "body{}")
        f.write("local/site/img/deep/er/logo.svg", "<svg/>")
        try FileManager.default.createDirectory(atPath: f.path("local/site/empty"), withIntermediateDirectories: true)
        let rec = Recorder()
        await batch([try await f.entry("local/site")], from: f.local, to: f.remote, into: f.path("server"), rec: rec).run()

        #expect(rec.last.state == .done)
        #expect(f.read("server/site/index.html") == "<h1>hi</h1>")
        #expect(f.read("server/site/css/app.css") == "body{}")
        #expect(f.read("server/site/img/deep/er/logo.svg") == "<svg/>")
        #expect(f.exists("server/site/empty"))
        #expect(rec.last.filesDone == 3 && rec.last.filesTotal == 3)
        #expect(rec.last.bytesDone == rec.last.bytesTotal)
    }

    /// BUG-005: copied folders got today's date instead of the original's.
    @Test func foldersKeepTheirModificationDates() async throws {
        let f = try await TransferFixture()
        f.write("server/site/sub/a.txt", "a")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path("server/site/sub"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.path("server/site"))
        await batch([try await f.remoteEntry("server/site")], from: f.remote, to: f.local, into: f.path("local")).run()
        for dir in ["local/site", "local/site/sub"] {
            let date = try FileManager.default.attributesOfItem(atPath: f.path(dir))[.modificationDate] as? Date
            #expect(date == old, "\(dir): \(String(describing: date))")
        }
        await batch([try await f.entry("local/site")], from: f.local, to: f.remote, into: f.path("server/site/sub")).run()
        #expect(try await f.client.stat(f.path("server/site/sub/site")).modificationTime == 1_600_000_000)
    }

    @Test func downloadsAFolderTree() async throws {
        let f = try await TransferFixture()
        for i in 0..<20 { f.write("server/logs/day-\(i).log", String(repeating: "x", count: i * 1000)) }
        let rec = Recorder()
        await batch([try await f.remoteEntry("server/logs")], from: f.remote, to: f.local, into: f.path("local"), rec: rec).run()
        #expect(rec.last.state == .done)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.path("local/logs")).count == 20)
        #expect(f.read("local/logs/day-7.log")?.count == 7000)
    }

    @Test(arguments: [
        (ConflictChoice.replace, "new", nil as String?),
        (.skip, "old", nil),
        (.keepBoth, "old", "new"),
    ])
    func conflictChoices(choice: ConflictChoice, expectedOriginal: String, expectedCopy: String?) async throws {
        let f = try await TransferFixture()
        f.write("local/a.txt", "new")
        f.write("server/a.txt", "old")
        let rec = Recorder()
        await batch([try await f.entry("local/a.txt")], from: f.local, to: f.remote, into: f.path("server"),
                    decide: .init(choice), rec: rec).run()
        #expect(rec.conflicts == ["a.txt"])
        #expect(f.read("server/a.txt") == expectedOriginal)
        #expect(f.read("server/a 2.txt") == expectedCopy)
    }

    @Test func replaceIfNewerComparesModificationTimes() async throws {
        let f = try await TransferFixture()
        f.write("local/newer.txt", "local", mtime: 2_000_000_000)
        f.write("server/newer.txt", "server", mtime: 1_000_000_000)
        f.write("local/older.txt", "local", mtime: 1_000_000_000)
        f.write("server/older.txt", "server", mtime: 2_000_000_000)
        let rec = Recorder()
        await batch([try await f.entry("local/newer.txt"), try await f.entry("local/older.txt")], from: f.local, to: f.remote,
                    into: f.path("server"), decide: .init(.replaceIfNewer, applyToAll: true), rec: rec).run()
        #expect(f.read("server/newer.txt") == "local")
        #expect(f.read("server/older.txt") == "server")
        #expect(rec.last.skipped == 1)
    }

    @Test func applyToAllAsksOnlyOnce() async throws {
        let f = try await TransferFixture()
        for i in 0..<10 {
            f.write("local/f\(i).txt", "new")
            f.write("server/f\(i).txt", "old")
        }
        let sources = try await (0..<10).asyncMap { try await f.entry("local/f\($0).txt") }
        let rec = Recorder()
        // A slow answer (like a person reading the dialog) keeps the question open while other files arrive.
        let b = TransferBatch(mode: .copy, sources: sources, from: f.local, to: f.remote, destinationFolder: f.path("server"),
                              parallel: 5, resolver: { c in
                                  rec.conflict(c)
                                  try? await Task.sleep(for: .milliseconds(100))
                                  return .init(.replace, applyToAll: true)
                              }, onProgress: { rec.progress($0) })
        await b.run()
        #expect(rec.conflicts.count == 1)
        #expect((0..<10).allSatisfy { f.read("server/f\($0).txt") == "new" })
    }

    @Test func stopCancelsTheRest() async throws {
        let f = try await TransferFixture()
        f.write("local/a.txt", "new")
        f.write("server/a.txt", "old")
        let rec = Recorder()
        await batch([try await f.entry("local/a.txt")], from: f.local, to: f.remote, into: f.path("server"), decide: .init(.stop), rec: rec).run()
        #expect(rec.last.state == .cancelled)
        #expect(f.read("server/a.txt") == "old")
    }

    @Test func retryWithSkipIdenticalOnlyCopiesWhatsMissing() async throws {
        let f = try await TransferFixture()
        f.write("local/set/done.txt", "already there", mtime: 1_700_000_000)
        f.write("local/set/missing.txt", "new")
        f.write("local/set/changed.txt", "local v2", mtime: 1_700_000_500)
        await batch([try await f.entry("local/set")], from: f.local, to: f.remote, into: f.path("server")).run()
        // Simulate a half-finished first attempt: remove one, change another.
        try FileManager.default.removeItem(atPath: f.path("server/set/missing.txt"))
        f.write("server/set/changed.txt", "old", mtime: 1_600_000_000)

        let rec = Recorder()
        let retry = TransferBatch(mode: .copy, sources: [try await f.entry("local/set")], from: f.local, to: f.remote,
                                  destinationFolder: f.path("server"), skipIdentical: true,
                                  resolver: { c in rec.conflict(c); return .init(.replace) }, onProgress: { rec.progress($0) })
        await retry.run()
        #expect(rec.conflicts == ["changed.txt"])  // the identical file was skipped without asking
        #expect(f.read("server/set/missing.txt") == "new")
        #expect(f.read("server/set/changed.txt") == "local v2")
        #expect(rec.last.skipped == 1)
    }

    @Test func oneUnreadableFileDoesNotStopTheOthers() async throws {
        let f = try await TransferFixture()
        f.write("local/dir/ok1.txt", "1")
        let secret = f.write("local/dir/locked.txt", "no")
        f.write("local/dir/ok2.txt", "2")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secret) }
        let rec = Recorder()
        await batch([try await f.entry("local/dir")], from: f.local, to: f.remote, into: f.path("server"), rec: rec).run()
        #expect(f.read("server/dir/ok1.txt") == "1")
        #expect(f.read("server/dir/ok2.txt") == "2")
        #expect(rec.last.failures.map { ($0.path as NSString).lastPathComponent } == ["locked.txt"])
        if case .failed = rec.last.state {} else { Issue.record("expected a failed-with-errors state, got \(rec.last.state)") }
    }

    @Test func moveAcrossFilesystemsRemovesTheSources() async throws {
        let f = try await TransferFixture()
        f.write("local/pack/a.txt", "a")
        f.write("local/pack/sub/b.txt", "b")
        await batch([try await f.entry("local/pack")], mode: .move, from: f.local, to: f.remote, into: f.path("server")).run()
        #expect(f.read("server/pack/sub/b.txt") == "b")
        #expect(!f.exists("local/pack"))
    }

    @Test func moveWithinOneServerIsARename() async throws {
        let f = try await TransferFixture()
        f.write("server/from/big.bin", String(repeating: "z", count: 100_000))
        try FileManager.default.createDirectory(atPath: f.path("server/to"), withIntermediateDirectories: true)
        let rec = Recorder()
        await batch([try await f.remoteEntry("server/from/big.bin")], mode: .move, from: f.remote, to: f.remote, into: f.path("server/to"), rec: rec).run()
        #expect(rec.last.state == .done)
        #expect(f.read("server/to/big.bin")?.count == 100_000)
        #expect(!f.exists("server/from/big.bin"))
        #expect(rec.last.bytesTotal == 0)  // no bytes were copied
    }

    @Test func copyingAFolderIntoItselfIsRefused() async throws {
        let f = try await TransferFixture()
        f.write("server/site/a.txt", "a")
        try FileManager.default.createDirectory(atPath: f.path("server/site/inner"), withIntermediateDirectories: true)
        let rec = Recorder()
        await batch([try await f.remoteEntry("server/site")], from: f.remote, to: f.remote, into: f.path("server/site/inner"), rec: rec).run()
        #expect(rec.last.state == .failed(TransferError.intoItself("site").localizedDescription))
    }

    @Test func serverToServerCopy() async throws {
        let f = try await TransferFixture()
        let other = RemoteOps(client: try await TransferFixture.connect(f.root), identity: "other")
        defer { other.client.close() }
        f.write("server/report.csv", "a,b\n1,2\n")
        try FileManager.default.createDirectory(atPath: f.path("server/archive"), withIntermediateDirectories: true)
        await batch([try await f.remoteEntry("server/report.csv")], from: f.remote, to: other, into: f.path("server/archive")).run()
        #expect(f.read("server/archive/report.csv") == "a,b\n1,2\n")
    }

    @Test func cancellingStopsTheBatch() async throws {
        let f = try await TransferFixture()
        for i in 0..<200 { f.write("local/many/f\(i)", String(repeating: "y", count: 50_000)) }
        let rec = Recorder()
        let b = batch([try await f.entry("local/many")], from: f.local, to: f.remote, into: f.path("server"), rec: rec)
        let task = Task { await b.run() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value
        #expect(rec.last.state == .cancelled)
        #expect(rec.last.filesDone < 200)
    }

    /// BUG-001: changing only the case of a name was refused on case-insensitive disks (APFS, HFS+).
    @Test func caseOnlyRenameLocalAndRemote() async throws {
        let f = try await TransferFixture()
        f.write("local/release.zip", "zip")
        try await f.local.rename(f.path("local/release.zip"), to: f.path("local/Release.zip"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.path("local")) == ["Release.zip"])

        f.write("server/notes.md", "md")
        try await f.remote.rename(f.path("server/notes.md"), to: f.path("server/Notes.md"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.path("server")) == ["Notes.md"])
    }

    @Test func renameStillRefusesToReplaceAnotherFile() async throws {
        let f = try await TransferFixture()
        f.write("local/a.txt", "a")
        f.write("local/b.txt", "b")
        await #expect(throws: (any Error).self) { try await f.local.rename(f.path("local/a.txt"), to: f.path("local/b.txt")) }
        f.write("server/a.txt", "a")
        f.write("server/b.txt", "b")
        await #expect(throws: (any Error).self) { try await f.remote.rename(f.path("server/a.txt"), to: f.path("server/b.txt")) }
        #expect(f.read("server/b.txt") == "b")
    }

    @Test func deleteTreeRemovesEverything() async throws {
        let f = try await TransferFixture()
        f.write("server/old/a/b/c.txt", "c")
        f.write("server/old/d.txt", "d")
        try await deleteTree(at: f.path("server/old"), on: f.remote)
        #expect(!f.exists("server/old"))
    }

    @Test func uniqueNames() async throws {
        let taken: Set<String> = ["a.txt", "a 2.txt", "folder", ".env"]
        #expect(await FileNames.uniqueName("a.txt") { taken.contains($0) } == "a 3.txt")
        #expect(await FileNames.uniqueName("folder") { taken.contains($0) } == "folder 2")
        #expect(await FileNames.uniqueName(".env") { taken.contains($0) } == ".env 2")
        #expect(await FileNames.uniqueName("free.txt") { taken.contains($0) } == "free.txt")
        #expect(FileNames.validationError(for: "a/b") != nil)
        #expect(FileNames.validationError(for: "  ") != nil)
        #expect(FileNames.validationError(for: "ok name.txt") == nil)
    }
}

@Suite struct RemoteEditTests {
    @Test func uploadsOnlyRealChangesAndRefusesToClobber() async throws {
        let f = try await TransferFixture()
        f.write("server/site/index.html", "v1", mtime: 1_700_000_000)
        let editRoot = f.root.appendingPathComponent("edits")
        let session = try await RemoteEditSession.open(f.path("server/site/index.html"), client: f.client, editRoot: editRoot)
        defer { session.close() }
        #expect(try String(contentsOf: session.localURL, encoding: .utf8) == "v1")

        #expect(try await session.uploadIfChanged() == .unchanged)

        try "v2".write(to: session.localURL, atomically: true, encoding: .utf8)
        #expect(try await session.uploadIfChanged() == .uploaded)
        #expect(f.read("server/site/index.html") == "v2")

        // Someone else edits the file on the server.
        f.write("server/site/index.html", "theirs", mtime: 1_800_000_000)
        try "v3".write(to: session.localURL, atomically: true, encoding: .utf8)
        #expect(try await session.uploadIfChanged() == .remoteChanged)
        #expect(f.read("server/site/index.html") == "theirs")

        #expect(try await session.uploadIfChanged(force: true) == .uploaded)
        #expect(f.read("server/site/index.html") == "v3")
    }

    @Test func closeRemovesTheLocalCopy() async throws {
        let f = try await TransferFixture()
        f.write("server/a.txt", "a")
        let session = try await RemoteEditSession.open(f.path("server/a.txt"), client: f.client, editRoot: f.root.appendingPathComponent("edits"))
        let dir = session.localURL.deletingLastPathComponent()
        session.close()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await transform(e)) }
        return out
    }
}

@Suite struct ThrottlingTests {
    @Test func limiterHoldsTheAverageRate() async throws {
        let limiter = BandwidthLimiter()
        await limiter.setLimit(200_000)  // 200 KB/s, with a 1 s burst
        let start = ContinuousClock.now
        for _ in 0..<(600_000 / 32_768) { await limiter.take(32_768) }
        let seconds = Double((ContinuousClock.now - start).components.seconds)
            + Double((ContinuousClock.now - start).components.attoseconds) / 1e18
        // ~590 KB at 200 KB/s with 200 KB of burst: about 2 s.
        #expect(seconds > 1.6 && seconds < 6, "took \(seconds) s")
    }

    @Test func noLimitMeansNoWaiting() async {
        let limiter = BandwidthLimiter()
        let start = ContinuousClock.now
        for _ in 0..<1000 { await limiter.take(1_000_000) }
        #expect(ContinuousClock.now - start < .milliseconds(200))
    }

    @Test func downloadReportsEveryByteToTheThrottle() async throws {
        let f = try await TransferFixture()
        let size = 1_000_003
        f.write("server/big.bin", String(repeating: "z", count: size))
        let counter = ByteCounter()
        try await f.client.download(f.path("server/big.bin"), to: URL(fileURLWithPath: f.path("local/big.bin")),
                                    throttle: { n in counter.add(n) })
        #expect(counter.total == size)
    }

    @Test func pauseHoldsTheBatchAndResumeFinishesIt() async throws {
        let f = try await TransferFixture()
        for i in 0..<60 { f.write("local/many/f\(i)", String(repeating: "y", count: 40_000)) }
        let rec = Recorder()
        let b = batch([try await f.entry("local/many")], from: f.local, to: f.remote, into: f.path("server"), rec: rec)
        let task = Task { await b.run() }
        _ = await waitFor { rec.last.filesDone >= 3 }
        await b.pause()
        try await Task.sleep(for: .milliseconds(150))   // let files already past the gate settle
        let atPause = rec.last.filesDone
        try await Task.sleep(for: .milliseconds(500))
        #expect(rec.last.filesDone == atPause, "kept going while paused: \(atPause) → \(rec.last.filesDone)")
        #expect(rec.last.filesDone < 60)
        await b.resume()
        await task.value
        #expect(rec.last.state == .done)
        #expect(rec.last.filesDone == 60)
    }

    func waitFor(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var total: Int { lock.withLock { n } }
    func add(_ x: Int) { lock.withLock { n += x } }
}
