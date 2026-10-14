import Foundation
import SFTPKit
import Testing
@testable import TransferKit

/// Local "L" on the Mac side, "R" on the server side (through sftp-server).
@Suite struct SyncTests {
    func plan(_ f: TransferFixture, _ o: SyncOptions) async throws -> SyncPlan {
        try await SyncEngine.compare(left: f.local, leftRoot: f.path("local"), right: f.remote, rightRoot: f.path("server"), options: o)
    }

    func run(_ f: TransferFixture, _ p: SyncPlan) async -> SyncResult {
        await SyncEngine.execute(p, left: f.local, leftRoot: f.path("local"), right: f.remote, rightRoot: f.path("server"))
    }

    func action(_ p: SyncPlan, _ rel: String) -> SyncItem.Action? { p.items.first { $0.relativePath == rel }?.action }

    @Test func oneWayPlansAddsUpdatesAndLeavesSameAlone() async throws {
        let f = try await TransferFixture()
        f.write("local/new.txt", "new")
        f.write("local/sub/deep.txt", "deep")
        f.write("local/changed.txt", "v2", mtime: 1_700_000_100)
        f.write("server/changed.txt", "v1", mtime: 1_700_000_000)
        f.write("local/same.txt", "same", mtime: 1_700_000_000)
        f.write("server/same.txt", "same", mtime: 1_700_000_001)  // within the 2 s tolerance
        f.write("server/orphan.txt", "only on the right")
        let p = try await plan(f, SyncOptions())
        #expect(action(p, "new.txt") == .copyToRight)
        #expect(action(p, "sub") == .createFolderRight)
        #expect(action(p, "sub/deep.txt") == .copyToRight)
        #expect(action(p, "changed.txt") == .copyToRight)
        #expect(action(p, "same.txt") == .same)
        #expect(action(p, "orphan.txt") == nil)  // deletes are off by default
        #expect(p.adds == 2 && p.updates == 1 && p.deletes == 0)
    }

    @Test func oneWayNeverOverwritesANewerTarget() async throws {
        let f = try await TransferFixture()
        f.write("local/report.txt", "old", mtime: 1_700_000_000)
        f.write("server/report.txt", "edited on the server", mtime: 1_800_000_000)
        let p = try await plan(f, SyncOptions())
        guard case .conflict = action(p, "report.txt") else { Issue.record("expected a conflict"); return }
        #expect(p.items.first?.included == false)
        _ = await run(f, p)
        #expect(f.read("server/report.txt") == "edited on the server")
    }

    @Test func deleteOrphansOnlyWhenAsked() async throws {
        let f = try await TransferFixture()
        f.write("local/keep.txt", "k")
        f.write("server/keep.txt", "k")
        f.write("server/stale/old.txt", "x")
        var o = SyncOptions()
        o.deleteOrphans = true
        let p = try await plan(f, o)
        #expect(action(p, "stale") == .deleteRight)
        _ = await run(f, p)
        #expect(!f.exists("server/stale"))
        #expect(f.exists("server/keep.txt"))
    }

    @Test func twoWayNewerWinsEachWayAndTiesAreConflicts() async throws {
        let f = try await TransferFixture()
        f.write("local/a.txt", "left newer", mtime: 1_700_000_100)
        f.write("server/a.txt", "left older", mtime: 1_700_000_000)
        f.write("local/b.txt", "right older", mtime: 1_700_000_000)
        f.write("server/b.txt", "right newer", mtime: 1_700_000_100)
        f.write("local/c.txt", "short", mtime: 1_700_000_000)
        f.write("server/c.txt", "much longer", mtime: 1_700_000_000)
        f.write("server/only-right.txt", "r")
        var o = SyncOptions()
        o.direction = .both
        o.updateBy = .dateOrSize
        let p = try await plan(f, o)
        #expect(action(p, "a.txt") == .copyToRight)
        #expect(action(p, "b.txt") == .copyToLeft)
        guard case .conflict = action(p, "c.txt") else { Issue.record("expected a conflict for c.txt"); return }
        #expect(action(p, "only-right.txt") == .copyToLeft)
        _ = await run(f, p)
        #expect(f.read("server/a.txt") == "left newer")
        #expect(f.read("local/b.txt") == "right newer")
        #expect(f.read("local/only-right.txt") == "r")
        #expect(f.read("local/c.txt") == "short" && f.read("server/c.txt") == "much longer")
    }

    @Test func twoWayWithDeletesIsRefused() async throws {
        let f = try await TransferFixture()
        var o = SyncOptions()
        o.direction = .both
        o.deleteOrphans = true
        await #expect(throws: SyncError.twoWayDelete) { _ = try await plan(f, o) }
    }

    @Test func excludesAndHiddenFiles() async throws {
        let f = try await TransferFixture()
        f.write("local/app.js", "js")
        f.write("local/debug.log", "log")
        f.write("local/node_modules/x/index.js", "dep")
        f.write("local/.env", "SECRET=1")
        var o = SyncOptions()
        o.excludes = ["*.log", "node_modules"]
        let p = try await plan(f, o)
        #expect(p.items.map(\.relativePath) == ["app.js"])
        o.includeHidden = true
        #expect(try await plan(f, o).items.map(\.relativePath).sorted() == [".env", "app.js"])
    }

    @Test func timeOffsetCorrection() async throws {
        let f = try await TransferFixture()
        f.write("local/a.txt", "same", mtime: 1_700_003_600)
        f.write("server/a.txt", "same", mtime: 1_700_000_000)  // server clock an hour behind
        var o = SyncOptions()
        #expect(action(try await plan(f, o), "a.txt") == .copyToRight)
        o.timeOffset = 3600
        #expect(action(try await plan(f, o), "a.txt") == .same)
    }

    @Test func fileVersusFolderIsAConflict() async throws {
        let f = try await TransferFixture()
        f.write("local/thing", "a file")
        f.write("server/thing/inside.txt", "a folder")
        guard case .conflict = action(try await plan(f, SyncOptions()), "thing") else { Issue.record("expected a conflict"); return }
    }

    @Test func unicodeNormalisationMatchesTheSameName() async throws {
        let f = try await TransferFixture()
        let nfd = "cafe\u{301}.txt", nfc = "caf\u{e9}.txt"
        f.write("local/" + nfd, "x", mtime: 1_700_000_000)
        f.write("server/" + nfc, "x", mtime: 1_700_000_000)
        let p = try await plan(f, SyncOptions())
        #expect(p.items.count == 1)
        #expect(p.items.first?.action == .same)
    }

    @Test func untickedItemsAreSkipped() async throws {
        let f = try await TransferFixture()
        f.write("local/yes.txt", "y")
        f.write("local/no.txt", "n")
        var p = try await plan(f, SyncOptions())
        if let i = p.items.firstIndex(where: { $0.relativePath == "no.txt" }) { p.items[i].included = false }
        _ = await run(f, p)
        #expect(f.exists("server/yes.txt"))
        #expect(!f.exists("server/no.txt"))
    }

    @Test func skipEmptyFolders() async throws {
        let f = try await TransferFixture()
        try FileManager.default.createDirectory(atPath: f.path("local/empty/deeper"), withIntermediateDirectories: true)
        f.write("local/full/a.txt", "a")
        var o = SyncOptions()
        o.skipEmptyFolders = true
        let p = try await plan(f, o)
        #expect(p.items.map(\.relativePath).sorted() == ["full", "full/a.txt"])
    }

    /// The real test of a sync: afterwards the trees match, and comparing again finds nothing to do.
    @Test func syncThenCompareAgainFindsNothing() async throws {
        let f = try await TransferFixture()
        for i in 0..<30 { f.write("local/site/page\(i).html", String(repeating: "p", count: i * 100)) }
        f.write("local/site/img/logo.svg", "<svg/>")
        f.write("server/site/page3.html", "old", mtime: 1_600_000_000)
        let first = try await plan(f, SyncOptions())
        let result = await run(f, first)
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(f.read("server/site/page3.html") == f.read("local/site/page3.html"))
        let second = try await plan(f, SyncOptions())
        #expect(!second.hasChanges, "\(second.items.filter(\.isChange).map(\.relativePath))")
    }
}
